"""Regression test for Stockfish requests that ignore low search settings.
    python -m tests.test_engine_timeout
"""
import os
import sys
import tempfile
import textwrap
import time

sys.path.insert(0, '.')

import chess

from chessnet.engine import EngineSettings, StockfishEngine


def _make_slow_mock_engine() -> str:
    fd, path = tempfile.mkstemp(prefix='mock_slow_stockfish_', suffix='.py')
    os.close(fd)
    script = textwrap.dedent(r'''
        #!/usr/bin/env python3
        import sys, time, select
        for raw in sys.stdin:
            line = raw.strip()
            if line == 'uci':
                print('id name SlowMockfish', flush=True)
                print('uciok', flush=True)
            elif line == 'isready':
                print('readyok', flush=True)
            elif line.startswith('go'):
                # Simulate an engine/search that runs longer than requested but
                # still honors UCI stop. The wrapper should send stop quickly.
                deadline = time.time() + 30
                while time.time() < deadline:
                    r, _, _ = select.select([sys.stdin], [], [], 0.05)
                    if r:
                        cmd = sys.stdin.readline().strip()
                        if cmd == 'stop':
                            print('bestmove e2e4', flush=True)
                            break
                else:
                    print('bestmove e2e4', flush=True)
            elif line == 'quit':
                break
    ''').lstrip()
    with open(path, 'w', encoding='utf-8') as f:
        f.write(script)
    os.chmod(path, 0o755)
    return path


def test_engine_sends_stop_after_effective_timeout():
    path = _make_slow_mock_engine()
    try:
        settings = EngineSettings(
            engine_path=path,
            search_mode='movetime',
            movetime_ms=50,
            search_timeout_sec=3.0,
        )
        t0 = time.monotonic()
        with StockfishEngine(settings) as engine:
            result = engine.best_move(chess.Board())
        elapsed = time.monotonic() - t0
        assert result.bestmove == 'e2e4'
        assert elapsed < 5.0
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


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
