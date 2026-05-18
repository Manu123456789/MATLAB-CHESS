"""
Shared-game JSON schema (clean break from the MATLAB format).

A single GameSnapshot bundles everything needed to reconstruct a Game
plus the session metadata (game id, host color, timestamps, optional
per-side chess clock state). The file on the shared drive is
GameSnapshot.to_dict() serialized as pretty JSON.
"""
from __future__ import annotations

import json
import secrets
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

import chess

from .model import Game, MoveRecord


SCHEMA_VERSION = 1


def new_game_id() -> str:
    """16 hex chars, plenty of entropy for distinguishing concurrent games."""
    return secrets.token_hex(8)


def now_iso() -> str:
    """ISO-8601 to seconds. Drops sub-second precision so file diffs
    are easier to read by hand."""
    return datetime.now().isoformat(timespec='seconds')


def _parse_iso(txt: str) -> Optional[datetime]:
    if not txt:
        return None
    try:
        return datetime.fromisoformat(txt)
    except ValueError:
        return None


def elapsed_seconds(start_iso: str, end_iso: Optional[str] = None) -> float:
    """Seconds elapsed between two ISO timestamps. Bad/missing inputs
    deliberately return zero so a malformed shared file does not crash
    the GUI."""
    start = _parse_iso(start_iso)
    if start is None:
        return 0.0
    end = _parse_iso(end_iso or now_iso())
    if end is None:
        return 0.0
    return max(0.0, (end - start).total_seconds())


@dataclass
class TimerState:
    """Serializable per-color chess clock.

    The clock is stored as remaining base seconds plus an ISO timestamp
    for the currently running side. That means a remote client can close
    and reopen the game and still compute the correct displayed remaining
    time from the shared file alone.
    """

    enabled: bool = False
    white_initial_sec: int = 600
    black_initial_sec: int = 600
    white_remaining_sec: float = 600.0
    black_remaining_sec: float = 600.0
    running: bool = False
    paused: bool = False
    paused_by: str = ''
    active_color: str = 'w'
    started_at: str = ''
    expired_color: str = ''
    white_opened: bool = False
    black_opened: bool = False

    @classmethod
    def disabled(cls) -> 'TimerState':
        return cls(enabled=False)

    @classmethod
    def from_seconds(cls,
                     enabled: bool,
                     white_seconds: int,
                     black_seconds: Optional[int] = None,
                     *,
                     opened_color: str = '',
                     local: bool = False) -> 'TimerState':
        white = max(1, int(round(white_seconds)))
        black = white if black_seconds is None else max(1, int(round(black_seconds)))
        t = cls(
            enabled=bool(enabled),
            white_initial_sec=white,
            black_initial_sec=black,
            white_remaining_sec=float(white),
            black_remaining_sec=float(black),
            active_color='w',
        )
        if local:
            t.white_opened = True
            t.black_opened = True
        elif opened_color == 'w':
            t.white_opened = True
        elif opened_color == 'b':
            t.black_opened = True
        return t

    @classmethod
    def from_dict(cls, d: Optional[dict]) -> 'TimerState':
        if not isinstance(d, dict):
            return cls.disabled()
        # Backward-compatible aliases for earlier MATLAB-style timer fields.
        initial = int(d.get('initialSeconds', d.get('whiteInitialSec', 600)) or 600)
        white_initial = int(d.get('whiteInitialSec', d.get('white_initial_sec', initial)) or initial)
        black_initial = int(d.get('blackInitialSec', d.get('black_initial_sec', initial)) or initial)
        return cls(
            enabled=bool(d.get('enabled', False)),
            white_initial_sec=max(1, white_initial),
            black_initial_sec=max(1, black_initial),
            white_remaining_sec=float(d.get('whiteRemainingSec', d.get('white_remaining_sec', white_initial)) or white_initial),
            black_remaining_sec=float(d.get('blackRemainingSec', d.get('black_remaining_sec', black_initial)) or black_initial),
            running=bool(d.get('running', False)),
            paused=bool(d.get('paused', False)),
            paused_by=str(d.get('pausedBy', d.get('paused_by', '')) or '')[:1],
            active_color=(str(d.get('activeColor', d.get('active_color', 'w')) or 'w')[:1]),
            started_at=str(d.get('startedAt', d.get('started_at', '')) or ''),
            expired_color=str(d.get('expiredColor', d.get('expired_color', '')) or '')[:1],
            white_opened=bool(d.get('whiteOpened', d.get('white_opened', False))),
            black_opened=bool(d.get('blackOpened', d.get('black_opened', False))),
        ).normalized()

    def normalized(self) -> 'TimerState':
        if self.active_color not in ('w', 'b'):
            self.active_color = 'w'
        if self.paused_by not in ('', 'w', 'b'):
            self.paused_by = ''
        if self.expired_color not in ('', 'w', 'b'):
            self.expired_color = ''
        self.white_initial_sec = max(1, int(round(self.white_initial_sec)))
        self.black_initial_sec = max(1, int(round(self.black_initial_sec)))
        self.white_remaining_sec = max(0.0, float(self.white_remaining_sec))
        self.black_remaining_sec = max(0.0, float(self.black_remaining_sec))
        self.enabled = bool(self.enabled)
        self.running = bool(self.running)
        self.paused = bool(self.paused)
        self.white_opened = bool(self.white_opened)
        self.black_opened = bool(self.black_opened)
        if not self.enabled:
            self.running = False
            self.paused = False
            self.started_at = ''
            self.expired_color = ''
        if self.expired_color:
            self.running = False
            self.paused = False
            self.started_at = ''
        if not self.running:
            self.started_at = ''
        return self

    def copy(self) -> 'TimerState':
        return TimerState.from_dict(self.to_dict())

    def to_dict(self) -> dict:
        return {
            'enabled': self.enabled,
            'whiteInitialSec': self.white_initial_sec,
            'blackInitialSec': self.black_initial_sec,
            'whiteRemainingSec': self.white_remaining_sec,
            'blackRemainingSec': self.black_remaining_sec,
            'running': self.running,
            'paused': self.paused,
            'pausedBy': self.paused_by,
            'activeColor': self.active_color,
            'startedAt': self.started_at,
            'expiredColor': self.expired_color,
            'whiteOpened': self.white_opened,
            'blackOpened': self.black_opened,
        }

    def both_players_opened(self) -> bool:
        return self.white_opened and self.black_opened

    def mark_opened(self, color: str) -> None:
        if color == 'w':
            self.white_opened = True
        elif color == 'b':
            self.black_opened = True

    def remaining_for(self, color: str, now: Optional[str] = None) -> float:
        rem = self.white_remaining_sec if color == 'w' else self.black_remaining_sec
        if (self.enabled and self.running and not self.paused
                and self.active_color == color and self.started_at):
            rem -= elapsed_seconds(self.started_at, now)
        return max(0.0, rem)

    def apply_elapsed(self, now: Optional[str] = None) -> None:
        """Burn elapsed time into the stored remaining seconds.

        This should be called before switching sides, pausing, or declaring
        timeout. It is intentionally not called on every paint/tick because
        display can compute elapsed time from startedAt without rewriting
        the shared file every second.
        """
        if not self.enabled or not self.running or self.paused or not self.started_at:
            return
        now = now or now_iso()
        elapsed = elapsed_seconds(self.started_at, now)
        if self.active_color == 'w':
            self.white_remaining_sec = max(0.0, self.white_remaining_sec - elapsed)
            if self.white_remaining_sec <= 0:
                self.expired_color = 'w'
        else:
            self.black_remaining_sec = max(0.0, self.black_remaining_sec - elapsed)
            if self.black_remaining_sec <= 0:
                self.expired_color = 'b'
        self.started_at = ''
        if self.expired_color:
            self.running = False
            self.paused = False
        else:
            # Caller will decide whether to restart immediately.
            self.running = False

    def start(self, color: str, now: Optional[str] = None) -> None:
        if not self.enabled or self.expired_color:
            return
        self.active_color = 'w' if color == 'w' else 'b'
        self.running = True
        self.paused = False
        self.paused_by = ''
        self.started_at = now or now_iso()

    def pause(self, paused_by: str = '', now: Optional[str] = None) -> None:
        if not self.enabled or self.expired_color:
            return
        self.apply_elapsed(now or now_iso())
        self.running = False
        self.paused = True
        self.paused_by = paused_by if paused_by in ('w', 'b') else ''
        self.started_at = ''

    def resume(self, now: Optional[str] = None) -> None:
        if not self.enabled or self.expired_color:
            return
        self.paused = False
        self.paused_by = ''
        self.start(self.active_color, now or now_iso())

    def stop(self, now: Optional[str] = None) -> None:
        if not self.enabled:
            return
        self.apply_elapsed(now or now_iso())
        self.running = False
        self.paused = False
        self.started_at = ''

    def switch_after_move(self, mover_color: str, next_color: str, now: Optional[str] = None) -> None:
        if not self.enabled or self.expired_color:
            return
        now = now or now_iso()
        self.active_color = 'w' if mover_color == 'w' else 'b'
        self.apply_elapsed(now)
        if self.expired_color:
            return
        self.start('w' if next_color == 'w' else 'b', now)


@dataclass
class GameSnapshot:
    """Everything we serialize. Pure data; no chess.Board reference --
    `to_game()` rebuilds one on demand."""

    schema_version: int
    game_id: str
    host_color: str          # 'w' or 'b' -- which color the host plays
    created_at: str
    updated_at: str
    fen: str                 # full FEN of the current position
    half_move_count: int     # len(history); used for stale-write detection
    history: list[MoveRecord] = field(default_factory=list)
    position_history: list[str] = field(default_factory=list)
    status: str = 'active'   # active|check|checkmate|stalemate|draw_*|timeout
    result: Optional[str] = None  # '1-0' | '0-1' | '1/2-1/2' once decided
    timer: TimerState = field(default_factory=TimerState.disabled)

    # --- construction ------------------------------------------------------

    @classmethod
    def initial(cls,
                host_color: str,
                timer: Optional[TimerState] = None) -> 'GameSnapshot':
        """Brand-new game in the starting position."""
        assert host_color in ('w', 'b')
        now = now_iso()
        return cls(
            schema_version=SCHEMA_VERSION,
            game_id=new_game_id(),
            host_color=host_color,
            created_at=now,
            updated_at=now,
            fen=chess.STARTING_FEN,
            half_move_count=0,
            history=[],
            position_history=[chess.STARTING_FEN],
            status='active',
            result=None,
            timer=(timer.copy() if timer is not None else TimerState.disabled()),
        )

    @classmethod
    def from_game(cls,
                  game: Game,
                  *,
                  base: 'GameSnapshot',
                  timer: Optional[TimerState] = None,
                  status: Optional[str] = None,
                  result: Optional[str] = None) -> 'GameSnapshot':
        """Snapshot of `game` carrying forward identity fields from `base`."""
        game_status = game.status()
        final_status = status if status is not None else game_status
        final_result = result if result is not None else _result_for(game, final_status, timer)
        return cls(
            schema_version=base.schema_version,
            game_id=base.game_id,
            host_color=base.host_color,
            created_at=base.created_at,
            updated_at=now_iso(),
            fen=game.board.fen(),
            half_move_count=len(game.history),
            history=list(game.history),
            position_history=game.position_history(),
            status=final_status,
            result=final_result,
            timer=(timer.copy() if timer is not None else base.timer.copy()),
        )

    # --- conversion --------------------------------------------------------

    def to_game(self) -> Game:
        """Reconstruct a runnable Game from this snapshot."""
        board = chess.Board(self.fen)
        initial = self.position_history[0] if self.position_history else chess.STARTING_FEN
        return Game(board=board, history=list(self.history), initial_fen=initial)

    # --- serialization -----------------------------------------------------

    def to_dict(self) -> dict:
        return {
            'schemaVersion': self.schema_version,
            'gameId': self.game_id,
            'hostColor': self.host_color,
            'createdAt': self.created_at,
            'updatedAt': self.updated_at,
            'fen': self.fen,
            'halfMoveCount': self.half_move_count,
            'history': [
                {
                    'uci': m.uci,
                    'san': m.san,
                    'captured': m.captured,
                    'timestamp': m.timestamp,
                    'fenAfter': m.fen_after,
                }
                for m in self.history
            ],
            'positionHistory': list(self.position_history),
            'status': self.status,
            'result': self.result,
            'timer': self.timer.to_dict(),
        }

    @classmethod
    def from_dict(cls, d: dict) -> 'GameSnapshot':
        ver = int(d.get('schemaVersion', 0))
        if ver != SCHEMA_VERSION:
            raise ValueError(
                f"Unsupported schemaVersion {ver}; expected {SCHEMA_VERSION}. "
                "This file was written by a different version of ChessNet."
            )
        host = d['hostColor']
        if host not in ('w', 'b'):
            raise ValueError(f"Bad hostColor: {host!r}")
        hist = [
            MoveRecord(
                san=h['san'],
                uci=h['uci'],
                captured=h.get('captured'),
                timestamp=h.get('timestamp', ''),
                fen_after=h.get('fenAfter', ''),
            )
            for h in d.get('history', [])
        ]
        raw_positions = d.get('positionHistory') or d.get('position_history')
        if isinstance(raw_positions, list) and raw_positions:
            position_history = [str(fen) for fen in raw_positions if fen]
        else:
            # Backward compatibility for files written before explicit position
            # history existed. MoveRecord.fen_after has always been present, so
            # analysis mode can still reconstruct the timeline.
            position_history = [chess.STARTING_FEN] + [m.fen_after for m in hist if m.fen_after]
        if not position_history:
            position_history = [chess.STARTING_FEN]
        return cls(
            schema_version=ver,
            game_id=d['gameId'],
            host_color=host,
            created_at=d.get('createdAt', ''),
            updated_at=d.get('updatedAt', ''),
            fen=d.get('fen', chess.STARTING_FEN),
            half_move_count=int(d.get('halfMoveCount', len(hist))),
            history=hist,
            position_history=position_history,
            status=d.get('status', 'active'),
            result=d.get('result'),
            timer=TimerState.from_dict(d.get('timer')),
        )

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2)

    @classmethod
    def from_json(cls, txt: str) -> 'GameSnapshot':
        return cls.from_dict(json.loads(txt))


def result_for_timeout(expired_color: str) -> Optional[str]:
    if expired_color == 'w':
        return '0-1'
    if expired_color == 'b':
        return '1-0'
    return None


def _result_for(game: Game,
                status: Optional[str] = None,
                timer: Optional[TimerState] = None) -> Optional[str]:
    """PGN-style result string for a finished game, or None if still going."""
    if status == 'timeout' and timer is not None:
        return result_for_timeout(timer.expired_color)
    if game.board.is_checkmate():
        # The side whose turn it is just got mated.
        return '0-1' if game.board.turn == chess.WHITE else '1-0'
    if (game.board.is_stalemate()
            or game.board.is_insufficient_material()
            or game.board.is_fivefold_repetition()
            or game.board.is_seventyfive_moves()):
        return '1/2-1/2'
    return None
