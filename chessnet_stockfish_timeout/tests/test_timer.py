"""Tests for per-side chess clock serialization and state transitions.
    python -m tests.test_timer
"""
import sys
sys.path.insert(0, '.')

from chessnet.serialize import GameSnapshot, TimerState


def test_unbalanced_timer_round_trip():
    timer = TimerState.from_seconds(True, 30, 120, opened_color='w')
    snap = GameSnapshot.initial('w', timer=timer)
    back = GameSnapshot.from_json(snap.to_json())
    assert back.timer.enabled is True
    assert back.timer.white_initial_sec == 30
    assert back.timer.black_initial_sec == 120
    assert back.timer.white_remaining_sec == 30
    assert back.timer.black_remaining_sec == 120
    assert back.timer.white_opened is True
    assert back.timer.black_opened is False


def test_timer_switch_after_move_burns_elapsed_and_starts_other_side():
    timer = TimerState.from_seconds(True, 30, 120, local=True)
    timer.start('w', '2026-05-14T12:00:00')
    timer.switch_after_move('w', 'b', '2026-05-14T12:00:05')
    assert timer.white_remaining_sec == 25
    assert timer.black_remaining_sec == 120
    assert timer.active_color == 'b'
    assert timer.running is True
    assert timer.started_at == '2026-05-14T12:00:05'


def test_timer_timeout_sets_expired_color():
    timer = TimerState.from_seconds(True, 3, 120, local=True)
    timer.start('w', '2026-05-14T12:00:00')
    timer.apply_elapsed('2026-05-14T12:00:05')
    assert timer.white_remaining_sec == 0
    assert timer.expired_color == 'w'
    assert timer.running is False


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
