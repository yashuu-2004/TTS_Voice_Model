#requires -Version 5.1
<#
.SYNOPSIS
One-command setup and launcher for the local IndicF5 Telugu Voice Lab on Windows.

.DESCRIPTION
Creates/reuses .venv, installs the pinned runtime, downloads the gated IndicF5
weights, and starts the Voice Lab.  The model is gated on Hugging Face; after
accepting the terms once, set HF_TOKEN or run `hf auth login`.
#>
[CmdletBinding()]
param(
    [switch]$NoBrowser,
    [switch]$SetupOnly,
    [switch]$SkipInstall,
    [switch]$SkipModels,
    [int]$Port = 0,
    [string]$Device = "",
    [string]$Venv = "",
    [string]$Python = "",
    [Alias("h")]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$Root = $PSScriptRoot
if (-not $Root) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
Set-Location -LiteralPath $Root

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Show-Usage {
    @'
Usage: .\run.ps1 [options]

Creates/reuses .venv, installs the pinned runtime, caches the gated IndicF5
weights, and starts the Telugu Voice Lab at http://127.0.0.1:7860.

Options:
  -NoBrowser       Do not try to open a browser (useful on servers/SSH).
  -Port PORT       Voice Lab port (default: 7860).
  -Device DEVICE   auto, cpu, cuda, or cuda:N (default: auto).
  -SetupOnly       Install dependencies and cache weights, then exit.
  -SkipInstall     Reuse an existing virtualenv; do not run pip.
  -SkipModels      Reuse cached weights; do not contact Hugging Face.
  -Venv PATH       Virtualenv directory (default: .venv).
  -Python PATH     64-bit Python 3.11 or 3.12 executable to use.
  -Help            Show this message.

Environment:
  HF_TOKEN         Hugging Face token with access to ai4bharat/IndicF5.
                   A token saved by `hf auth login` is also used.
  TTS_VENV         Override the virtualenv directory.
  TTS_PYTHON       Override the Python executable.
  VOICE_LAB_PORT   Override the UI port.
  TTS_DEVICE       Override the inference device.
  TTS_TORCH_INDEX_URL
                   Override the PyTorch wheel index.

One-time prerequisite:
  Accept the terms at https://huggingface.co/ai4bharat/IndicF5, then either
  set HF_TOKEN or run `hf auth login`.  This script does not bypass gated-model
  access.

Windows needs a shared FFmpeg build (the separate DLLs, not just ffmpeg.exe) so
TorchCodec can decode audio. The script installs it with winget or Chocolatey
when missing; otherwise it prints the exact command.

The easiest Windows entry point is run.bat, which invokes this script with an
ExecutionPolicy bypass for the current process.
'@ | Write-Host
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
    }
}

function Test-PythonVersion {
    param([hashtable]$Candidate)
    $prefix = @($Candidate.Prefix)
    & $Candidate.Exe @prefix -c 'import sys; raise SystemExit(0 if sys.version_info[:2] in ((3, 11), (3, 12)) and sys.maxsize > 2**32 else 1)' 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Find-Python {
    param([string]$Requested)

    if ($Requested) {
        $commands = @(Get-Command -Name $Requested -CommandType Application -All -ErrorAction SilentlyContinue)
        if ($commands.Count -eq 0 -and (Test-Path -LiteralPath $Requested)) {
            $commands = @([pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Requested).Path })
        }
        if ($commands.Count -eq 0) {
            throw "Python executable not found: $Requested"
        }
        foreach ($command in $commands) {
            $candidate = @{ Exe = $command.Path; Prefix = @() }
            if (Test-PythonVersion -Candidate $candidate) {
                return $candidate
            }
        }
        throw "64-bit Python 3.11 or 3.12 is required; $Requested is not supported."
    }

    $candidates = @(
        @{ Exe = "py"; Prefix = @("-3.12") },
        @{ Exe = "py"; Prefix = @("-3.11") },
        @{ Exe = "python3.12"; Prefix = @() },
        @{ Exe = "python"; Prefix = @() }
    )

    foreach ($entry in $candidates) {
        $commands = @(Get-Command -Name $entry.Exe -CommandType Application -All -ErrorAction SilentlyContinue)
        foreach ($command in $commands) {
            $candidate = @{ Exe = $command.Path; Prefix = @($entry.Prefix) }
            if (Test-PythonVersion -Candidate $candidate) {
                return $candidate
            }
        }
    }

    throw "64-bit Python 3.11 or 3.12 was not found. Install Python 3.12 from python.org, enable the py launcher, or pass -Python PATH."
}

function Update-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($machine, $user) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($parts.Count -gt 0) {
        $env:Path = "$env:Path;$($parts -join ';')"
    }
    if ($env:LOCALAPPDATA) {
        $wingetLinks = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"
        if (Test-Path -LiteralPath $wingetLinks) {
            $env:Path = "$wingetLinks;$env:Path"
        }
    }
}

function Test-FfmpegShared {
    param([string]$FfmpegPath)
    $directory = Split-Path -Parent $FfmpegPath
    if (-not $directory) {
        return $false
    }
    $dll = Get-ChildItem -LiteralPath $directory -Filter "avcodec-*.dll" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return [bool]$dll
}

function Find-Ffmpeg {
    $candidates = @()
    $commands = @(Get-Command ffmpeg.exe -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if ($command.Path -and $candidates -notcontains $command.Path) {
            $candidates += $command.Path
        }
    }

    $searchRoots = @()
    if ($env:LOCALAPPDATA) {
        $searchRoots += (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages")
    }
    if ($env:ProgramFiles) {
        $searchRoots += (Join-Path $env:ProgramFiles "WinGet\Packages")
    }
    if ($env:ProgramData) {
        $searchRoots += (Join-Path $env:ProgramData "chocolatey\lib")
    }
    if ($env:USERPROFILE) {
        $searchRoots += (Join-Path $env:USERPROFILE "scoop\apps")
    }

    foreach ($searchRoot in $searchRoots) {
        if (-not (Test-Path -LiteralPath $searchRoot)) {
            continue
        }
        $found = @(Get-ChildItem -LiteralPath $searchRoot -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
        foreach ($candidate in $found) {
            if ($candidates -notcontains $candidate) {
                $candidates += $candidate
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-FfmpegShared -FfmpegPath $candidate) {
            $directory = Split-Path -Parent $candidate
            if ($directory) {
                $env:Path = "$directory;$env:Path"
            }
            return $candidate
        }
    }
    return $null
}

function Ensure-Ffmpeg {
    $ffmpeg = Find-Ffmpeg
    if ($ffmpeg) {
        return $ffmpeg
    }

    Write-Step "A shared FFmpeg build is missing; attempting to install it."
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($winget) {
        & $winget.Path install --id Gyan.FFmpeg.Shared --exact --silent --accept-package-agreements --accept-source-agreements
        Update-ProcessPath
        $ffmpeg = Find-Ffmpeg
        if ($ffmpeg) {
            return $ffmpeg
        }
    }

    $choco = Get-Command choco.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($choco) {
        & $choco.Path install ffmpeg-shared -y
        Update-ProcessPath
        $ffmpeg = Find-Ffmpeg
        if ($ffmpeg) {
            return $ffmpeg
        }
    }

    throw "A shared FFmpeg build is required for TorchCodec. Install it with: winget install --id Gyan.FFmpeg.Shared -e (or choco install ffmpeg-shared -y), then rerun."
}

try {
    if ($Help) {
        Show-Usage
        exit 0
    }

    if ($env:OS -ne "Windows_NT") {
        throw "run.ps1 is for Windows. Use ./run.sh on macOS or Linux."
    }

    if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
        throw "Windows x64 is required for the pinned PyTorch wheels. Detected: $env:PROCESSOR_ARCHITECTURE"
    }

    if ($Port -eq 0) {
        if ($env:VOICE_LAB_PORT -and $env:VOICE_LAB_PORT -ne "") {
            $parsedPort = 0
            if (-not [int]::TryParse($env:VOICE_LAB_PORT, [ref]$parsedPort)) {
                throw "VOICE_LAB_PORT must be a number, got: $env:VOICE_LAB_PORT"
            }
            $Port = $parsedPort
        } else {
            $Port = 7860
        }
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "PORT must be between 1 and 65535"
    }

    if (-not $Device) {
        if ($env:TTS_DEVICE) {
            $Device = $env:TTS_DEVICE
        } else {
            $Device = "auto"
        }
    }
    if ($Device -notmatch '^(auto|cpu|cuda(:[0-9]+)?)$') {
        throw "DEVICE must be auto, cpu, cuda, or cuda:N (got: $Device)"
    }

    if (-not $Venv) {
        if ($env:TTS_VENV) {
            $Venv = $env:TTS_VENV
        } else {
            $Venv = Join-Path $Root ".venv"
        }
    }
    if (-not $Python -and $env:TTS_PYTHON) {
        $Python = $env:TTS_PYTHON
    }
    if ($env:VOICE_LAB_NO_BROWSER -and $env:VOICE_LAB_NO_BROWSER -ne "0") {
        $NoBrowser = $true
    }

    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "Git for Windows is required to install the pinned IndicF5/F5-TTS source package."
    }

    try {
        $driveName = (Get-Item -LiteralPath $Root).PSDrive.Name
        $freeBytes = (Get-PSDrive -Name $driveName).Free
        if ($freeBytes -lt 5GB) {
            throw "At least 5 GB of free disk space is required; found approximately $([math]::Round($freeBytes / 1GB, 1)) GB."
        }
    } catch {
        # A UNC path may not have a PSDrive; let the installer report any real
        # disk-space failure instead of rejecting a valid mounted directory.
        if ($_.Exception.Message -like "At least 5 GB*") {
            throw
        }
    }

    $pythonInfo = Find-Python -Requested $Python
    $pythonPrefix = @($pythonInfo.Prefix)
    Write-Step "Using Python: $(& $pythonInfo.Exe @pythonPrefix --version 2>&1)"

    [void](Ensure-Ffmpeg)

    $venvPython = Join-Path $Venv "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        if ($SkipInstall) {
            throw "$Venv has no usable Python. Omit -SkipInstall or choose another -Venv."
        }
        Write-Step "Creating virtualenv at $Venv"
        $venvArgs = @($pythonInfo.Prefix) + @("-m", "venv", $Venv)
        Invoke-Checked -FilePath $pythonInfo.Exe -ArgumentList $venvArgs
    }

    & $venvPython -c 'import sys; raise SystemExit(0 if sys.version_info[:2] in ((3, 11), (3, 12)) and sys.maxsize > 2**32 else 1)' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "$Venv uses an unsupported Python. Remove it or set -Venv to a fresh path."
    }

    $marker = Join-Path $Venv ".tts-quickstart-ready-v1"
    $needsInstall = $false
    if (-not (Test-Path -LiteralPath $marker)) {
        $needsInstall = $true
    } else {
        $markerTime = (Get-Item -LiteralPath $marker).LastWriteTimeUtc
        foreach ($relative in @("requirements.txt", "requirements-core.txt", "requirements-api.txt")) {
            $requirement = Join-Path $Root $relative
            if ((Get-Item -LiteralPath $requirement).LastWriteTimeUtc -gt $markerTime) {
                $needsInstall = $true
                break
            }
        }
    }
    if ($SkipInstall) {
        $needsInstall = $false
        & $venvPython -c 'import torch, gradio, f5_tts, soundfile, torchcodec' 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "The existing virtualenv is incomplete. Rerun without -SkipInstall."
        }
    }

    if ($needsInstall) {
        Write-Step "Installing/updating Python packages (this can take several minutes)..."
        $env:PIP_NO_INPUT = "1"
        $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"

        Invoke-Checked -FilePath $venvPython -ArgumentList @(
            "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"
        )

        $torchIndex = $env:TTS_TORCH_INDEX_URL
        if (-not $torchIndex) {
            $nvidia = Get-Command nvidia-smi.exe -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($nvidia) {
                & $nvidia.Path -L *> $null
                if ($LASTEXITCODE -eq 0) {
                    $torchIndex = "https://download.pytorch.org/whl/cu128"
                    Write-Step "NVIDIA GPU detected; installing CUDA PyTorch wheels."
                }
            }
            if (-not $torchIndex) {
                $torchIndex = "https://download.pytorch.org/whl/cpu"
                Write-Step "No NVIDIA GPU detected; installing CPU PyTorch wheels."
            }
        }

        Invoke-Checked -FilePath $venvPython -ArgumentList @(
            "-m", "pip", "install", "--index-url", $torchIndex,
            "torch==2.11.0", "torchaudio==2.11.0"
        )
        Invoke-Checked -FilePath $venvPython -ArgumentList @(
            "-m", "pip", "install", "-r", (Join-Path $Root "requirements.txt")
        )

        $verify = @'
import os
import tempfile
import wave

import torch
import torchaudio
import torchcodec
from torchcodec.decoders import AudioDecoder
import gradio
import f5_tts
import soundfile

check_path = os.path.join(tempfile.gettempdir(), f"tts-ffmpeg-check-{os.getpid()}.wav")
try:
    with wave.open(check_path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(24000)
        handle.writeframes(b"\0\0" * 2400)
    decoded = AudioDecoder(check_path).get_all_samples()
    assert decoded.sample_rate == 24000
    assert decoded.data.shape[-1] == 2400
finally:
    try:
        os.unlink(check_path)
    except OSError:
        pass

print(f"PyTorch {torch.__version__}, torchaudio {torchaudio.__version__}, Gradio {gradio.__version__}")
'@
        # Run the verification as a temporary .py file instead of passing
        # multiline Python source through PowerShell's native -c argument.
        # This avoids quote/backslash corruption in Windows PowerShell 5.1.
        $verifyPath = Join-Path ([IO.Path]::GetTempPath()) ("tts-runtime-check-{0}.py" -f [guid]::NewGuid().ToString("N"))
        try {
            [IO.File]::WriteAllText(
                $verifyPath,
                $verify,
                (New-Object System.Text.UTF8Encoding($false))
            )
            Invoke-Checked -FilePath $venvPython -ArgumentList @($verifyPath)
        } finally {
            Remove-Item -LiteralPath $verifyPath -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Path $marker -Force | Out-Null
    }

    $outputs = Join-Path $Root "outputs"
    $references = Join-Path $Root "references"
    $cache = Join-Path $Root "cache"
    New-Item -ItemType Directory -Force -Path $outputs, $references, $cache | Out-Null

    if (-not $SkipModels) {
        Write-Step "Caching IndicF5 and Vocos weights (first run: about 1.5 GB)..."
        Remove-Item Env:HF_HUB_OFFLINE -ErrorAction SilentlyContinue
        Remove-Item Env:TRANSFORMERS_OFFLINE -ErrorAction SilentlyContinue
        try {
            Invoke-Checked -FilePath $venvPython -ArgumentList @(
                "-m", "tts.setup_models", "--skip-transliterator"
            )
        } catch {
            Write-Host ""
            Write-Host "Hugging Face model setup failed." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "The IndicF5 model is gated. One-time setup is required:"
            Write-Host "  1. Sign in at https://huggingface.co/ai4bharat/IndicF5"
            Write-Host "  2. Accept the model terms."
            Write-Host "  3. Set a token with access: `$env:HF_TOKEN = 'hf_...'"
            Write-Host "     Or run: hf auth login"
            Write-Host "  4. Rerun: .\run.ps1"
            Write-Host ""
            Write-Host "The script never bypasses the gated-model agreement and never prints the token."
            Write-Host "If the weights are already cached, rerun with -SkipModels."
            exit 3
        }
    }

    if ($SetupOnly) {
        Write-Step "Setup complete. Model assets and the Python environment are ready."
        exit 0
    }

    $venvScripts = Join-Path $Venv "Scripts"
    $env:Path = "$venvScripts;$env:Path"
    $env:GRADIO_ANALYTICS_ENABLED = "False"
    $env:HF_HUB_OFFLINE = "1"
    $env:TRANSFORMERS_OFFLINE = "1"
    $env:TTS_DEVICE = $Device
    $env:VOICE_LAB_PORT = "$Port"
    $env:PYTHONUNBUFFERED = "1"
    if ($NoBrowser) {
        $env:VOICE_LAB_NO_BROWSER = "1"
    }

    Write-Step "Starting Telugu Voice Lab on http://127.0.0.1:$Port"
    Write-Host "First generation loads IndicF5 and is slower; later generations reuse the loaded model."
    Write-Host "Press Ctrl-C to stop."

    & $venvPython (Join-Path $Root "voice_lab_app.py")
    exit $LASTEXITCODE
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
