#!/bin/bash
# Build the XSIGHT server launcher into a Windows .exe using the SSH build VM.
#
# Usage:  ./launcher/build_windows.sh
# Output: dist/XSIGHTServer.exe   (drop it in the client's server\ folder)
set -euo pipefail

VM="${VM:-builder@buildsrv.local}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="C:/build/xsight_launcher"
EXE_NAME="XSIGHTServer"
TMP_PS1="/tmp/opencode/xsight_build.ps1"

echo "=> Preparing $VM:$REMOTE"
ssh "$VM" "powershell -NoProfile -Command \"Remove-Item -Recurse -Force $REMOTE -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $REMOTE | Out-Null\""

echo "=> Copying launcher source + build script"
scp "$ROOT/launcher/xsight_launcher.py" "$VM:$REMOTE/"

cat > "$TMP_PS1" <<'PS1'
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
cd C:\build\xsight_launcher
python --version
pyinstaller --onefile --windowed --clean --noconfirm --name XSIGHTServer xsight_launcher.py
PS1
scp "$TMP_PS1" "$VM:$REMOTE/build.ps1"

echo "=> Building on Windows (pyinstaller onefile, windowed)"
ssh "$VM" "powershell -NoProfile -ExecutionPolicy Bypass -File $REMOTE/build.ps1"

mkdir -p "$ROOT/dist"
echo "=> Retrieving dist/$EXE_NAME.exe"
scp "$VM:$REMOTE/dist/$EXE_NAME.exe" "$ROOT/dist/"

ls -lh "$ROOT/dist/$EXE_NAME.exe"
file "$ROOT/dist/$EXE_NAME.exe"
