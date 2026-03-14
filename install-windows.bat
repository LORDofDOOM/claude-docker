@echo off
setlocal

echo ============================================
echo  Claude Docker - Windows Global Tool Setup
echo ============================================
echo.

REM Navigate to the .NET project directory
cd /d "%~dp0src\windows\claude-docker-cli"

REM Clean old packages
if exist "%~dp0src\windows\claude-docker-cli\nupkg" del /q "%~dp0src\windows\claude-docker-cli\nupkg\*.nupkg"

REM Build and pack
echo Building and packing claude-docker-cli...
dotnet pack -c Release -o "%~dp0src\windows\claude-docker-cli\nupkg"
if errorlevel 1 (
    echo.
    echo [ERR] Build failed. Ensure .NET SDK 10+ is installed.
    pause
    exit /b 1
)

echo.
echo Installing as global tool...

REM Uninstall old version (if any), then install fresh
dotnet tool uninstall -g claude-docker-cli 2>nul
dotnet tool install -g claude-docker-cli --add-source "%~dp0src\windows\claude-docker-cli\nupkg" --prerelease
if errorlevel 1 (
    echo.
    echo [ERR] Tool installation failed.
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
echo  Command:  claude-docker
echo  Run from: Any directory
echo.
echo  Project root set to: %PROJECT_ROOT%
echo  Override with: set CLAUDE_DOCKER_PROJECT=path\to\claude-docker
echo.
echo  NOTE: Open a NEW terminal for changes to take effect.
echo.
pause
