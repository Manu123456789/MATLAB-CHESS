@echo off
setlocal

cd /d "%~dp0"

echo ============================================================
echo Building ChessNet standalone Windows executable
echo ============================================================
echo.

where python >nul 2>nul
if errorlevel 1 (
    echo ERROR: Python was not found.
    echo Install Python 3.10+ and check "Add Python to PATH" during install.
    pause
    exit /b 1
)

if not exist .venv (
    echo Creating local virtual environment...
    python -m venv .venv
    if errorlevel 1 goto :fail
)

call .venv\Scripts\activate.bat
if errorlevel 1 goto :fail

echo Upgrading pip...
python -m pip install --upgrade pip
if errorlevel 1 goto :fail

echo Installing app requirements...
python -m pip install -r requirements.txt
if errorlevel 1 goto :fail

echo Installing build requirements...
python -m pip install -r requirements-build.txt
if errorlevel 1 goto :fail

echo Building single-file executable with PyInstaller...
pyinstaller --clean --noconfirm ChessNet.spec
if errorlevel 1 goto :fail

if not exist "%CD%\dist\ChessNet.exe" (
    echo ERROR: PyInstaller finished, but dist\ChessNet.exe was not found.
    goto :fail
)

echo Locating Desktop folder...
for /f "usebackq delims=" %%D in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "[Environment]::GetFolderPath('Desktop')"`) do set "DESKTOP_DIR=%%D"

if "%DESKTOP_DIR%"=="" (
    echo ERROR: Could not locate your Desktop folder.
    goto :fail
)

if not exist "%DESKTOP_DIR%" (
    echo ERROR: Desktop folder does not exist:
    echo   %DESKTOP_DIR%
    goto :fail
)

echo Copying ChessNet.exe to Desktop...
copy /Y "%CD%\dist\ChessNet.exe" "%DESKTOP_DIR%\ChessNet.exe" >nul
if errorlevel 1 (
    echo ERROR: Could not copy ChessNet.exe to Desktop.
    echo Check whether the Desktop folder is writable or controlled by OneDrive/security settings.
    goto :fail
)

echo.
echo ============================================================
echo Build complete.
echo Your clickable app was created here:
echo   %DESKTOP_DIR%\ChessNet.exe
echo.
echo A backup build output is also here:
echo   %CD%\dist\ChessNet.exe
echo ============================================================
echo.
pause
exit /b 0

:fail
echo.
echo ERROR: Build failed. Review the messages above.
echo.
pause
exit /b 1
