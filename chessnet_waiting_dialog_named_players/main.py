"""ChessNet entry point.

Shows the session dialog, then opens the main window in either local
hot-seat or network mode based on the user's choice.

Usage:
    python main.py
"""
from __future__ import annotations

import os
import sys
import json
import secrets
from datetime import datetime

import chess
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication, QMessageBox, QDialog, QVBoxLayout, QLabel, QPushButton

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
            increment_seconds=choice.increment_seconds,
            local=True,
        )
        win = MainWindow(Game(), orientation=chess.WHITE, timer_state=timer)
    elif choice.mode == MODE_HOST:
        win = _host_window(
            choice.file_path,
            choice.color,
            choice.white_player,
            choice.timer_enabled,
            choice.white_seconds,
            choice.black_seconds,
            choice.increment_seconds,
        )
        if win is None:
            return 1
    elif choice.mode == MODE_JOIN:
        win = _join_window(choice.file_path, choice.color, choice.white_player)
        if win is None:
            return 1
    elif choice.mode == MODE_BOT:
        timer = TimerState.from_seconds(
            choice.timer_enabled,
            choice.white_seconds,
            choice.black_seconds,
            increment_seconds=choice.increment_seconds,
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


def _safe_name(name: str) -> str:
    import re
    cleaned = re.sub(r'\s+', '_', (name or '').strip())
    cleaned = re.sub(r'[^A-Za-z0-9_.-]+', '', cleaned)
    cleaned = cleaned.strip('._-')
    return cleaned or 'Player'


def _stamp_from_snapshot(snap: GameSnapshot) -> str:
    try:
        dt = datetime.fromisoformat(snap.created_at)
    except Exception:
        dt = datetime.now()
    hour_12 = dt.hour % 12 or 12
    return f"{hour_12}_{dt.minute:02d}_{dt:%m%d%y}"


def _unique_path(directory: str, filename: str) -> str:
    path = os.path.join(directory, filename)
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(filename)
    for idx in range(2, 1000):
        candidate = os.path.join(directory, f"{stem}_{idx}{ext}")
        if not os.path.exists(candidate):
            return candidate
    return path


def _final_game_path(waiting_path: str, white_name: str, black_name: str, snap: GameSnapshot) -> str:
    directory = os.path.dirname(os.path.abspath(waiting_path)) or '.'
    stamp = snap.setup.get('stamp') or _stamp_from_snapshot(snap)
    filename = f"{_safe_name(white_name)}_vs._{_safe_name(black_name)}_{stamp}.json"
    return _unique_path(directory, filename)


def _write_json_direct(path: str, snap: GameSnapshot) -> None:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(snap.to_json())


def _host_window(file_path: str, host_color: str, host_name: str, timer_enabled: bool = False, white_seconds: int = 600, black_seconds: int = 600, increment_seconds: int = 0) -> MainWindow | None:
    """Create a waiting-room file, wait for the joiner, then open the finalized game.

    ``host_color`` may be ``'w'``, ``'b'``, or ``'random'``. Random is resolved
    exactly once by the host before the waiting file is written. The joiner then
    reads that authoritative host color and is assigned the opposite side.
    """
    file_path = os.path.abspath(file_path)
    if host_color == 'random':
        host_color = secrets.choice(('w', 'b'))
    if host_color not in ('w', 'b'):
        host_color = 'w'
    if os.path.exists(file_path):
        r = QMessageBox.question(
            None, "File exists",
            f"{file_path}\n\nalready exists. Overwrite with a new waiting game?",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No,
        )
        if r != QMessageBox.Yes:
            return None

    timer = TimerState.from_seconds(
        timer_enabled,
        white_seconds,
        black_seconds,
        increment_seconds=increment_seconds,
        opened_color=host_color,
    )
    snap = GameSnapshot.initial(host_color, timer=timer)
    snap.status = 'waiting_for_player'
    host_name = host_name.strip() or 'Host'
    snap.players = {
        'host': {'name': host_name, 'color': host_color},
        'joiner': None,
    }
    snap.setup = {
        'waiting': True,
        'hostName': host_name,
        'hostColor': host_color,
        'colorMode': 'random' if host_color not in ('w', 'b') else 'fixed',
        'stamp': _stamp_from_snapshot(snap),
    }
    snap.color_assignment = {'hostColor': host_color, 'joinerColor': 'b' if host_color == 'w' else 'w'}

    try:
        _write_json_direct(file_path, snap)
    except OSError as e:
        QMessageBox.critical(
            None, "Cannot create waiting game",
            f"Failed to write {file_path}:\n\n{e}"
        )
        return None

    final_path, final_snap = _wait_for_opponent(file_path)
    if not final_path or final_snap is None:
        return None

    my_color = final_snap.players.get('host', {}).get('color') or final_snap.host_color
    netgame = NetGame(final_path, my_color=my_color, snapshot=final_snap)
    orient = chess.WHITE if my_color == 'w' else chess.BLACK
    return MainWindow(final_snap.to_game(), netgame=netgame, orientation=orient)


def _wait_for_opponent(waiting_path: str) -> tuple[str | None, GameSnapshot | None]:
    dlg = QDialog()
    dlg.setWindowTitle("Waiting for opponent")
    dlg.setModal(True)
    dlg.setMinimumWidth(520)
    layout = QVBoxLayout(dlg)
    label = QLabel(
        "Waiting for the joining player to open the shared game file...\n\n"
        f"Waiting file:\n{waiting_path}\n\n"
        "Keep this window open. The game will start automatically once the opponent joins."
    )
    label.setWordWrap(True)
    layout.addWidget(label)
    cancel = QPushButton("Cancel")
    layout.addWidget(cancel)
    cancel.clicked.connect(dlg.reject)

    result: dict[str, object] = {'path': None, 'snap': None}

    def poll() -> None:
        try:
            with open(waiting_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
        except Exception:
            return
        status = data.get('status')
        final_path = data.get('setup', {}).get('finalPath')
        if status == 'redirect' and final_path and os.path.exists(final_path):
            try:
                with open(final_path, 'r', encoding='utf-8') as f:
                    snap = GameSnapshot.from_json(f.read())
            except Exception:
                return
            result['path'] = final_path
            result['snap'] = snap
            dlg.accept()
        elif status in ('active', 'check'):
            try:
                snap = GameSnapshot.from_dict(data)
            except Exception:
                return
            result['path'] = waiting_path
            result['snap'] = snap
            dlg.accept()

    timer = QTimer(dlg)
    timer.timeout.connect(poll)
    timer.start(750)
    poll()
    if dlg.exec() != QDialog.Accepted:
        return None, None
    return result['path'], result['snap']  # type: ignore[return-value]


def _join_window(file_path: str, my_color: str | None = None, joiner_name: str = 'Joiner') -> MainWindow | None:
    """Read an existing game file. Waiting games auto-assign the joiner to the
    opposite color and create the final White-vs-Black game file name."""
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

    if snap.status == 'waiting_for_player':
        return _join_waiting_game(file_path, snap, joiner_name)

    if snap.status == 'redirect':
        final_path = snap.setup.get('finalPath')
        if final_path and os.path.exists(final_path):
            return _join_window(final_path, my_color, joiner_name)

    if my_color not in ('w', 'b'):
        my_color = 'b' if snap.host_color == 'w' else 'w'
    netgame = NetGame(file_path, my_color=my_color, snapshot=snap)
    orient = chess.WHITE if my_color == 'w' else chess.BLACK
    return MainWindow(snap.to_game(), netgame=netgame, orientation=orient)


def _join_waiting_game(waiting_path: str, waiting_snap: GameSnapshot, joiner_name: str) -> MainWindow | None:
    host_color = waiting_snap.host_color
    if host_color not in ('w', 'b'):
        QMessageBox.critical(None, "Invalid waiting game", "The waiting file has an invalid host color.")
        return None
    joiner_color = 'b' if host_color == 'w' else 'w'
    host_name = waiting_snap.players.get('host', {}).get('name') or waiting_snap.setup.get('hostName') or 'Host'
    joiner_name = joiner_name.strip() or 'Joiner'
    white_name = host_name if host_color == 'w' else joiner_name
    black_name = joiner_name if host_color == 'w' else host_name
    final_path = _final_game_path(waiting_path, white_name, black_name, waiting_snap)

    active = GameSnapshot.initial(host_color, timer=waiting_snap.timer.copy())
    active.game_id = waiting_snap.game_id
    active.created_at = waiting_snap.created_at
    active.status = 'active'
    active.players = {
        'host': {'name': host_name, 'color': host_color},
        'joiner': {'name': joiner_name, 'color': joiner_color},
        'white': {'name': white_name, 'role': 'host' if host_color == 'w' else 'joiner'},
        'black': {'name': black_name, 'role': 'joiner' if host_color == 'w' else 'host'},
    }
    active.setup = dict(waiting_snap.setup or {})
    active.setup.update({
        'waiting': False,
        'finalPath': final_path,
        'whiteName': white_name,
        'blackName': black_name,
        'joinerName': joiner_name,
    })
    active.color_assignment = {
        'hostColor': host_color,
        'joinerColor': joiner_color,
        'whiteRole': 'host' if host_color == 'w' else 'joiner',
        'blackRole': 'joiner' if host_color == 'w' else 'host',
    }
    active.timer.mark_opened(joiner_color)

    try:
        _write_json_direct(final_path, active)
        redirect = waiting_snap
        redirect.status = 'redirect'
        redirect.setup = dict(redirect.setup or {})
        redirect.setup.update({'finalPath': final_path, 'waiting': False})
        redirect.players = active.players
        redirect.color_assignment = active.color_assignment
        _write_json_direct(waiting_path, redirect)
    except OSError as e:
        QMessageBox.critical(
            None, "Cannot join game",
            f"Failed to create or update the shared game files:\n\n{e}"
        )
        return None

    netgame = NetGame(final_path, my_color=joiner_color, snapshot=active)
    orient = chess.WHITE if joiner_color == 'w' else chess.BLACK
    QMessageBox.information(None, "Joined game", f"You are playing {'White' if joiner_color == 'w' else 'Black'}.\n\nGame file:\n{final_path}")
    return MainWindow(active.to_game(), netgame=netgame, orientation=orient)

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
