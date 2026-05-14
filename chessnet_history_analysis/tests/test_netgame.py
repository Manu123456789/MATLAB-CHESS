"""End-to-end tests for the NetGame shared-file layer.
Simulates two clients reading and writing the same file.

    python -m tests.test_netgame
"""
import os
import sys
import tempfile

sys.path.insert(0, '.')

import chess

from chessnet.model import Game
from chessnet.netgame import NetGame, StaleWriteError, WrongGameError
from chessnet.serialize import GameSnapshot


def _tmppath() -> str:
    fd, path = tempfile.mkstemp(suffix='.json', prefix='chesstest_')
    os.close(fd)
    os.remove(path)
    return path


def test_bootstrap_creates_file():
    path = _tmppath()
    try:
        snap = GameSnapshot.initial('w')
        ng = NetGame(path, 'w', snap)
        ng.bootstrap(snap)
        assert os.path.exists(path)
        # Read back via a second NetGame
        ng2 = NetGame(path, 'b', snap)
        s2 = ng2.load()
        assert s2.game_id == snap.game_id
        assert s2.host_color == 'w'
    finally:
        if os.path.exists(path):
            os.remove(path)


def test_two_clients_exchange_moves():
    """Simulates the real network flow: white writes, black reads,
    black writes, white reads."""
    path = _tmppath()
    try:
        snap = GameSnapshot.initial('w')
        white = NetGame(path, 'w', snap)
        white.bootstrap(snap)
        black = NetGame(path, 'b', snap)
        # Black needs to sync up after bootstrap.
        black.load()

        assert white.my_turn is True
        assert black.my_turn is False

        # White plays e4
        g_white = white.last_seen.to_game()
        g_white.push(chess.Move.from_uci('e2e4'))
        white.save(g_white)

        # Black refreshes
        black.load()
        assert black.my_turn is True
        assert black.last_seen.half_move_count == 1
        assert black.last_seen.history[-1].san == 'e4'

        # Black plays e5
        g_black = black.last_seen.to_game()
        g_black.push(chess.Move.from_uci('e7e5'))
        black.save(g_black)

        # White refreshes
        white.load()
        assert white.my_turn is True
        assert white.last_seen.half_move_count == 2
    finally:
        if os.path.exists(path):
            os.remove(path)


def test_stale_write_detected():
    """If two clients both think it's their turn and both try to save,
    the second one must see StaleWriteError."""
    path = _tmppath()
    try:
        snap = GameSnapshot.initial('w')
        ng_a = NetGame(path, 'w', snap)
        ng_a.bootstrap(snap)
        ng_b = NetGame(path, 'w', snap)
        ng_b.load()   # both clients on same half-move count

        # Client A writes a move
        g_a = ng_a.last_seen.to_game()
        g_a.push(chess.Move.from_uci('e2e4'))
        ng_a.save(g_a)

        # Client B, still thinking it's at half-move 0, tries to write
        g_b = ng_b.last_seen.to_game()
        g_b.push(chess.Move.from_uci('d2d4'))
        try:
            ng_b.save(g_b)
        except StaleWriteError:
            return
        raise AssertionError("expected StaleWriteError")
    finally:
        if os.path.exists(path):
            os.remove(path)


def test_wrong_game_id_detected():
    """Opening a file whose gameId differs from what we expect raises."""
    path = _tmppath()
    try:
        snap = GameSnapshot.initial('w')
        ng = NetGame(path, 'w', snap)
        ng.bootstrap(snap)

        # Someone overwrites the file with a completely new game
        new_snap = GameSnapshot.initial('w')
        new_ng = NetGame(path, 'w', new_snap)
        new_ng.bootstrap(new_snap)

        # Original NetGame tries to load -- should refuse
        try:
            ng.load()
        except WrongGameError:
            return
        raise AssertionError("expected WrongGameError")
    finally:
        if os.path.exists(path):
            os.remove(path)


def test_mtime_changed_after_write():
    """The cheap mtime-changed check correctly fires only after writes."""
    path = _tmppath()
    try:
        snap = GameSnapshot.initial('w')
        ng = NetGame(path, 'w', snap)
        ng.bootstrap(snap)

        # Second client sees the file unchanged from its perspective
        ng2 = NetGame(path, 'b', snap)
        ng2.load()
        assert ng2.mtime_changed() is False

        # White writes a move
        import time as _time
        _time.sleep(0.01)   # ensure mtime advances on coarse filesystems
        g = ng.last_seen.to_game()
        g.push(chess.Move.from_uci('e2e4'))
        ng.save(g)

        # Black's mtime check should now report a change
        assert ng2.mtime_changed() is True

        # After Black reloads, no further change
        ng2.load()
        assert ng2.mtime_changed() is False
    finally:
        if os.path.exists(path):
            os.remove(path)


def test_atomic_write_leaves_no_temp_files():
    """After a successful save, only the target file remains in the
    directory (no leftover .tmp.xxx)."""
    path = _tmppath()
    try:
        snap = GameSnapshot.initial('w')
        ng = NetGame(path, 'w', snap)
        ng.bootstrap(snap)

        for uci in ['e2e4','e7e5','g1f3','b8c6']:
            game = ng.last_seen.to_game()
            game.push(chess.Move.from_uci(uci))
            ng.save(game)
            # Refresh from disk between writes -- swaps which side is "us"
            ng.my_color = 'w' if ng.last_seen.fen.split()[1] == 'w' else 'b'

        directory = os.path.dirname(path)
        leftover = [f for f in os.listdir(directory)
                    if f.startswith('.' + os.path.basename(path) + '.tmp.')]
        assert leftover == [], f"leftover temp files: {leftover}"
    finally:
        if os.path.exists(path):
            os.remove(path)


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
