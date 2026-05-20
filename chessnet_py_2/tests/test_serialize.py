"""Tests for the JSON snapshot schema.
    python -m tests.test_serialize
"""
import sys
sys.path.insert(0, '.')

import chess

from chessnet.model import Game
from chessnet.serialize import GameSnapshot, SCHEMA_VERSION


def test_initial_is_well_formed():
    s = GameSnapshot.initial('w')
    assert s.schema_version == SCHEMA_VERSION
    assert s.host_color == 'w'
    assert len(s.game_id) == 16
    assert s.fen == chess.STARTING_FEN
    assert s.half_move_count == 0
    assert s.status == 'active'
    assert s.result is None


def test_round_trip_initial():
    s = GameSnapshot.initial('b')
    txt = s.to_json()
    back = GameSnapshot.from_json(txt)
    assert back.game_id == s.game_id
    assert back.host_color == 'b'
    assert back.fen == s.fen
    assert back.half_move_count == 0


def test_round_trip_after_moves():
    s0 = GameSnapshot.initial('w')
    g = s0.to_game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('e7e5'))
    g.push(chess.Move.from_uci('g1f3'))
    s1 = GameSnapshot.from_game(g, base=s0)
    assert s1.half_move_count == 3
    assert s1.game_id == s0.game_id

    back = GameSnapshot.from_json(s1.to_json())
    assert back.half_move_count == 3
    assert len(back.history) == 3
    assert back.history[0].san == 'e4'
    assert back.history[2].san == 'Nf3'

    # rebuild game and verify position matches
    g2 = back.to_game()
    assert g2.board.fen() == g.board.fen()


def test_result_string_on_checkmate():
    s = GameSnapshot.initial('w')
    g = s.to_game()
    for uci in ['f2f3','e7e5','g2g4','d8h4']:
        g.push(chess.Move.from_uci(uci))
    snap = GameSnapshot.from_game(g, base=s)
    assert snap.status == 'checkmate'
    assert snap.result == '0-1'


def test_result_string_on_resignation():
    s = GameSnapshot.initial('w')
    g = s.to_game()
    white_resigns = GameSnapshot.from_game(g, base=s, status='resign_w')
    black_resigns = GameSnapshot.from_game(g, base=s, status='resign_b')
    assert white_resigns.result == '0-1'
    assert black_resigns.result == '1-0'
    assert GameSnapshot.from_json(white_resigns.to_json()).status == 'resign_w'


def test_bad_schema_version_rejected():
    s = GameSnapshot.initial('w').to_dict()
    s['schemaVersion'] = 999
    try:
        GameSnapshot.from_dict(s)
    except ValueError:
        return
    raise AssertionError("expected ValueError for bad schemaVersion")


def test_bad_host_color_rejected():
    s = GameSnapshot.initial('w').to_dict()
    s['hostColor'] = 'x'
    try:
        GameSnapshot.from_dict(s)
    except ValueError:
        return
    raise AssertionError("expected ValueError for bad hostColor")


def test_history_round_trip_preserves_captures():
    s = GameSnapshot.initial('w')
    g = s.to_game()
    g.push(chess.Move.from_uci('e2e4'))
    g.push(chess.Move.from_uci('d7d5'))
    g.push(chess.Move.from_uci('e4d5'))
    snap = GameSnapshot.from_game(g, base=s)
    back = GameSnapshot.from_json(snap.to_json())
    assert back.history[-1].captured == 'p'


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
