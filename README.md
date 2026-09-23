# analysis-project

This repository sets up a Python analysis environment. It installs [Miniconda](https://docs.anaconda.com/miniconda/) if [Conda](https://docs.conda.io/) is missing, creates the environment, installs [NumPy](https://numpy.org/), [SciPy](https://scipy.org/), [pandas](https://pandas.pydata.org/), and the rest of the [neuro_py](https://github.com/ayalab1/neuro_py) base stack, installs neuro_py editable, then [PyTorch](https://pytorch.org/), and [CuPy](https://cupy.dev/) when an NVIDIA GPU and driver are present. Press Enter to accept the defaults: project name analysis, environment name analysis, and Python 3.12.

## Windows

Paste this command in PowerShell.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/PraPaudel/analysis-project/main/setup.ps1 | iex"
```

## macOS and Linux

Paste this command in a terminal.

```bash
curl -fsSL https://raw.githubusercontent.com/PraPaudel/analysis-project/main/setup.sh | bash
```
