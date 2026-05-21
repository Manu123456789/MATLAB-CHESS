# MATLAB-CHESS

Chess in MATLAB on a shared network drive.

## Stockfish Setup

This project uses the Stockfish chess engine.

Stockfish repository:  
https://github.com/official-stockfish/Stockfish

---

Do this for python path setup: $env:Path = "D:\Your\Path\To\python;D:\Your\Path\To\python\scripts;" + $env:Path


## Notes

- Replace `/path/to/Stockfish/Stockfish-master/src` with the actual location of the Stockfish `src` directory.
- The compiled Stockfish executable should be created in the `src` directory after the build completes.
- Make sure MATLAB has access to the shared network drive where the Stockfish executable is stored.

## Setup

This guide explains how to set up and run the Python version of the chess game on a new Windows machine, including Python setup, project dependencies, Stockfish setup, and shared-file network play.

## 1. Install Python

Install **Python 3.10 or newer**.

During installation, make sure to enable:

```text
Add Python to PATH
```

Verify the installation in Command Prompt or PowerShell:

```powershell
python --version
```

You should see something like:

```text
Python 3.10.x
```

or newer.

## 2. Unzip the Project

Unzip the project folder, for example:

```text
chessnet_stockfish_engine_fix.zip
```

Place it somewhere convenient, such as:

```text
C:\Users\<your-name>\Documents\chessnet_stockfish_engine_fix
```

The project folder should contain files/folders like:

```text
main.py
requirements.txt
chessnet\
assets\
tests\
README.md
```

Open PowerShell inside the project folder.

## 3. Create a Virtual Environment

From inside the project folder, run:

```powershell
python -m venv .venv
```

Activate the virtual environment:

```powershell
.venv\Scripts\activate
```

After activation, your terminal prompt should look something like:

```text
(.venv) PS C:\...\chessnet_stockfish_engine_fix>
```

## 4. Install Required Packages

With the virtual environment activated, run:

```powershell
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

This installs the required Python packages, including:

```text
PySide6
python-chess
watchdog
```

## 5. Run the Game

From the project folder, with the virtual environment still activated, run:

```powershell
python main.py
```

This should launch the ChessNet GUI.

## 6. Install Stockfish

Stockfish is **not bundled** with the project. You need to download the Stockfish executable separately.

After downloading Stockfish, note the location of the `.exe` file. For example:

```text
C:\Users\<your-name>\Downloads\stockfish\stockfish-windows-x86-64-avx2.exe
```

When launching the chess game, choose either:

```text
Play against Stockfish
```

or:

```text
Spectate with Stockfish
```

Then use the GUI to browse to the Stockfish executable.

The game saves Stockfish settings here:

```text
C:\Users\<your-name>\.chessnet_stockfish.json
```

This means you usually only need to enter the Stockfish path once.

## 7. Network / Shared-File Play

For two-player network play, both machines need access to the same shared JSON game file.

Recommended shared locations include:

```text
OneDrive shared folder
Google Drive synced folder
Dropbox
Network drive
Shared LAN folder
```

### Host Player

1. Choose **Host Game**.
2. Pick or create a shared game file, for example:

```text
C:\Users\<your-name>\OneDrive\ChessGames\game1.json
```

3. Choose your color and timer settings.

### Join Player

1. Choose **Join Game**.
2. Select the same shared JSON file.

After both players are connected to the same file, the clients should update automatically.

## 8. Optional: Run Tests

From the project folder, with the virtual environment activated, run:

```powershell
python -m tests.test_model
python -m tests.test_serialize
python -m tests.test_netgame
python -m tests.test_timer
python -m tests.test_premove_preview
python -m tests.test_history_analysis
python -m tests.test_engine
python -m tests.test_engine_options_dialog
```

## Quick Start Commands

```powershell
cd C:\path\to\chessnet_stockfish_engine_fix
python -m venv .venv
.venv\Scripts\activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python main.py
```

## Summary

To run the game on a new machine:

1. Install Python 3.10 or newer.
2. Unzip the project.
3. Create and activate a virtual environment.
4. Install dependencies from `requirements.txt`.
5. Run `python main.py`.
6. Download Stockfish separately and point the app to the Stockfish `.exe`.
7. For network play, make sure both players use the same shared JSON game file.
