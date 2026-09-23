#requires -Version 5.1
<#
.SYNOPSIS
    Create a lean Windows conda analysis environment and a local project folder.
.DESCRIPTION
    One entry point. Works as .\setup.ps1 and via irm|iex / gh api|iex.
    Questions are asked first; the rest is unattended.
.PARAMETER Name
    Project name. Default: analysis
.PARAMETER EnvName
    Conda environment name. Default: the project name
.PARAMETER Python
    Python version. Default: 3.12
.PARAMETER Yes
    Skip prompts. Use defaults or passed values. Accept wipe of an existing env.
#>
param(
    [string]$Name = "",
    [string]$EnvName = "",
    [string]$Python = "",
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:InvokedAsFile = -not [string]::IsNullOrWhiteSpace($PSScriptRoot)
$script:CondaExe = $null
$script:CondaPrefix = $null
$script:MinicondaInstalledThisRun = $false
$script:HasGpu = $false
$script:CudaVersion = $null
$script:TorchIndexUrl = "https://download.pytorch.org/whl/cpu"
$script:CupyPackage = $null
$script:EnvName = $null
$script:ProjectName = $null
$script:PackageName = $null
$script:PythonVersion = $null
$script:ProjectDir = $null

$DEFAULT_PROJECT_NAME = "analysis"
$DEFAULT_PYTHON_VERSION = "3.12"
$NUMPY_PIN = "numpy>=1.26,<2"
$NEUROPY_PATH = "C:\GitHub\neuro_py"
$NEUROPY_REPO = "https://github.com/ayalab1/neuro_py.git"
$AGENTKIT_INSTALL = "C:\GitHub\agentkit\install.py"
$MINICONDA_URL = "https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe"

$CUDA_PYTORCH_MAP = @{
    "11.8" = "cu118"
    "12.1" = "cu121"
    "12.4" = "cu124"
}

$CUPY_PIP_PACKAGES = @{
    "11" = "cupy-cuda11x"
    "12" = "cupy-cuda12x"
    "13" = "cupy-cuda13x"
}

function Stop-Setup {
    param(
        [int]$Code = 0,
        [string]$Message = ""
    )
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        if ($Code -ne 0) {
            Write-Host $Message -ForegroundColor Red
        }
        else {
            Write-Host $Message
        }
    }
    if ($script:InvokedAsFile) {
        exit $Code
    }
    if ($Code -ne 0) {
        throw "Setup failed with exit code $Code."
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host ">> $Message" -ForegroundColor White
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Get-EmbeddedTemplates {
    return @{
        "README.md" = @'
# __PROJECT_NAME__

Analysis project for the `__ENV_NAME__` conda environment (Python __PYTHON_VERSION__).

Work lives in the `__PACKAGE_NAME__` package and in `tests/`. This is a scripting project.

## Activate

```text
conda activate __ENV_NAME__
```

Data in `data/` stays on this machine or Drive and is not committed.
'@
        "pyproject.toml" = @'
[build-system]
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
'@
        ".gitignore" = @'
data/**
!data/README.md
__pycache__/
*.py[cod]
.venv/
.agentkit/
.bridge-cache/
.cursor/
'@
        "data\README.md" = @'
# data

Keep datasets here. They stay local or on Drive and are not committed.
'@
        "docs\README.md" = @'
# docs

Project notes and documentation.
'@
        "results\README.md" = @'
# results

Figures, tables, and other outputs. Treat this folder as generated unless you decide otherwise.
'@
        "tests\README.md" = @'
# tests

Add tests next to `test_import.py`.
'@
        "tests\test_import.py" = @'
import __PACKAGE_NAME__


def test_import_package():
    assert __PACKAGE_NAME__.__name__ == "__PACKAGE_NAME__"
'@
        "__PACKAGE_NAME__\__init__.py" = @'
"""__PROJECT_NAME__."""

__version__ = "0.1.0"
'@
        "__PACKAGE_NAME__\analysis.py" = @'
"""Analysis helpers for __PROJECT_NAME__.

Add importable functions here. Work lives in this package and in tests/.
"""
'@
        "__PACKAGE_NAME__\README.md" = @'
# __PACKAGE_NAME__

Python package for __PROJECT_NAME__.

Add analysis as importable modules here. Tests live in `tests/`.
'@
    }
}

function Get-SafeFolderName {
    param([string]$Name)
    $invalid = [regex]::Escape(([IO.Path]::GetInvalidFileNameChars() -join ""))
    $safe = $Name -replace "[$invalid]", "_"
    $safe = $safe.Trim().TrimEnd(".")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = $DEFAULT_PROJECT_NAME
    }
    return $safe
}

function Get-SafePackageName {
    param([string]$Name)
    $pkg = $Name.ToLowerInvariant()
    $pkg = $pkg -replace "[^a-z0-9_]", "_"
    $pkg = $pkg -replace "_+", "_"
    $pkg = $pkg.Trim("_")
    if ([string]::IsNullOrWhiteSpace($pkg)) {
        $pkg = $DEFAULT_PROJECT_NAME
    }
    if ($pkg -match "^[0-9]") {
        $pkg = "_$pkg"
    }
    return $pkg
}

function Read-ValueOrDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Get-CondaExeFromPrefix {
    param([string]$Prefix)
    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $Prefix)) {
        return $null
    }
    $candidates = @(
        (Join-Path $Prefix "Scripts\conda.exe"),
        (Join-Path $Prefix "condabin\conda.exe"),
        (Join-Path $Prefix "_conda.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-PrefixFromCondaPath {
    param([string]$CondaPath)
    $item = Get-Item -LiteralPath $CondaPath -ErrorAction SilentlyContinue
    if (-not $item) {
        return $null
    }
    $dirName = $item.Directory.Name
    if ($dirName -eq "Scripts" -or $dirName -eq "condabin") {
        return $item.Directory.Parent.FullName
    }
    return $item.Directory.FullName
}

function Find-CondaInstallation {
    $pathCmd = Get-Command conda.exe -ErrorAction SilentlyContinue
    if (-not $pathCmd) {
        $pathCmd = Get-Command conda -ErrorAction SilentlyContinue
    }
    if ($pathCmd -and $pathCmd.Source) {
        $source = $pathCmd.Source
        if ($source -like "*.exe" -and (Test-Path -LiteralPath $source)) {
            $prefix = Get-PrefixFromCondaPath -CondaPath $source
            $exe = Get-CondaExeFromPrefix -Prefix $prefix
            if ($exe) {
                return [pscustomobject]@{ Exe = $exe; Prefix = $prefix }
            }
            return [pscustomobject]@{ Exe = $source; Prefix = $prefix }
        }
        $prefixFromBat = Get-PrefixFromCondaPath -CondaPath $source
        $exeFromBat = Get-CondaExeFromPrefix -Prefix $prefixFromBat
        if ($exeFromBat) {
            return [pscustomobject]@{ Exe = $exeFromBat; Prefix = $prefixFromBat }
        }
    }

    $roots = @(
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:ProgramData
    )
    $names = @(
        "miniconda3",
        "Miniconda3",
        "anaconda3",
        "Anaconda3",
        "miniforge3",
        "Miniforge3"
    )
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        foreach ($name in $names) {
            $prefix = Join-Path $root $name
            $exe = Get-CondaExeFromPrefix -Prefix $prefix
            if ($exe) {
                return [pscustomobject]@{ Exe = $exe; Prefix = $prefix }
            }
        }
    }
    return $null
}

function Install-Miniconda3 {
    Write-Step "Miniconda not found; installing Miniconda3 for the current user"
    $dest = Join-Path $env:USERPROFILE "miniconda3"
    $installer = Join-Path $env:TEMP "Miniconda3-latest-Windows-x86_64.exe"
    $oldProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $MINICONDA_URL -OutFile $installer -UseBasicParsing
    }
    finally {
        $ProgressPreference = $oldProgress
    }

    # /D must be last. Do not quote the path; NSIS treats /D as literal.
    $installArgs = "/InstallationType=JustMe /AddToPath=0 /RegisterPython=0 /S /D=$dest"
    $process = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Stop-Setup -Code 1 -Message "Miniconda installer exited with code $($process.ExitCode)."
    }

    $exe = Get-CondaExeFromPrefix -Prefix $dest
    if (-not $exe) {
        Stop-Setup -Code 1 -Message "Miniconda installed but conda.exe was not found under $dest."
    }
    $script:MinicondaInstalledThisRun = $true
    Write-Success "Miniconda3 installed at $dest"
    return [pscustomobject]@{ Exe = $exe; Prefix = $dest }
}

function Initialize-CondaToS {
    Write-Step "Accepting conda Terms of Service for Anaconda channels"
    $channels = @(
        "https://repo.anaconda.com/pkgs/main",
        "https://repo.anaconda.com/pkgs/r",
        "https://repo.anaconda.com/pkgs/msys2"
    )
    foreach ($channel in $channels) {
        & $script:CondaExe tos accept --override-channels --channel $channel 2>$null | Out-Null
    }
}

function Test-CondaEnvExists {
    param([string]$EnvName)
    $jsonText = & $script:CondaExe env list --json 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        $envPath = Join-Path $script:CondaPrefix "envs\$EnvName"
        return (Test-Path -LiteralPath $envPath)
    }
    try {
        $data = $jsonText | ConvertFrom-Json
        foreach ($entry in @($data.envs)) {
            if ([string]::IsNullOrWhiteSpace($entry)) {
                continue
            }
            if ((Split-Path -Path $entry -Leaf) -eq $EnvName) {
                return $true
            }
        }
    }
    catch {
        $envPath = Join-Path $script:CondaPrefix "envs\$EnvName"
        return (Test-Path -LiteralPath $envPath)
    }
    return $false
}

function Invoke-Conda {
    param([string[]]$CondaArgs)
    & $script:CondaExe @CondaArgs
    if ($LASTEXITCODE -ne 0) {
        Stop-Setup -Code 1 -Message "conda $($CondaArgs -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Invoke-EnvPip {
    param([string[]]$PipArgs)
    & $script:CondaExe run -n $script:EnvName --no-capture-output pip @PipArgs
    if ($LASTEXITCODE -ne 0) {
        Stop-Setup -Code 1 -Message "pip $($PipArgs -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Resolve-CudaVersionParts {
    param([string]$CudaVersion)
    $segments = $CudaVersion.Split(".")
    $major = [int]$segments[0]
    $minor = 0
    if ($segments.Length -gt 1) {
        $minor = [int]$segments[1]
    }
    return [pscustomobject]@{
        Major      = $major
        Minor      = $minor
        Normalized = "{0}.{1}" -f $major, $minor
    }
}

function Resolve-PyTorchPipTag {
    param([string]$CudaVersion)
    $parts = Resolve-CudaVersionParts -CudaVersion $CudaVersion
    if ($CUDA_PYTORCH_MAP.ContainsKey($parts.Normalized)) {
        return $CUDA_PYTORCH_MAP[$parts.Normalized]
    }
    if ($parts.Major -eq 12) {
        return "cu124"
    }
    if ($parts.Major -eq 11) {
        return "cu118"
    }
    return "cu124"
}

function Resolve-CuPyPipPackage {
    param([string]$CudaVersion)
    $parts = Resolve-CudaVersionParts -CudaVersion $CudaVersion
    $majorKey = $parts.Major.ToString()
    if ($CUPY_PIP_PACKAGES.ContainsKey($majorKey)) {
        return $CUPY_PIP_PACKAGES[$majorKey]
    }
    return $null
}

function Resolve-GpuSupport {
    Write-Step "Checking for NVIDIA GPU"
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        Write-Host "GPU not detected"
        $script:HasGpu = $false
        $script:TorchIndexUrl = "https://download.pytorch.org/whl/cpu"
        $script:CupyPackage = $null
        return
    }

    $query = $null
    $queryCode = 1
    try {
        $query = & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null
        $queryCode = $LASTEXITCODE
    }
    catch {
        $queryCode = 1
    }

    if ($queryCode -ne 0 -or [string]::IsNullOrWhiteSpace(($query | Out-String).Trim())) {
        Write-Host "GPU not detected"
        $script:HasGpu = $false
        $script:TorchIndexUrl = "https://download.pytorch.org/whl/cpu"
        $script:CupyPackage = $null
        return
    }

    $cudaVersion = $null
    try {
        $smiText = & nvidia-smi 2>$null | Out-String
        $match = [regex]::Match($smiText, "CUDA Version:\s*(\d+\.\d+)")
        if ($match.Success) {
            $cudaVersion = $match.Groups[1].Value
        }
    }
    catch {
        $cudaVersion = $null
    }

    if ([string]::IsNullOrWhiteSpace($cudaVersion)) {
        $cudaVersion = "12.4"
    }

    $tag = Resolve-PyTorchPipTag -CudaVersion $cudaVersion
    $script:HasGpu = $true
    $script:CudaVersion = $cudaVersion
    $script:TorchIndexUrl = "https://download.pytorch.org/whl/$tag"
    $script:CupyPackage = Resolve-CuPyPipPackage -CudaVersion $cudaVersion
    Write-Success "GPU detected ($(($query | Out-String).Trim())); CUDA $cudaVersion -> $tag"
}

function Expand-TemplateText {
    param([string]$Text)
    $expanded = $Text
    $expanded = $expanded.Replace("__PROJECT_NAME__", $script:ProjectName)
    $expanded = $expanded.Replace("__PACKAGE_NAME__", $script:PackageName)
    $expanded = $expanded.Replace("__ENV_NAME__", $script:EnvName)
    $expanded = $expanded.Replace("__PYTHON_VERSION__", $script:PythonVersion)
    return $expanded
}

function Write-FileFromTemplate {
    param(
        [string]$RelativePath,
        [string]$Content
    )
    $expandedPath = Expand-TemplateText -Text $RelativePath
    $destination = Join-Path $script:ProjectDir $expandedPath
    $parent = Split-Path -Path $destination -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $expanded = Expand-TemplateText -Text $Content
    Set-Content -Path $destination -Value $expanded -Encoding UTF8
}

function Write-ProjectFromTemplates {
    Write-Step "Writing project folder $($script:ProjectDir)"
    if (-not (Test-Path -LiteralPath $script:ProjectDir)) {
        New-Item -ItemType Directory -Path $script:ProjectDir -Force | Out-Null
    }

    $diskRoot = $null
    if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "template"))) {
        $diskRoot = Join-Path $PSScriptRoot "template"
    }

    if ($diskRoot) {
        Write-Info "Using template files from $diskRoot"
        $files = Get-ChildItem -LiteralPath $diskRoot -Recurse -File
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($diskRoot.Length).TrimStart("\", "/")
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            Write-FileFromTemplate -RelativePath $relative -Content $content
        }
        return
    }

    Write-Info "Using embedded template files (irm/gh launch)"
    $embedded = Get-EmbeddedTemplates
    foreach ($key in $embedded.Keys) {
        Write-FileFromTemplate -RelativePath $key -Content $embedded[$key]
    }
}

function Initialize-ProjectGitRepo {
    $gitDir = Join-Path $script:ProjectDir ".git"
    if (Test-Path -LiteralPath $gitDir) {
        Write-Info "Project already has a git repo; leaving it unchanged"
        return
    }
    Write-Step "Initializing git repository in $($script:ProjectName)"
    git -C $script:ProjectDir init | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "git init failed; continuing without a project repository"
    }
}

function Install-NeuroPyEditable {
    if (-not (Test-Path -LiteralPath $NEUROPY_PATH)) {
        Write-Step "Cloning neuro_py to $NEUROPY_PATH"
        $parent = Split-Path -Path $NEUROPY_PATH -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        git clone --depth 1 $NEUROPY_REPO $NEUROPY_PATH
        if ($LASTEXITCODE -ne 0) {
            Stop-Setup -Code 1 -Message "Failed to clone neuro_py."
        }
    }
    else {
        Write-Info "Using existing neuro_py at $NEUROPY_PATH"
    }

    Write-Step "Installing neuro_py editable (--no-deps)"
    Push-Location $NEUROPY_PATH
    try {
        Invoke-EnvPip -PipArgs @(
            "install", "-e", ".",
            "--no-deps",
            "--force-reinstall",
            "--no-cache-dir",
            "--no-input"
        )
    }
    finally {
        Pop-Location
    }
}

function Invoke-AgentkitBestEffort {
    if (-not (Test-Path -LiteralPath $AGENTKIT_INSTALL)) {
        Write-Host "agentkit was skipped (C:\GitHub\agentkit\install.py not found)"
        return
    }
    Write-Step "Running agentkit init"
    Push-Location $script:ProjectDir
    try {
        & $script:CondaExe run -n $script:EnvName --no-capture-output python $AGENTKIT_INSTALL init
        if ($LASTEXITCODE -ne 0) {
            Write-Host "agentkit was skipped (install.py init failed)"
        }
    }
    catch {
        Write-Host "agentkit was skipped ($($_.Exception.Message))"
    }
    finally {
        Pop-Location
    }
}

function Test-Imports {
    Write-Step "Checking imports"
    $expectGpu = "0"
    if ($script:HasGpu) {
        $expectGpu = "1"
    }
    $snippet = @"
import sys
import neuro_py
import torch
cuda = bool(torch.cuda.is_available())
print("neuro_py: import ok")
print("torch: %s" % torch.__version__)
print("torch.cuda.is_available: %s" % cuda)
if sys.argv[1] == "1" and not cuda:
    sys.exit(1)
"@
    $tempFile = Join-Path $env:TEMP ("analysis-import-check-" + [guid]::NewGuid().ToString() + ".py")
    Set-Content -Path $tempFile -Value $snippet -Encoding ASCII
    try {
        & $script:CondaExe run -n $script:EnvName --no-capture-output python $tempFile $expectGpu
        $code = $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) {
        if ($script:HasGpu) {
            Stop-Setup -Code 1 -Message "Import check failed: torch.cuda.is_available() is false on the GPU path."
        }
        Stop-Setup -Code 1 -Message "Import check failed."
    }
    Write-Success "Import check passed"
}

function Get-SetupAnswers {
    $projectDefault = $DEFAULT_PROJECT_NAME
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $projectDefault = $Name.Trim()
    }

    $pythonDefault = $DEFAULT_PYTHON_VERSION
    if (-not [string]::IsNullOrWhiteSpace($Python)) {
        $pythonDefault = $Python.Trim()
    }

    if ($Yes) {
        $project = $projectDefault
        $envDefault = $project
        if (-not [string]::IsNullOrWhiteSpace($EnvName)) {
            $envDefault = $EnvName.Trim()
        }
        return [pscustomobject]@{
            Project = $project
            Env     = $envDefault
            Python  = $pythonDefault
        }
    }

    $project = Read-ValueOrDefault -Prompt "Project name" -Default $projectDefault
    $envDefault = $project
    if (-not [string]::IsNullOrWhiteSpace($EnvName)) {
        $envDefault = $EnvName.Trim()
    }
    $env = Read-ValueOrDefault -Prompt "Environment name" -Default $envDefault
    $py = Read-ValueOrDefault -Prompt "Python version" -Default $pythonDefault
    return [pscustomobject]@{
        Project = $project
        Env     = $env
        Python  = $py
    }
}

# --- questions (all upfront) -------------------------------------------------
$answers = Get-SetupAnswers
$script:ProjectName = Get-SafeFolderName -Name $answers.Project
$script:PackageName = Get-SafePackageName -Name $script:ProjectName
$script:EnvName = $answers.Env.Trim()
if ([string]::IsNullOrWhiteSpace($script:EnvName)) {
    $script:EnvName = $script:ProjectName
}
$script:PythonVersion = $answers.Python.Trim()
if ([string]::IsNullOrWhiteSpace($script:PythonVersion)) {
    $script:PythonVersion = $DEFAULT_PYTHON_VERSION
}
$script:ProjectDir = Join-Path (Get-Location).Path $script:ProjectName

Write-Info "Project: $($script:ProjectName)"
Write-Info "Package: $($script:PackageName)"
Write-Info "Environment: $($script:EnvName)"
Write-Info "Python: $($script:PythonVersion)"

# --- locate conda (search only; install later if needed) ---------------------
$found = Find-CondaInstallation
$envAlreadyExists = $false
if ($found) {
    $script:CondaExe = $found.Exe
    $script:CondaPrefix = $found.Prefix
    Write-Info "Using conda at $($script:CondaExe)"
    $envAlreadyExists = Test-CondaEnvExists -EnvName $script:EnvName
}

$wipe = $false
if ($envAlreadyExists) {
    if ($Yes) {
        $wipe = $true
        Write-Info "Environment '$($script:EnvName)' exists; wipe accepted (-Yes)"
    }
    else {
        $wipeAnswer = Read-Host "Wipe and recreate? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($wipeAnswer) -or $wipeAnswer.Trim() -match "^[Yy]") {
            $wipe = $true
        }
        elseif ($wipeAnswer.Trim() -match "^[Nn]") {
            Stop-Setup -Code 0 -Message "Environment '$($script:EnvName)' was left unchanged."
            return
        }
        else {
            $wipe = $true
        }
    }
}

# --- unattended phase --------------------------------------------------------
if (-not $found) {
    $found = Install-Miniconda3
    $script:CondaExe = $found.Exe
    $script:CondaPrefix = $found.Prefix
}

Initialize-CondaToS
Resolve-GpuSupport

if ($wipe) {
    Write-Step "Removing existing environment $($script:EnvName)"
    Invoke-Conda -CondaArgs @("env", "remove", "-n", $script:EnvName, "-y")
}

Write-Step "Creating conda environment $($script:EnvName) (Python $($script:PythonVersion))"
Invoke-Conda -CondaArgs @("create", "--name", $script:EnvName, "python=$($script:PythonVersion)", "-y")
Write-Success "Environment '$($script:EnvName)' created"

Write-Step "Installing lean analysis stack"
$basePackages = @(
    $NUMPY_PIN,
    "scipy",
    "matplotlib",
    "scikit-learn",
    "pandas",
    "numba",
    "tqdm",
    "joblib",
    "seaborn",
    "scikit-image",
    "lazy-loader",
    "PyWavelets",
    "Bottleneck",
    "h5py",
    "hdf5storage",
    "pymatreader",
    "PyYAML"
)
Invoke-EnvPip -PipArgs (@("install", "--no-input", "--no-cache-dir") + $basePackages)

Write-Step "Installing nelpy (--no-deps)"
Invoke-EnvPip -PipArgs @(
    "install",
    "--no-deps",
    "--no-input",
    "--no-cache-dir",
    "nelpy @ git+https://github.com/nelpy/nelpy.git"
)

Install-NeuroPyEditable

Write-Step "Installing Jupyter kernel $($script:EnvName)"
Invoke-EnvPip -PipArgs @("install", "--no-input", "--no-cache-dir", "ipykernel")
& $script:CondaExe run -n $script:EnvName --no-capture-output python -m ipykernel install --user --name $script:EnvName --display-name $script:EnvName
if ($LASTEXITCODE -ne 0) {
    Stop-Setup -Code 1 -Message "Failed to register the Jupyter kernel."
}

Write-Step "Installing PyTorch last"
Invoke-EnvPip -PipArgs @(
    "install",
    "torch",
    "torchvision",
    "torchaudio",
    "--index-url",
    $script:TorchIndexUrl,
    "--no-cache-dir",
    "--no-input"
)
Write-Success "PyTorch installed from $($script:TorchIndexUrl)"

if ($script:HasGpu) {
    if ($script:CupyPackage) {
        Write-Step "Installing CuPy ($($script:CupyPackage))"
        Invoke-EnvPip -PipArgs @("install", $script:CupyPackage, "--no-cache-dir", "--no-input")
    }
    else {
        Write-Host "CuPy was skipped (no wheel mapping for CUDA $($script:CudaVersion))"
    }
}
else {
    Write-Host "CuPy was skipped (GPU-only)"
}

Write-ProjectFromTemplates
Initialize-ProjectGitRepo

Write-Step "Installing project editable"
Push-Location $script:ProjectDir
try {
    Invoke-EnvPip -PipArgs @("install", "-e", ".", "--no-input")
}
finally {
    Pop-Location
}

Invoke-AgentkitBestEffort
Test-Imports

Write-Host ""
Write-Host "Installation complete." -ForegroundColor Green
Write-Host ""
Write-Host "    conda activate $($script:EnvName)"
Write-Host "    cd .\$($script:ProjectName)"
Write-Host ""
if ($script:MinicondaInstalledThisRun) {
    Write-Host "Miniconda was installed this run. Open a new terminal so conda is on PATH."
}
