# Build the XSIGHT server launcher exe on the build VM (run FROM the VM).
# Sync + kick-off happen from Linux (see build_windows_launcher.sh); this
# script is what actually runs on Windows.
param(
    [string]$Src = "C:\build\xslauncher",
    [string]$Out = "C:\build\xslauncher_out"
)

$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User") + ";C:\flutter\bin"

Set-Location $Src
Write-Host "==> flutter pub get"
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "pub get failed" }

Write-Host "==> flutter build windows --release"
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "build failed" }

Write-Host "==> package bundle"
Remove-Item -Recurse -Force $Out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Out | Out-Null
Copy-Item -Recurse "$Src\build\windows\x64\runner\Release\*" "$Out\"
Compress-Archive -Path "$Out\*" -DestinationPath "$Out\..\xsight_launcher_win.zip" -Force

Write-Host "==> bundle contents"
Get-ChildItem $Out | Select-Object Name, Length | Format-Table -AutoSize
Write-Host "OK: $Out\xsight_launcher.exe"
