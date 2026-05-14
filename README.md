# MATLAB-CHESS

Chess in MATLAB on a shared network drive.

## Stockfish Setup

This project uses the Stockfish chess engine.

Stockfish repository:  
https://github.com/official-stockfish/Stockfish

---

## Notes

- Replace `/path/to/Stockfish/Stockfish-master/src` with the actual location of the Stockfish `src` directory.
- The compiled Stockfish executable should be created in the `src` directory after the build completes.
- Make sure MATLAB has access to the shared network drive where the Stockfish executable is stored.

## Setup
1. Install Python

Install Python 3.10 or newer from the official Python website or Microsoft Store.

During installation, make sure you check:

Add Python to PATH

Then verify it in Command Prompt or PowerShell:

python --version

You should see something like:

Python 3.10.x

or newer.

2. Unzip the chess project

Unzip:

chessnet_stockfish_engine_fix.zip

For example, put it somewhere like:

C:\Users\<your-name>\Documents\chessnet_stockfish_engine_fix

Open PowerShell in that folder. The folder should contain:

main.py
requirements.txt
chessnet\
assets\
tests\
README.md
3. Create a virtual environment

From inside the project folder:

python -m venv .venv

Activate it:

.venv\Scripts\activate

Your prompt should now show something like:

(.venv) PS C:\...\chessnet_stockfish_engine_fix>
4. Install required Python packages

Run:

python -m pip install --upgrade pip
python -m pip install -r requirements.txt

This installs:

PySide6
python-chess
watchdog
5. Run the chess game

From the same activated environment:

python main.py

That should launch the GUI.

6. Install Stockfish separately

Stockfish is not bundled with the project. Download the Stockfish executable separately, then remember where the .exe is located.

For example:

C:\Users\<your-name>\Downloads\stockfish\stockfish-windows-x86-64-avx2.exe

When you open the chess game and choose Play against Stockfish or Spectate with Stockfish, use the GUI to browse to that executable.

The game saves the engine path/settings here:

C:\Users\<your-name>\.chessnet_stockfish.json

So you should not need to re-enter the path every time.

7. Network/shared-file play

For two-player network play, both machines need access to the same shared JSON file.

Examples:

OneDrive shared folder
Google Drive synced folder
Dropbox
Network drive
Shared LAN folder

Host player:

Choose Host Game.
Pick/create a shared game file, for example:
C:\Users\<your-name>\OneDrive\ChessGames\game1.json
Choose your color and timer settings.

Join player:

Choose Join Game.
Select the same shared JSON file.

After that, both clients should update automatically.

8. Optional: run tests

From the project folder with the virtual environment activated:

python -m tests.test_model
python -m tests.test_serialize
python -m tests.test_netgame
python -m tests.test_timer
python -m tests.test_premove_preview
python -m tests.test_history_analysis
python -m tests.test_engine
python -m tests.test_engine_options_dialog
Fastest full command sequence
cd C:\path\to\chessnet_stockfish_engine_fix
python -m venv .venv
.venv\Scripts\activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python main.py
