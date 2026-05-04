@echo off
setlocal

echo ============================================
echo  Claude Code statusline - Uninstall (Windows)
echo ============================================
echo.
echo Removes the statusLine entry from %%USERPROFILE%%\.claude\settings.json.
echo Other keys in settings.json are left untouched.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$settingsPath = Join-Path $HOME '.claude\settings.json';" ^
    "if (-not (Test-Path $settingsPath)) { Write-Host '[OK] No settings.json present at' $settingsPath '- nothing to remove.'; exit 0 };" ^
    "try { $obj = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch { Write-Host '[!] Could not parse' $settingsPath; exit 1 };" ^
    "if ($obj.PSObject.Properties.Match('statusLine').Count) {" ^
    "  $obj.PSObject.Properties.Remove('statusLine');" ^
    "  $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8;" ^
    "  Write-Host '[OK] Removed statusLine from' $settingsPath" ^
    "} else {" ^
    "  Write-Host '[OK] No statusLine entry in' $settingsPath '- nothing to remove.'" ^
    "}"

if errorlevel 1 (
    echo.
    echo [ERR] Uninstall failed.
    pause
    exit /b 1
)

echo.
echo ============================================
echo  Done. Restart Claude Code to drop the statusline.
echo ============================================
echo.
pause
