# analysis-project

This repository sets up a Python analysis environment on your machine. It installs Miniconda if you do not already have Conda, creates a Conda environment, installs the core scientific packages and neuro_py, then PyTorch (CUDA when an NVIDIA GPU and driver are present, CPU otherwise), and writes a small Python project you can edit. It asks its questions first, then runs on its own. Press Enter to accept each default: project name analysis, environment name analysis, and Python 3.12.

## Windows

Paste this command in PowerShell. It installs that environment and writes the project.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/PraPaudel/analysis-project/main/setup.ps1 | iex"
```

## macOS and Linux

macOS and Linux use the same command. Paste it in a terminal.

```bash
curl -fsSL https://raw.githubusercontent.com/PraPaudel/analysis-project/main/setup.sh | bash
```

## What gets installed

- Miniconda, if Conda is not already on the machine
- A Conda environment
- numpy, scipy, pandas, and the other neuro_py base packages
- neuro_py itself from the ayalab1 checkout, with `pip install -e .`
- PyTorch
- CuPy only when a GPU is detected
- A new script project (package, tests, results, docs, data)

No notebooks. Nothing is pushed to GitHub.
