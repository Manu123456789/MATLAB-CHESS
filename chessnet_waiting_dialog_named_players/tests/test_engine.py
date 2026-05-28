"""Tests for Stockfish/UCI settings and parsing.
    python -m tests.test_engine
"""
import os
import sys
import tempfile
import textwrap

sys.path.insert(0, '.')

import chess

from chessnet.engine import (
    EngineSettings, StockfishEngine, parse_analysis_lines,
)


def test_engine_settings_round_trip_and_go_commands():
    s = EngineSettings(depth=0, elo=999999, search_mode='bad').normalized()
    assert s.depth == 1
    assert s.elo == 3190
    assert s.search_mode == 'movetime'
    d = s.to_dict()
    back = EngineSettings.from_dict(d)
    assert back.to_dict() == d

    s.search_mode = 'depth'
    s.depth = 6
    assert s.go_command(chess.Board()) == 'go depth 6'
    s.search_mode = 'nodes'
    s.nodes = 123
    assert s.go_command(chess.Board()) == 'go nodes 123'


def test_parse_analysis_score_is_white_relative():
    lines = [
        'info depth 10 score cp 50 nodes 1 pv e7e5',
        'bestmove e7e5',
    ]
    a = parse_analysis_lines(lines, chess.BLACK)
    assert a.bestmove == 'e7e5'
    assert a.score_cp_white == -50
    assert a.pvs[0].first_move == 'e7e5'


def test_parse_mate_score_is_white_relative():
    lines = [
        'info depth 10 score mate 3 pv h5e8',
        'bestmove h5e8',
    ]
    a = parse_analysis_lines(lines, chess.WHITE)
    assert a.mate_white == 3
    assert a.score_cp_white == 100000


def _make_mock_engine() -> str:
    fd, path = tempfile.mkstemp(prefix='mock_stockfish_', suffix='.py')
    os.close(fd)
    script = textwrap.dedent(r'''
        #!/usr/bin/env python3
        import sys
        for raw in sys.stdin:
            line = raw.strip()
            if line == 'uci':
                print('id name Mockfish', flush=True)
                print('uciok', flush=True)
            elif line == 'isready':
                print('readyok', flush=True)
            elif line.startswith('go'):
                print('info depth 1 score cp 42 nodes 1 pv e2e4', flush=True)
                print('bestmove e2e4', flush=True)
            elif line == 'quit':
                break
    ''').lstrip()
    with open(path, 'w', encoding='utf-8') as f:
        f.write(script)
    os.chmod(path, 0o755)
    return path


def test_stockfish_engine_wrapper_with_mock_uci_engine():
    path = _make_mock_engine()
    try:
        settings = EngineSettings(engine_path=path, search_mode='depth', depth=1)
        with StockfishEngine(settings) as engine:
            result = engine.best_move(chess.Board())
        assert result.bestmove == 'e2e4'
        assert result.score_cp_white == 42
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
