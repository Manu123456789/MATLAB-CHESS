"""Tests for persistent position history, replay helpers, analysis variations,
and same-file network New Game rebinding.

    python -m tests.test_history_analysis
"""
import os
import sys
import tempfile

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, '.')

import chess
from PySide6.QtWidgets import QApplication

from chessnet.model import Game
from chessnet.netgame import NetGame
from chessnet.serialize import GameSnapshot, TimerState
from chessnet.gui.main_window import MainWindow


def _app():
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    return app


def _tmppath() -> str:
    fd, path = tempfile.mkstemp(suffix='.json', prefix='chesstest_')
    os.close(fd)
    os.remove(path)
    return path


def test_position_history_round_trip():
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('e7e5'))
    snap = GameSnapshot.from_game(g, base=GameSnapshot.initial('w'))
    assert len(snap.position_history) == 3
    assert snap.position_history[0] == chess.STARTING_FEN
    assert snap.position_history[-1] == g.board.fen()

    loaded = GameSnapshot.from_json(snap.to_json())
    assert loaded.position_history == snap.position_history
    assert loaded.to_game().position_history() == snap.position_history


def test_backward_compatible_position_history_from_move_records():
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    snap = GameSnapshot.from_game(g, base=GameSnapshot.initial('w'))
    d = snap.to_dict()
    del d['positionHistory']
    loaded = GameSnapshot.from_dict(d)
    assert loaded.position_history == [chess.STARTING_FEN, g.history[-1].fen_after]


def test_same_file_new_game_rebinds_opponent_without_file_prompt():
    path = _tmppath()
    try:
        snap = GameSnapshot.initial('w')
        host = NetGame(path, 'w', snap)
        host.bootstrap(snap)
        guest = NetGame(path, 'b', snap)
        guest.load()

        new_snap = GameSnapshot.initial(
            'b',
            timer=TimerState.from_seconds(True, 30, 120, opened_color='b'),
        )
        host.start_new_game(new_snap, my_color='b')
        loaded = guest.load(allow_rebind=True)

        assert loaded.game_id == new_snap.game_id
        assert guest.game_id == new_snap.game_id
        assert guest.my_color == 'w'  # opposite the new host color
        assert loaded.timer.black_opened is True
    finally:
        if os.path.exists(path):
            os.remove(path)


def test_analysis_variation_does_not_mutate_real_game():
    _app()
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('e7e5'))
    real_final = g.board.fen()

    win = MainWindow(g, orientation=chess.WHITE)
    try:
        win._enter_analysis_mode()
        assert win._analysis_index == 2
        win._set_analysis_index(1)  # after 1. e4, Black to move
        assert win._analysis_game is not None
        win._analysis_game.push(chess.Move.from_uci('c7c5'))
        win._on_move_made(win._analysis_game.history[-1].san)

        # Alternate analysis moves must not truncate or replace the real
        # saved timeline. The variation is held only by _analysis_game.
        assert len(win._analysis_positions) == 3
        assert chess.Board(win._analysis_positions[-1]).fen() == real_final
        assert win._analysis_game.board.piece_at(chess.C5).symbol() == 'p'
        assert win.game.board.fen() == real_final
        assert len(win.game.history) == 2
    finally:
        win.close()


def test_replay_button_uses_previous_fen_without_mutating_game():
    _app()
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    win = MainWindow(g, orientation=chess.WHITE)
    try:
        before = g.position_history()[-2]
        win._on_replay_last_move()
        assert win.board_view.display_board_override is not None
        assert win.board_view.display_board_override.fen() == before
        assert win.game.board.fen() == g.position_history()[-1]
        win._finish_replay_last_move()
        assert win.board_view.display_board_override is None
    finally:
        win.close()


def test_analysis_variation_navigation_preserves_real_timeline():
    _app()
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('e7e5'))
    g.push(chess.Move.from_uci('g1f3'))
    real_positions = g.position_history()

    win = MainWindow(g, orientation=chess.WHITE)
    try:
        win._enter_analysis_mode()
        win._set_analysis_index(1)  # after 1. e4, black to move
        assert win._analysis_game is not None
        win._analysis_game.push(chess.Move.from_uci('c7c5'))
        win._on_move_made(win._analysis_game.history[-1].san)

        assert win._analysis_positions == real_positions
        assert win.game.position_history() == real_positions
        assert chess.Board(real_positions[2]).piece_at(chess.E5).symbol() == 'p'

        win._set_analysis_index(2)
        assert win._analysis_game is not None
        assert win._analysis_game.board.fen() == real_positions[2]
        assert win._analysis_game.board.piece_at(chess.E5).symbol() == 'p'
        assert win._analysis_game.board.piece_at(chess.C5) is None
    finally:
        win.close()


def test_analysis_graveyard_uses_history_prefix():
    _app()
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('d7d5'))
    g.push(chess.Move.from_uci('e4d5'))  # white captures black pawn

    win = MainWindow(g, orientation=chess.WHITE)
    try:
        win._enter_analysis_mode()
        win._set_analysis_index(3)
        assert win._analysis_game is not None
        assert [r.captured for r in win._analysis_game.history] == [None, None, 'p']
    finally:
        win.close()


def test_live_history_back_forward_is_read_only():
    _app()
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('e7e5'))
    final_fen = g.board.fen()

    win = MainWindow(g, orientation=chess.WHITE)
    try:
        win._set_live_review_index(1)
        assert win._view_index == 1
        assert win.board_view.display_board_override is not None
        assert win.board_view.input_locked is True
        assert win.game.board.fen() == final_fen
        assert len(win.game.history) == 2

        win._set_live_review_index(2)
        assert win._view_index is None
        assert win.board_view.display_board_override is None
        assert win.game.board.fen() == final_fen
    finally:
        win.close()


if __name__ == '__main__':
    tests = [v for k, v in globals().items() if k.startswith('test_')]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  OK  {t.__name__}")
        except Exception as e:
            failed += 1
            print(f"FAIL  {t.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(0 if failed == 0 else 1)
