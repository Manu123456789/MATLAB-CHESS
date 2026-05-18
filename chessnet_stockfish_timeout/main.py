"""ChessNet entry point.

Shows the session dialog, then opens the main window in either local
hot-seat or network mode based on the user's choice.

Usage:
    python main.py
"""
from __future__ import annotations

import os
import sys

import chess
from PySide6.QtWidgets import QApplication, QMessageBox, QDialog

from chessnet.model import Game
from chessnet.netgame import NetGame, WrongGameError
from chessnet.serialize import GameSnapshot, TimerState
from chessnet.gui.session_dialog import (
    SessionDialog, MODE_LOCAL, MODE_HOST, MODE_JOIN, MODE_BOT, MODE_SPECTATE,
)
from chessnet.gui.main_window import MainWindow


def main() -> int:
    app = QApplication(sys.argv)

    dlg = SessionDialog()
    if dlg.exec() != QDialog.Accepted:
        return 0
    choice = dlg.choice()
    if choice.cancelled:
        return 0

    if choice.mode == MODE_LOCAL:
        timer = TimerState.from_seconds(
            choice.timer_enabled,
            choice.white_seconds,
            choice.black_seconds,
            local=True,
        )
        win = MainWindow(Game(), orientation=chess.WHITE, timer_state=timer)
    elif choice.mode == MODE_HOST:
        win = _host_window(
            choice.file_path,
            choice.color,
            choice.timer_enabled,
            choice.white_seconds,
            choice.black_seconds,
        )
        if win is None:
            return 1
    elif choice.mode == MODE_JOIN:
        win = _join_window(choice.file_path)
        if win is None:
            return 1
    elif choice.mode == MODE_BOT:
        timer = TimerState.from_seconds(
            choice.timer_enabled,
            choice.white_seconds,
            choice.black_seconds,
            local=True,
        )
        human_color = chess.WHITE if choice.color == 'w' else chess.BLACK
        engine_color = not human_color
        win = MainWindow(
            Game(),
            orientation=human_color,
            timer_state=timer,
            bot_color=engine_color,
            engine_settings=choice.engine_settings,
            evaluation_enabled=True,
        )
    elif choice.mode == MODE_SPECTATE:
        win = _spectate_window(choice.file_path, choice.engine_settings)
        if win is None:
            return 1
    else:
        QMessageBox.critical(None, "Unknown mode", f"Mode: {choice.mode}")
        return 1

    win.show()
    return app.exec()


def _host_window(file_path: str, host_color: str, timer_enabled: bool = False, white_seconds: int = 600, black_seconds: int = 600) -> MainWindow | None:
    """Create a fresh game, write it to `file_path`, return the main window."""
    file_path = os.path.abspath(file_path)
    if os.path.exists(file_path):
        r = QMessageBox.question(
            None, "File exists",
            f"{file_path}\n\nalready exists. Overwrite with a new game?",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No,
        )
        if r != QMessageBox.Yes:
            return None

    timer = TimerState.from_seconds(
        timer_enabled,
        white_seconds,
        black_seconds,
        opened_color=host_color,
    )
    snap = GameSnapshot.initial(host_color, timer=timer)
    # Build the NetGame with a placeholder snapshot, then bootstrap to
    # write the real one. bootstrap() updates last_seen and game_id.
    netgame = NetGame(file_path, my_color=host_color, snapshot=snap)
    try:
        netgame.bootstrap(snap)
    except OSError as e:
        QMessageBox.critical(
            None, "Cannot create game file",
            f"Failed to write {file_path}:\n\n{e}"
        )
        return None

    orient = chess.WHITE if host_color == 'w' else chess.BLACK
    return MainWindow(snap.to_game(), netgame=netgame, orientation=orient)


def _join_window(file_path: str) -> MainWindow | None:
    """Read an existing game file, take the opposite color from host."""
    file_path = os.path.abspath(file_path)
    try:
        # Provisional NetGame -- we'll fix up game_id and color from the file.
        # We give it a dummy snapshot first; load() will replace it.
        with open(file_path, 'r', encoding='utf-8') as f:
            snap = GameSnapshot.from_json(f.read())
    except (OSError, ValueError) as e:
        QMessageBox.critical(
            None, "Cannot open game file",
            f"Failed to read {file_path}:\n\n{e}"
        )
        return None

    my_color = 'b' if snap.host_color == 'w' else 'w'
    netgame = NetGame(file_path, my_color=my_color, snapshot=snap)
    orient = chess.WHITE if my_color == 'w' else chess.BLACK
    return MainWindow(snap.to_game(), netgame=netgame, orientation=orient)


def _spectate_window(file_path: str, engine_settings) -> MainWindow | None:
    """Read an existing game file as a read-only spectator with engine eval."""
    file_path = os.path.abspath(file_path)
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            snap = GameSnapshot.from_json(f.read())
    except (OSError, ValueError) as e:
        QMessageBox.critical(
            None, "Cannot open game file",
            f"Failed to read {file_path}:\n\n{e}"
        )
        return None

    # NetGame still provides robust load/rebind/watch behavior. The window's
    # spectator flag prevents any writes or moves from this client.
    netgame = NetGame(file_path, my_color='w', snapshot=snap)
    return MainWindow(
        snap.to_game(),
        netgame=netgame,
        orientation=chess.WHITE,
        spectator=True,
        engine_settings=engine_settings,
        evaluation_enabled=True,
    )


if __name__ == "__main__":
    sys.exit(main())
