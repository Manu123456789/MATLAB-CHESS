@echo off
setlocal

REM ChessNet source launcher.
REM First run: creates .venv and installs requirements.txt.
REM Later runs: skips dependency checks and immediately launches the app.

cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" goto SETUP
if not exist ".venv\.chessnet_requirements_installed" goto SETUP

goto RUN

:SETUP
echo Setting up ChessNet Python environment. This may take a few minutes on first run...
python --version >nul 2>&1
if errorlevel 1 (
    echo Python was not found. Please install Python 3.10 or newer and enable "Add Python to PATH".
    pause
    exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
    python -m venv .venv
    if errorlevel 1 (
        echo Failed to create the virtual environment.
        pause
        exit /b 1
    )
)

".venv\Scripts\python.exe" -m pip install --upgrade pip
if errorlevel 1 (
    echo Failed to upgrade pip.
    pause
    exit /b 1
)

".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 (
    echo Failed to install requirements.txt.
    pause
    exit /b 1
)

echo installed> ".venv\.chessnet_requirements_installed"

:RUN
".venv\Scripts\python.exe" main.py
if errorlevel 1 (
    echo ChessNet exited with an error.
    pause
    exit /b 1
)

endlocal
