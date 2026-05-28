"""Regression tests for Stockfish watchdog/clock behavior.
    python -m tests.test_engine_watchdog_settings
"""
import sys
sys.path.insert(0, '.')

import chess

from chessnet.engine import EngineSettings
from chessnet.serialize import TimerState


def test_analysis_settings_do_not_use_clock():
    base = EngineSettings(use_clock=True, search_mode='movetime', movetime_ms=50, search_timeout_sec=2)
    analysis = EngineSettings.for_analysis(base)
    assert analysis.use_clock is False
    assert analysis.search_timeout_sec >= 10
    assert analysis.movetime_ms >= 1200


def test_clock_go_falls_back_when_remaining_below_move_overhead():
    s = EngineSettings(search_mode='movetime', movetime_ms=250, use_clock=True, move_overhead_ms=250)
    timer = TimerState.from_seconds(True, 1, 60, local=True)
    timer.white_remaining_sec = 0.20
    timer.black_remaining_sec = 60
    cmd = s.go_command(chess.Board(), timer_state=timer)
    assert cmd == 'go movetime 250'


def test_clock_go_uses_clock_when_budget_is_sensible():
    s = EngineSettings(search_mode='movetime', movetime_ms=250, use_clock=True, move_overhead_ms=250)
    timer = TimerState.from_seconds(True, 60, 60, local=True)
    cmd = s.go_command(chess.Board(), timer_state=timer)
    assert cmd.startswith('go wtime ')
    assert ' btime ' in cmd


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
