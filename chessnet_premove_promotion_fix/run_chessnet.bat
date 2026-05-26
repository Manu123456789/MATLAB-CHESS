@echo off
setlocal

cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
    echo ERROR: Python was not found.
    echo Install Python 3.10+ and check "Add Python to PATH" during install.
    pause
    exit /b 1
)

if not exist .venv (
    echo First run: creating local virtual environment...
    python -m venv .venv
    if errorlevel 1 goto :fail
)

call .venv\Scripts\activate.bat
if errorlevel 1 goto :fail

python -m pip show PySide6 >nul 2>nul
if errorlevel 1 (
    echo First run: installing ChessNet requirements...
    python -m pip install --upgrade pip
    if errorlevel 1 goto :fail
    python -m pip install -r requirements.txt
    if errorlevel 1 goto :fail
)

python main.py
exit /b 0

:fail
echo.
echo ERROR: Could not start ChessNet. Review the messages above.
echo.
pause
exit /b 1
