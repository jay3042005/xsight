# XSIGHT Flutter kiosk app — one-shot Windows build.
#
# Copy the project folder to the Windows laptop, then in PowerShell:
#
#     cd xsight\scripts
#     powershell -ExecutionPolicy Bypass -File build_windows_app.ps1
#
# Add -Run to launch the app after building instead of just producing the exe.
#
# What it does:
#   1. Checks for Flutter and the Visual Studio C++ toolchain, installing
#      whatever is missing via winget (asks before installing).
#   2. flutter pub get
#   3. flutter build windows --release
#   4. Prints the artifact folder to ship (exe + dlls + data\ together).
#
# Everything is printed as it goes — paste the full output back if any step
# fails and the fix can be made from the Linux side.

param(
    [switch]$Run,          # flutter run -d windows instead of building release
    [switch]$SkipInstall   # never install anything; only check and build
)

$ErrorActionPreference = 'Stop'
function Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Fail($msg)  { Write-Host "    $msg" -ForegroundColor Red; exit 1 }

# --- locate the project root (this script lives in <root>\scripts) ---------
$Root = Split-Path -Parent $PSScriptRoot
Step "Project root: $Root"
if (-not (Test-Path "$Root\pubspec.yaml")) {
    Fail "pubspec.yaml not found — run this script from inside the project copy."
}

# --- 1. Flutter SDK ---------------------------------------------------------
Step "Checking Flutter SDK"
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    # Not on PATH. Check the default install location before offering winget.
    $localFlutter = "$env:USERPROFILE\flutter\bin\flutter.bat"
    if (Test-Path $localFlutter) {
        $env:Path = "$env:USERPROFILE\flutter\bin;$env:Path"
        Ok "Found Flutter at $localFlutter (added to PATH for this session)"
    } elseif (-not $SkipInstall) {
        Step "Flutter not found — installing via winget (about 1 GB)"
        $answer = Read-Host "    Install Flutter now? [y/N]"
        if ($answer -match '^[Yy]') {
            winget install --id Flutter.Flutter --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) {
                Fail "winget install Flutter failed. Install manually from https://docs.flutter.dev/get-started/install/windows and re-run."
            }
            $env:Path = "$env:USERPROFILE\flutter\bin;$env:Path"
        } else {
            Fail "Flutter is required. Install from https://docs.flutter.dev/get-started/install/windows then re-run."
        }
    } else {
        Fail "Flutter not found (and -SkipInstall was given)."
    }
} else {
    Ok "Flutter on PATH: $($flutter.Source)"
}

Step "flutter doctor"
flutter doctor
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "    flutter doctor reported a problem. Read the lines above:" -ForegroundColor Yellow
    Write-Host "    - 'Visual Studio not installed' -> let this script install it (re-run without -SkipInstall), or see step 2" -ForegroundColor Yellow
    Write-Host "    - Android/Chrome toolchain warnings are IRRELEVANT for a Windows build" -ForegroundColor Yellow
}

# --- 2. Visual Studio C++ toolchain (the actual compiler for the exe) ------
Step "Checking Visual Studio C++ workload"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVs = $false
if (Test-Path $vswhere) {
    $hasVs = (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) -ne $null
}
if ($hasVs) {
    Ok "Visual Studio C++ toolchain present"
} elseif (-not $SkipInstall) {
    Step "Visual Studio C++ not found — installing VS Build Tools 2022 (large, several GB)"
    $answer = Read-Host "    Install now? [y/N]"
    if ($answer -match '^[Yy]') {
        winget install --id Microsoft.VisualStudio.2022.BuildTools `
            --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" `
            --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            Fail "VS Build Tools install failed. Install 'Desktop development with C++' from https://visualstudio.microsoft.com/downloads/ and re-run."
        }
        Ok "Installed. NOTE: open a NEW PowerShell window and re-run this script so the toolchain is detected."
        exit 0
    } else {
        Fail "The C++ toolchain is required to build the Windows app. Re-run and accept, or install manually."
    }
} else {
    Fail "Visual Studio C++ toolchain not found (and -SkipInstall was given)."
}

# --- 3. Build ---------------------------------------------------------------
Set-Location $Root
Step "flutter pub get"
flutter pub get
if ($LASTEXITCODE -ne 0) { Fail "pub get failed — paste the output above back for a fix." }

if ($Run) {
    Step "flutter run -d windows"
    flutter run -d windows
    exit $LASTEXITCODE
}

Step "flutter build windows --release (first build takes a few minutes)"
flutter build windows --release
if ($LASTEXITCODE -ne 0) { Fail "build failed — paste the full output above back for a fix." }

$Out = "$Root\build\windows\x64\runner\Release"
Step "BUILD OK"
Ok "App folder: $Out"
Write-Host ""
Write-Host "    Ship the WHOLE Release folder together (exe + dlls + data\)." -ForegroundColor Cyan
Write-Host "    Point the app's Settings at the backend, e.g. http://<linux-server-ip>:8000" -ForegroundColor Cyan
