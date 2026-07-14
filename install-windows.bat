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

REM ── codex-docker-cli (sister tool) ────────────────────────────────
cd /d "%~dp0src\windows\codex-docker-cli"

if exist "%~dp0src\windows\codex-docker-cli\nupkg" del /q "%~dp0src\windows\codex-docker-cli\nupkg\*.nupkg"

echo.
echo Building and packing codex-docker-cli...
dotnet pack -c Release -o "%~dp0src\windows\codex-docker-cli\nupkg"
if errorlevel 1 (
    echo.
    echo [ERR] codex-docker-cli build failed.
    pause
    exit /b 1
)

echo.
echo Installing codex-docker as global tool...
dotnet tool uninstall -g codex-docker-cli 2>nul
dotnet tool install -g codex-docker-cli --add-source "%~dp0src\windows\codex-docker-cli\nupkg" --prerelease
if errorlevel 1 (
    echo.
    echo [ERR] codex-docker-cli installation failed.
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

REM ── Native host runtimes (Claude Code, OpenCode, Codex) ───────────
REM These back the native (non-Docker) context-menu entries. Re-running
REM the installers updates each tool to the latest release. Failures are
REM non-fatal — Docker mode does not need the native CLIs. Comment out this
REM whole section if you only want the Docker wrappers.
echo.
echo ============================================
echo  Installing / updating native host runtimes
echo ============================================

echo.
echo [1/3] Claude Code (native, claude.ai/install.ps1)...
powershell -ExecutionPolicy Bypass -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"
if errorlevel 1 echo [!] Claude Code native install/update failed (skipping) - Docker mode still works.

echo.
echo [2/3] OpenCode (native, npm i -g opencode-ai)...
where npm >nul 2>nul
if errorlevel 1 (
    echo [!] npm not found - skipping native OpenCode. Install Node.js to enable it.
) else (
    call npm install -g opencode-ai
    if errorlevel 1 echo [!] OpenCode native install/update failed (skipping).
)

echo.
echo [3/3] Codex CLI (native, chatgpt.com/codex/install.ps1)...
powershell -ExecutionPolicy Bypass -NoProfile -Command "$env:CODEX_NON_INTERACTIVE='1'; irm https://chatgpt.com/codex/install.ps1 | iex"
if errorlevel 1 echo [!] Codex native install/update failed (skipping).

echo.
echo ============================================
echo  Installation complete!
echo ============================================
echo.
echo  Docker:   claude-docker        (Claude Code in Docker)
echo            opencode-docker      (OpenCode in Docker)
echo            codex-docker         (Codex CLI in Docker)
echo            claude-docker --tool opencode^|codex  (alternative form)
echo  Native:   claude / opencode / codex  (host runtimes, updated above)
echo  Run from: Any directory
echo.
echo  Project root set to: %PROJECT_ROOT%
echo  Override with: set CLAUDE_DOCKER_PROJECT=path\to\claude-docker
echo.
echo  NOTE: Open a NEW terminal for changes to take effect.
echo.
pause
