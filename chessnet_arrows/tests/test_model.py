"""Smoke tests for the Game model. Run from project root:
    python -m tests.test_model
"""
import sys
sys.path.insert(0, '.')

import chess
from chessnet.model import Game


def test_opening():
    g = Game()
    assert g.turn == chess.WHITE
    assert g.status() == 'active'
    moves = g.legal_moves_from(chess.E2)
    targets = {m.to_square for m in moves}
    assert chess.E3 in targets
    assert chess.E4 in targets

def test_basic_capture():
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('d7d5'))
    rec = g.push(chess.Move.from_uci('e4d5'))
    assert rec.captured == 'p'  # black pawn
    assert rec.san == 'exd5'

def test_en_passant_capture_recorded():
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('a7a6'))
    g.push(chess.Move.from_uci('e4e5'))
    g.push(chess.Move.from_uci('d7d5'))
    rec = g.push(chess.Move.from_uci('e5d6'))   # en passant
    assert rec.captured == 'p'

def test_castling():
    g = Game()
    moves = ['e2e4','e7e5','g1f3','b8c6','f1b5','g8f6','e1g1']
    for u in moves:
        g.push(chess.Move.from_uci(u))
    assert g.history[-1].san == 'O-O'

def test_promotion_target_squares():
    g = Game()
    # Force a near-promotion position.
    g.board.set_fen('8/P7/8/8/8/8/8/4k2K w - - 0 1')
    targets = g.legal_target_squares(chess.A7)
    # All promotion moves collapse to the single dest square a8.
    assert targets == {chess.A8}
    assert g.is_promotion_move(chess.A7, chess.A8)
    g.push(chess.Move(chess.A7, chess.A8, promotion=chess.QUEEN))
    assert g.history[-1].san.startswith('a8=Q')

def test_fools_mate_detected():
    g = Game()
    for u in ['f2f3','e7e5','g2g4','d8h4']:
        g.push(chess.Move.from_uci(u))
    assert g.status() == 'checkmate'
    assert g.is_game_over()

def test_undo():
    g = Game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('e7e5'))
    assert len(g.history) == 2
    g.pop()
    assert len(g.history) == 1
    assert g.turn == chess.BLACK


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
