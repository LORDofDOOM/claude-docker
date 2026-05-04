@echo off
setlocal

echo ============================================
echo  Claude Code statusline (Windows, opt-in)
echo ============================================
echo.
echo This wires the enhanced statusline (model, cost, context bar, git branch,
echo plan usage) into your native Windows Claude Code via %%USERPROFILE%%\.claude\settings.json.
echo Re-run this file at any time to refresh the path. Use --uninstall to remove.
echo.

set "STATUSLINE_PS1=%~dp0src\statusline.ps1"
if not exist "%STATUSLINE_PS1%" (
    echo [ERR] Cannot find %STATUSLINE_PS1%
    pause
    exit /b 1
)

if /I "%~1"=="--uninstall" (
    set MODE=uninstall
) else (
    set MODE=install
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ps = '%STATUSLINE_PS1%';" ^
    "$mode = '%MODE%';" ^
    "$settingsPath = Join-Path $HOME '.claude\settings.json';" ^
    "$dir = Split-Path -Parent $settingsPath;" ^
    "if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }" ^
    "if (Test-Path $settingsPath) { try { $obj = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch { $obj = [pscustomobject]@{} } } else { $obj = [pscustomobject]@{} };" ^
    "if ($mode -eq 'uninstall') {" ^
    "  if ($obj.PSObject.Properties.Match('statusLine').Count) { $obj.PSObject.Properties.Remove('statusLine') };" ^
    "  Write-Host '[OK] Removed statusLine from' $settingsPath" ^
    "} else {" ^
    "  $cmd = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"' + $ps + '\"';" ^
    "  $sl = [pscustomobject]@{ type = 'command'; command = $cmd };" ^
    "  if ($obj.PSObject.Properties.Match('statusLine').Count) { $obj.statusLine = $sl } else { $obj | Add-Member -NotePropertyName statusLine -NotePropertyValue $sl };" ^
    "  Write-Host '[OK] Wired statusline ->' $cmd" ^
    "};" ^
    "$obj | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8;" ^
    "Write-Host '[OK] Wrote' $settingsPath"

if errorlevel 1 (
    echo.
    echo [ERR] Statusline configuration failed.
    pause
    exit /b 1
)

echo.
echo ============================================
echo  Done. Restart Claude Code to see the change.
echo ============================================
echo.
pause
