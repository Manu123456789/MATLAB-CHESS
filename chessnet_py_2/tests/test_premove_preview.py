"""Tests for chess.com-style local premove preview behavior.

Run from project root:
    python -m tests.test_premove_preview
"""
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, '.')

import chess
from PySide6.QtWidgets import QApplication

from chessnet.model import Game
from chessnet.gui.board_view import BoardView


_APP = QApplication.instance() or QApplication([])


def _white_waiting_view() -> BoardView:
    game = Game()
    game.push(chess.Move.from_uci('e2e4'))  # black to move; white can premove
    view = BoardView(game)
    view.input_locked = True
    view.set_premove_mode(True, chess.WHITE)
    return view


def test_premove_moves_piece_on_private_preview_board():
    view = _white_waiting_view()

    view._handle_premove_click(chess.G1)
    view._handle_premove_click(chess.F3)

    assert [m.uci() for m in view.premove_queue] == ['g1f3']
    preview = view._board_for_painting()
    assert preview.piece_at(chess.F3).symbol() == 'N'
    assert preview.piece_at(chess.G1) is None
    # The real synchronized board is untouched until the premove fires.
    assert view.game.board.piece_at(chess.G1).symbol() == 'N'
    assert view.game.board.piece_at(chess.F3) is None


def test_premove_can_be_chained_from_preview_destination():
    view = _white_waiting_view()

    view._handle_premove_click(chess.G1)
    view._handle_premove_click(chess.F3)
    view._handle_premove_click(chess.F3)

    assert chess.G5 in view.premove_targets

    view._handle_premove_click(chess.G5)

    assert [m.uci() for m in view.premove_queue] == ['g1f3', 'f3g5']
    preview = view._board_for_painting()
    assert preview.piece_at(chess.G5).symbol() == 'N'
    assert preview.piece_at(chess.F3) is None
    assert preview.piece_at(chess.G1) is None


def test_clear_premoves_restores_real_board_preview():
    view = _white_waiting_view()

    view._handle_premove_click(chess.G1)
    view._handle_premove_click(chess.F3)
    view.clear_premoves()

    preview = view._board_for_painting()
    assert preview.piece_at(chess.G1).symbol() == 'N'
    assert preview.piece_at(chess.F3) is None
    assert view.premove_queue == []


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
