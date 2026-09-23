#!/usr/bin/env bash
# Create a lean conda analysis environment and a local project folder.
# Questions are asked first; the rest is unattended.
set -euo pipefail

DEFAULT_PROJECT_NAME="analysis"
DEFAULT_PYTHON_VERSION="3.12"
NUMPY_PIN="numpy>=1.26,<2"
NEUROPY_PATH="${HOME}/GitHub/neuro_py"
NEUROPY_REPO="https://github.com/ayalab1/neuro_py.git"
AGENTKIT_INSTALL="${HOME}/GitHub/agentkit/install.py"

CONDA=""
CONDA_PREFIX=""
MINICONDA_INSTALLED=0
HAS_GPU=0
CUDA_VERSION=""
TORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"
CUPY_PACKAGE=""
ENV_NAME=""
PROJECT_NAME=""
PACKAGE_NAME=""
PYTHON_VERSION=""
PROJECT_DIR=""

NAME_FLAG=""
ENV_FLAG=""
PYTHON_FLAG=""
YES=0

step() { echo ">> $1"; }
info() { echo "[INFO] $1"; }
success() { echo "[SUCCESS] $1"; }
warn() { echo "[WARNING] $1"; }

die() {
  echo "$1" >&2
  exit "${2:-1}"
}

usage() {
  echo "Usage: setup.sh [--name NAME] [--env-name NAME] [--python VER] [--yes]"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || die "--name requires a value"
        NAME_FLAG="$2"
        shift 2
        ;;
      --name=*)
        NAME_FLAG="${1#*=}"
        shift
        ;;
      --env-name)
        [[ $# -ge 2 ]] || die "--env-name requires a value"
        ENV_FLAG="$2"
        shift 2
        ;;
      --env-name=*)
        ENV_FLAG="${1#*=}"
        shift
        ;;
      --python)
        [[ $# -ge 2 ]] || die "--python requires a value"
        PYTHON_FLAG="$2"
        shift 2
        ;;
      --python=*)
        PYTHON_FLAG="${1#*=}"
        shift
        ;;
      --yes|-y)
        YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

safe_folder_name() {
  local name="$1"
  name="$(printf '%s' "$name" | tr '/\\:*?"<>|' '_' | sed 's/[[:space:]]*$//;s/^[[:space:]]*//;s/\.*$//')"
  if [[ -z "$name" ]]; then
    name="$DEFAULT_PROJECT_NAME"
  fi
  printf '%s' "$name"
}

safe_package_name() {
  local pkg
  pkg="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g;s/__*/_/g;s/^_//;s/_$//')"
  if [[ -z "$pkg" ]]; then
    pkg="$DEFAULT_PROJECT_NAME"
  fi
  if [[ "$pkg" =~ ^[0-9] ]]; then
    pkg="_$pkg"
  fi
  printf '%s' "$pkg"
}

safe_env_name() {
  # conda rejects space, colon, slash, and hash in environment names
  local name="$1"
  name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s|[[:space:]:/#]|_|g;s/__*/_/g;s/^_//;s/_$//')"
  if [[ -z "$name" ]]; then
    name="$DEFAULT_PROJECT_NAME"
  fi
  printf '%s' "$name"
}

read_value_or_default() {
  local prompt="$1"
  local default="$2"
  local value=""
  read -r -p "${prompt} [${default}]: " value || true
  if [[ -z "${value// }" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
}

find_conda() {
  local candidate dir base prefix
  if command -v conda >/dev/null 2>&1; then
    candidate="$(command -v conda)"
    if [[ -x "$candidate" && -f "$candidate" ]]; then
      dir="$(dirname "$candidate")"
      base="$(basename "$dir")"
      if [[ "$base" == "bin" || "$base" == "condabin" ]]; then
        prefix="$(dirname "$dir")"
      else
        prefix="$dir"
      fi
      if [[ -x "${prefix}/bin/conda" ]]; then
        CONDA="${prefix}/bin/conda"
        CONDA_PREFIX="$prefix"
        return 0
      fi
      CONDA="$candidate"
      CONDA_PREFIX="$prefix"
      return 0
    fi
  fi

  local roots=(
    "${HOME}/miniconda3"
    "${HOME}/Miniconda3"
    "${HOME}/anaconda3"
    "${HOME}/miniforge3"
    "/opt/conda"
    "/usr/local/miniconda3"
  )
  local p
  for p in "${roots[@]}"; do
    if [[ -x "${p}/bin/conda" ]]; then
      CONDA="${p}/bin/conda"
      CONDA_PREFIX="$p"
      return 0
    fi
  done
  return 1
}

install_miniconda() {
  step "Miniconda not found; installing Miniconda3 for the current user"
  local dest="${HOME}/miniconda3"
  local os arch url installer
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)
      case "$arch" in
        x86_64|amd64)
          url="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
          ;;
        *)
          die "Unsupported Linux architecture: $arch"
          ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        arm64)
          url="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
          ;;
        x86_64)
          url="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
          ;;
        *)
          die "Unsupported macOS architecture: $arch"
          ;;
      esac
      ;;
    *)
      die "Unsupported OS: $os"
      ;;
  esac

  installer="${TMPDIR:-/tmp}/Miniconda3-latest.sh"
  curl -fsSL "$url" -o "$installer"
  bash "$installer" -b -p "$dest"
  CONDA="${dest}/bin/conda"
  CONDA_PREFIX="$dest"
  MINICONDA_INSTALLED=1
  if [[ ! -x "$CONDA" ]]; then
    die "Miniconda installed but conda was not found under $dest."
  fi
  success "Miniconda3 installed at $dest"
}

initialize_conda_tos() {
  step "Accepting conda Terms of Service for Anaconda channels"
  "$CONDA" tos accept --override-channels --channel "https://repo.anaconda.com/pkgs/main" >/dev/null 2>&1 || true
  "$CONDA" tos accept --override-channels --channel "https://repo.anaconda.com/pkgs/r" >/dev/null 2>&1 || true
}

conda_env_exists() {
  local json
  json="$("$CONDA" env list --json 2>/dev/null || true)"
  if [[ -n "$json" ]] && printf '%s\n' "$json" | grep -E "[/\\\\]${ENV_NAME}\"" >/dev/null 2>&1; then
    return 0
  fi
  [[ -d "${CONDA_PREFIX}/envs/${ENV_NAME}" ]]
}

invoke_conda() {
  "$CONDA" "$@"
}

invoke_env_pip() {
  "$CONDA" run -n "$ENV_NAME" --no-capture-output pip "$@"
}

resolve_pytorch_tag() {
  local ver="$1"
  local major="${ver%%.*}"
  case "$ver" in
    11.8) echo "cu118"; return ;;
    12.1) echo "cu121"; return ;;
    12.4) echo "cu124"; return ;;
  esac
  if [[ "$major" == "12" ]]; then
    echo "cu124"
  elif [[ "$major" == "11" ]]; then
    echo "cu118"
  else
    echo "cu124"
  fi
}

resolve_cupy_package() {
  local ver="$1"
  local major="${ver%%.*}"
  case "$major" in
    11) echo "cupy-cuda11x" ;;
    12) echo "cupy-cuda12x" ;;
    13) echo "cupy-cuda13x" ;;
    *) echo "" ;;
  esac
}

resolve_gpu() {
  step "Checking for NVIDIA GPU"
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "GPU not detected"
    HAS_GPU=0
    TORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"
    CUPY_PACKAGE=""
    return 0
  fi

  local query=""
  if ! query="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"; then
    echo "GPU not detected"
    HAS_GPU=0
    TORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"
    CUPY_PACKAGE=""
    return 0
  fi
  if [[ -z "${query//[$' \t\n\r']/}" ]]; then
    echo "GPU not detected"
    HAS_GPU=0
    TORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"
    CUPY_PACKAGE=""
    return 0
  fi

  local smi_text="" cuda_version=""
  smi_text="$(nvidia-smi 2>/dev/null || true)"
  if [[ "$smi_text" =~ CUDA\ Version:[[:space:]]+([0-9]+\.[0-9]+) ]]; then
    cuda_version="${BASH_REMATCH[1]}"
  else
    cuda_version="12.4"
  fi

  local tag
  tag="$(resolve_pytorch_tag "$cuda_version")"
  HAS_GPU=1
  CUDA_VERSION="$cuda_version"
  TORCH_INDEX_URL="https://download.pytorch.org/whl/${tag}"
  CUPY_PACKAGE="$(resolve_cupy_package "$cuda_version")"
  success "GPU detected (${query//$'\n'/; }); CUDA ${cuda_version} -> ${tag}"
}

expand_tokens() {
  local text="$1"
  text="${text//__PROJECT_NAME__/${PROJECT_NAME}}"
  text="${text//__PACKAGE_NAME__/${PACKAGE_NAME}}"
  text="${text//__ENV_NAME__/${ENV_NAME}}"
  text="${text//__PYTHON_VERSION__/${PYTHON_VERSION}}"
  printf '%s' "$text"
}

write_file_from_template() {
  local rel="$1"
  local content="$2"
  local dest
  dest="${PROJECT_DIR}/$(expand_tokens "$rel")"
  mkdir -p "$(dirname "$dest")"
  expand_tokens "$content" > "$dest"
  printf '\n' >> "$dest"
}

write_embedded_templates() {
  write_file_from_template "README.md" '# __PROJECT_NAME__

Analysis project for the `__ENV_NAME__` conda environment (Python __PYTHON_VERSION__).

Work lives in the `__PACKAGE_NAME__` package and in `tests/`. This is a scripting project.

## Activate

```text
conda activate __ENV_NAME__
```

Data in `data/` stays on this machine or Drive and is not committed.
'
  write_file_from_template "pyproject.toml" '[build-system]
requires = ["setuptools>=61.0"]
build-backend = "setuptools.build_meta"

[project]
name = "__PACKAGE_NAME__"
version = "0.1.0"
description = "__PROJECT_NAME__"
readme = "README.md"
requires-python = ">=__PYTHON_VERSION__"
dependencies = []

[tool.setuptools]
packages = ["__PACKAGE_NAME__"]

[tool.pytest.ini_options]
testpaths = ["tests"]
'
  write_file_from_template ".gitignore" 'data/**
!data/README.md
__pycache__/
*.py[cod]
.venv/
.agentkit/
.bridge-cache/
.cursor/
'
  write_file_from_template "data/README.md" '# data

Keep datasets here. They stay local or on Drive and are not committed.
'
  write_file_from_template "docs/README.md" '# docs

Project notes and documentation.
'
  write_file_from_template "results/README.md" '# results

Figures, tables, and other outputs. Treat this folder as generated unless you decide otherwise.
'
  write_file_from_template "tests/README.md" '# tests

Add tests next to `test_import.py`.
'
  write_file_from_template "tests/test_import.py" 'import __PACKAGE_NAME__


def test_import_package():
    assert __PACKAGE_NAME__.__name__ == "__PACKAGE_NAME__"
'
  write_file_from_template "__PACKAGE_NAME__/__init__.py" '"""__PROJECT_NAME__."""

__version__ = "0.1.0"
'
  write_file_from_template "__PACKAGE_NAME__/analysis.py" '"""Analysis helpers for __PROJECT_NAME__.

Add importable functions here. Work lives in this package and in tests/.
"""
'
  write_file_from_template "__PACKAGE_NAME__/README.md" '# __PACKAGE_NAME__

Python package for __PROJECT_NAME__.

Add analysis as importable modules here. Tests live in `tests/`.
'
}

resolve_script_dir() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "$src" || "$src" == "bash" || "$src" == "-" || ! -f "$src" ]]; then
    return 1
  fi
  (cd "$(dirname "$src")" && pwd)
}

write_project_from_templates() {
  step "Writing project folder ${PROJECT_DIR}"
  mkdir -p "$PROJECT_DIR"
  local script_dir=""
  script_dir="$(resolve_script_dir || true)"
  if [[ -n "$script_dir" && -d "${script_dir}/template" ]]; then
    info "Using template files from ${script_dir}/template"
    local file rel dest
    while IFS= read -r -d '' file; do
      rel="${file#"${script_dir}/template/"}"
      dest="${PROJECT_DIR}/$(expand_tokens "$rel")"
      mkdir -p "$(dirname "$dest")"
      expand_tokens "$(cat "$file")" > "$dest"
      printf '\n' >> "$dest"
    done < <(find "${script_dir}/template" -type f -print0)
    return 0
  fi
  info "Using embedded template files (curl/gh launch)"
  write_embedded_templates
}

initialize_project_git() {
  if [[ -d "${PROJECT_DIR}/.git" ]]; then
    info "Project already has a git repo; leaving it unchanged"
    return 0
  fi
  step "Initializing git repository in ${PROJECT_NAME}"
  if ! git -C "$PROJECT_DIR" init >/dev/null; then
    warn "git init failed; continuing without a project repository"
  fi
}

install_neuropy_editable() {
  if [[ ! -d "$NEUROPY_PATH" ]]; then
    step "Cloning neuro_py to ${NEUROPY_PATH}"
    mkdir -p "$(dirname "$NEUROPY_PATH")"
    git clone --depth 1 "$NEUROPY_REPO" "$NEUROPY_PATH"
  else
    info "Using existing neuro_py at ${NEUROPY_PATH}"
  fi
  step "Installing neuro_py editable (--no-deps)"
  (
    cd "$NEUROPY_PATH"
    invoke_env_pip install -e . --no-deps --force-reinstall --no-cache-dir --no-input
  )
}

invoke_agentkit_best_effort() {
  if [[ ! -f "$AGENTKIT_INSTALL" ]]; then
    echo "agentkit was skipped (${AGENTKIT_INSTALL} not found)"
    return 0
  fi
  step "Running agentkit init"
  if ! (
    cd "$PROJECT_DIR"
    "$CONDA" run -n "$ENV_NAME" --no-capture-output python "$AGENTKIT_INSTALL" init
  ); then
    echo "agentkit was skipped (install.py init failed)"
  fi
}

test_imports() {
  step "Checking imports"
  local expect_gpu="0"
  if [[ "$HAS_GPU" == "1" ]]; then
    expect_gpu="1"
  fi
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'PY'
import sys
import neuro_py
import torch
cuda = bool(torch.cuda.is_available())
print("neuro_py: import ok")
print("torch: %s" % torch.__version__)
print("torch.cuda.is_available: %s" % cuda)
if sys.argv[1] == "1" and not cuda:
    sys.exit(1)
PY
  local code=0
  if ! "$CONDA" run -n "$ENV_NAME" --no-capture-output python "$tmp" "$expect_gpu"; then
    code=1
  fi
  rm -f "$tmp"
  if [[ "$code" -ne 0 ]]; then
    if [[ "$HAS_GPU" == "1" ]]; then
      die "Import check failed: torch.cuda.is_available() is false on the GPU path."
    fi
    die "Import check failed."
  fi
  success "Import check passed"
}

get_setup_answers() {
  local project_default="$DEFAULT_PROJECT_NAME"
  local python_default="$DEFAULT_PYTHON_VERSION"
  if [[ -n "$NAME_FLAG" ]]; then
    project_default="$NAME_FLAG"
  fi
  if [[ -n "$PYTHON_FLAG" ]]; then
    python_default="$PYTHON_FLAG"
  fi

  if [[ "$YES" == "1" ]]; then
    PROJECT_NAME="$(safe_folder_name "$project_default")"
    if [[ -n "$ENV_FLAG" ]]; then
      ENV_NAME="$(safe_env_name "$ENV_FLAG")"
    else
      ENV_NAME="$(safe_env_name "$PROJECT_NAME")"
    fi
    PYTHON_VERSION="$python_default"
    return 0
  fi

  local project env py env_default
  project="$(read_value_or_default "Project name" "$project_default")"
  PROJECT_NAME="$(safe_folder_name "$project")"
  env_default="$(safe_env_name "$PROJECT_NAME")"
  if [[ -n "$ENV_FLAG" ]]; then
    env_default="$(safe_env_name "$ENV_FLAG")"
  fi
  env="$(read_value_or_default "Environment name" "$env_default")"
  py="$(read_value_or_default "Python version" "$python_default")"
  ENV_NAME="$(safe_env_name "$env")"
  PYTHON_VERSION="$(printf '%s' "$py" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

# --- questions (all upfront) -------------------------------------------------
parse_args "$@"
get_setup_answers
PACKAGE_NAME="$(safe_package_name "$PROJECT_NAME")"
if [[ -z "$ENV_NAME" ]]; then
  ENV_NAME="$(safe_env_name "$PROJECT_NAME")"
fi
if [[ -z "$PYTHON_VERSION" ]]; then
  PYTHON_VERSION="$DEFAULT_PYTHON_VERSION"
fi
PROJECT_DIR="$(pwd)/${PROJECT_NAME}"

info "Project: ${PROJECT_NAME}"
info "Package: ${PACKAGE_NAME}"
info "Environment: ${ENV_NAME}"
info "Python: ${PYTHON_VERSION}"

# --- locate conda (search only; install later if needed) ---------------------
FOUND=0
if find_conda; then
  FOUND=1
  info "Using conda at ${CONDA}"
fi

WIPE=0
if [[ "$FOUND" == "1" ]] && conda_env_exists; then
  if [[ "$YES" == "1" ]]; then
    WIPE=1
    info "Environment '${ENV_NAME}' exists; wipe accepted (--yes)"
  else
    wipe_answer=""
    read -r -p "Wipe and recreate? [Y/n]: " wipe_answer || true
    if [[ -z "${wipe_answer// }" || "$wipe_answer" =~ ^[Yy] ]]; then
      WIPE=1
    elif [[ "$wipe_answer" =~ ^[Nn] ]]; then
      echo "Environment '${ENV_NAME}' was left unchanged."
      exit 0
    else
      WIPE=1
    fi
  fi
fi

# --- unattended phase --------------------------------------------------------
if [[ "$FOUND" != "1" ]]; then
  install_miniconda
fi

initialize_conda_tos
resolve_gpu

if [[ "$WIPE" == "1" ]]; then
  step "Removing existing environment ${ENV_NAME}"
  invoke_conda env remove -n "$ENV_NAME" -y
fi

step "Creating conda environment ${ENV_NAME} (Python ${PYTHON_VERSION})"
invoke_conda create -n "$ENV_NAME" "python=${PYTHON_VERSION}" -y
success "Environment '${ENV_NAME}' created"

step "Installing lean analysis stack"
invoke_env_pip install --no-input --no-cache-dir \
  "$NUMPY_PIN" \
  scipy \
  matplotlib \
  scikit-learn \
  pandas \
  numba \
  tqdm \
  joblib \
  seaborn \
  scikit-image \
  lazy-loader \
  PyWavelets \
  Bottleneck \
  h5py \
  hdf5storage \
  pymatreader \
  PyYAML

step "Installing nelpy (--no-deps)"
invoke_env_pip install --no-deps --no-input --no-cache-dir \
  "nelpy @ git+https://github.com/nelpy/nelpy.git"

install_neuropy_editable

step "Installing Jupyter kernel ${ENV_NAME}"
invoke_env_pip install --no-input --no-cache-dir ipykernel
"$CONDA" run -n "$ENV_NAME" --no-capture-output python -m ipykernel install --user --name "$ENV_NAME" --display-name "$ENV_NAME"

step "Installing PyTorch last"
invoke_env_pip install torch torchvision torchaudio \
  --index-url "$TORCH_INDEX_URL" \
  --no-cache-dir \
  --no-input
success "PyTorch installed from ${TORCH_INDEX_URL}"

if [[ "$HAS_GPU" == "1" ]]; then
  if [[ -n "$CUPY_PACKAGE" ]]; then
    step "Installing CuPy (${CUPY_PACKAGE})"
    invoke_env_pip install "$CUPY_PACKAGE" --no-cache-dir --no-input
  else
    echo "CuPy was skipped (no wheel mapping for CUDA ${CUDA_VERSION})"
  fi
else
  echo "CuPy was skipped (GPU-only)"
fi

write_project_from_templates
initialize_project_git

step "Installing project editable"
(
  cd "$PROJECT_DIR"
  invoke_env_pip install -e . --no-input
)

invoke_agentkit_best_effort
test_imports

echo ""
echo "Installation complete."
echo ""
echo "    conda activate ${ENV_NAME}"
echo "    cd ./${PROJECT_NAME}"
echo ""
if [[ "$MINICONDA_INSTALLED" == "1" ]]; then
  echo "Miniconda was installed this run. Open a new terminal so conda is on PATH."
fi
