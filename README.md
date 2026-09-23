# analysis-project

Windows one-liner that creates a lean conda analysis environment and a local project folder.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/PraPaudel/analysis-project/main/setup.ps1 | iex"
```

This repo is private, so that raw `irm` URL returns 404 until the repo is public. While it is private, use GitHub CLI (already authenticated) to fetch the same script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -c "gh api -H 'Accept: application/vnd.github.raw' repos/PraPaudel/analysis-project/contents/setup.ps1 | iex"
```

From a clone:

```powershell
.\setup.ps1
```

Non-interactive (accepts defaults or the values you pass; wipes an existing env without asking):

```powershell
.\setup.ps1 -Name analysis -EnvName analysis -Python 3.12 -Yes
```

Windows only. A macOS/Linux bash installer can come later. Conda stays the engine for now; uv is a later option, not this repo.

## Questions (all upfront)

The script asks these with `Read-Host`. Enter accepts the default.

1. Project name `[analysis]`
2. Environment name — default is the project name you just typed
3. Python version `[3.12]`
4. Only if that conda env already exists: Wipe and recreate? `[Y/n]` — Enter means yes. `n` exits before changing anything and leaves the env unchanged.

It does not prompt for CUDA, pip vs conda, neuro_py, or a deep-learning extra. The script decides those.

## What runs unattended

1. Finds conda on PATH, then common Miniconda/Anaconda/Miniforge locations. If none exist, installs Miniconda3 (current user only, no admin) and accepts Anaconda channel Terms of Service.
2. Detects an NVIDIA GPU with `nvidia-smi`. GPU: CUDA-matched PyTorch and CuPy wheels. No GPU: CPU PyTorch, CuPy skipped.
3. Creates `conda create --name <env> python=<ver>`.
4. Installs a lean stack (numpy pinned to `>=1.26,<2`, neuro_py base deps, nelpy with `--no-deps`). No Playwright, PyQt, Altair, or similar extras. No lightning or tensorboard.
5. Editable-installs neuro_py with `--no-deps` from `C:\GitHub\neuro_py`, or clones https://github.com/ayalab1/neuro_py if that folder is missing.
6. Installs `ipykernel` with pip and registers a Jupyter kernel named after the env.
7. Installs PyTorch last (then CuPy on GPU) so later steps cannot upgrade torch.
8. Writes `<project>/` in the current directory from `template/` (or copies embedded in `setup.ps1` when launched via `irm`/`gh api`).
9. `git init` in the new project if needed. Does not add a remote, commit, or push.
10. Editable-installs the new project (`pip install -e .`). Its `pyproject.toml` does not depend on torch or neuro_py.
11. Best-effort `agentkit`: runs `C:\GitHub\agentkit\install.py init` from the project if that file exists; otherwise skips.
12. Import check: `neuro_py` and `torch`. On GPU, `torch.cuda.is_available()` must be true.

When it finishes:

```text
conda activate <env>
cd .\<project>
```

If Miniconda was installed in this run, open a new terminal so conda is on PATH.
