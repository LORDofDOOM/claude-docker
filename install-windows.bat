@echo off
setlocal

echo ============================================
echo  Claude / OpenCode Docker - Windows Setup
echo ============================================
echo.

REM ── claude-docker-cli ─────────────────────────────────────────────
cd /d "%~dp0src\windows\claude-docker-cli"

if exist "%~dp0src\windows\claude-docker-cli\nupkg" del /q "%~dp0src\windows\claude-docker-cli\nupkg\*.nupkg"

echo Building and packing claude-docker-cli...
dotnet pack -c Release -o "%~dp0src\windows\claude-docker-cli\nupkg"
if errorlevel 1 (
    echo.
    echo [ERR] claude-docker-cli build failed. Ensure .NET SDK 10+ is installed.
    pause
    exit /b 1
)

echo.
echo Installing claude-docker as global tool...
dotnet tool uninstall -g claude-docker-cli 2>nul
dotnet tool install -g claude-docker-cli --add-source "%~dp0src\windows\claude-docker-cli\nupkg" --prerelease
if errorlevel 1 (
    echo.
    echo [ERR] claude-docker-cli installation failed.
    pause
    exit /b 1
)

REM ── opencode-docker-cli (sister tool) ─────────────────────────────
cd /d "%~dp0src\windows\opencode-docker-cli"

if exist "%~dp0src\windows\opencode-docker-cli\nupkg" del /q "%~dp0src\windows\opencode-docker-cli\nupkg\*.nupkg"

echo.
echo Building and packing opencode-docker-cli...
dotnet pack -c Release -o "%~dp0src\windows\opencode-docker-cli\nupkg"
if errorlevel 1 (
    echo.
    echo [ERR] opencode-docker-cli build failed.
    pause
    exit /b 1
)

echo.
echo Installing opencode-docker as global tool...
dotnet tool uninstall -g opencode-docker-cli 2>nul
dotnet tool install -g opencode-docker-cli --add-source "%~dp0src\windows\opencode-docker-cli\nupkg" --prerelease
if errorlevel 1 (
    echo.
    echo [ERR] opencode-docker-cli installation failed.
    pause
    exit /b 1
)

REM Set CLAUDE_DOCKER_PROJECT so the tool can find the repo
echo.
echo Setting CLAUDE_DOCKER_PROJECT environment variable...
REM %~dp0 is the repo root (where this .bat lives), strip trailing backslash
set "PROJECT_ROOT=%~dp0"
if "%PROJECT_ROOT:~-1%"=="\" set "PROJECT_ROOT=%PROJECT_ROOT:~0,-1%"
setx CLAUDE_DOCKER_PROJECT "%PROJECT_ROOT%" >nul 2>nul

echo.
echo ============================================
echo  Installation complete!
echo ============================================
echo.
echo  Commands: claude-docker        (Claude Code in Docker)
echo            opencode-docker      (OpenCode in Docker)
echo            claude-docker --tool opencode  (alternative form)
echo  Run from: Any directory
echo.
echo  Project root set to: %PROJECT_ROOT%
echo  Override with: set CLAUDE_DOCKER_PROJECT=path\to\claude-docker
echo.
echo  NOTE: Open a NEW terminal for changes to take effect.
echo.
pause
