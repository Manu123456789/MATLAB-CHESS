# Building the ChessNet Windows Executable

The normal end user should run:

```text
ChessNet.exe
```

from their Desktop.

For a developer building the executable from source:

1. Install Python 3.10 or newer.
2. Double-click `build_windows_exe.bat` from the project root.
3. The finished executable will be copied directly to your Desktop:

```text
%USERPROFILE%\Desktop\ChessNet.exe
```

The script uses Windows' real Desktop location, so it also works when Desktop is redirected through OneDrive.

A backup copy is also created at:

```text
dist\ChessNet.exe
```

The build script automatically creates `.venv`, installs `requirements.txt`, installs `requirements-build.txt`, runs PyInstaller, and copies the final single-file executable to Desktop.

Stockfish is not bundled. Users still need to download Stockfish separately and point ChessNet to the Stockfish executable from the GUI.
