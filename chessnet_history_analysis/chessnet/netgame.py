"""
NetGame: owns the shared-file game session. Responsibilities:

  1. Atomic writes via temp file + os.replace (atomic on POSIX, atomic on
     Windows NTFS, best-effort on SMB; readers never see a torn file).
  2. Optimistic concurrency: before writing, re-read the file and check
     halfMoveCount didn't advance under us. If it did, the opponent
     wrote ahead and we refuse rather than clobber their move.
  3. Game-id binding: every read verifies the file still belongs to the
     game we joined. Catches a teammate accidentally overwriting the
     file with a fresh game.
  4. Retry-with-backoff on reads. Mid-rename on the writer's side can
     briefly fail open() on the reader's side; a few short retries
     hide this.

The GUI never sees raw filesystem ops -- it pulls a GameSnapshot and
hands one back. Network-mode polling and watchdog wiring live in
main_window.py; this class is just I/O.
"""
from __future__ import annotations

import json
import os
import secrets
import time
from typing import Optional

from .model import Game
from .serialize import GameSnapshot, TimerState


class StaleWriteError(Exception):
    """Raised when our optimistic-concurrency check finds the file has
    advanced past our base snapshot. The caller should re-sync and
    surface the conflict to the user."""


class WrongGameError(Exception):
    """Raised when the file's gameId no longer matches our session.
    Probably a teammate started a new game in the same file."""


class NetGame:
    """One side of a networked game. Holds my color, the game id, and
    the most recent snapshot we've seen on disk."""

    # Read-retry tuning. Two retries with short backoff covers virtually
    # all transient mid-rename failures on SMB without making real
    # errors take too long to surface.
    READ_RETRIES = 3
    READ_BACKOFF_MS = 80

    def __init__(self, file_path: str, my_color: str, snapshot: GameSnapshot):
        if my_color not in ('w', 'b'):
            raise ValueError(f"my_color must be 'w' or 'b', got {my_color!r}")
        self.file_path = os.path.abspath(file_path)
        self.my_color = my_color
        self.game_id = snapshot.game_id
        self.last_seen: GameSnapshot = snapshot
        # Cache the file's mtime after every successful read/write so the
        # fallback poller can cheaply skip when nothing changed.
        self._last_seen_mtime: float = 0.0
        try:
            self._last_seen_mtime = os.path.getmtime(self.file_path)
        except OSError:
            pass

    # --- queries -----------------------------------------------------------

    @property
    def my_turn(self) -> bool:
        """True iff it's our color's move and the game isn't over."""
        s = self.last_seen
        side_to_move = 'w' if s.fen.split()[1] == 'w' else 'b'
        if side_to_move != self.my_color:
            return False
        return s.status in ('active', 'check')

    def file_mtime(self) -> Optional[float]:
        """Last-modified time of the shared file, or None if missing.
        Cheap pre-check for the fallback poller."""
        try:
            return os.path.getmtime(self.file_path)
        except OSError:
            return None

    def mtime_changed(self) -> bool:
        """True if the file's mtime is different from what we saw at the
        last successful read/write. Used by the fallback poll to skip
        unnecessary parses."""
        m = self.file_mtime()
        if m is None:
            return False
        return m != self._last_seen_mtime

    # --- reads -------------------------------------------------------------

    def load(self, *, allow_rebind: bool = False) -> GameSnapshot:
        """Read+parse the shared file. Verifies game-id and updates the
        cached last-seen snapshot.

        If allow_rebind is true, a different gameId in the same file is treated
        as an intentional New Game request. This lets one player restart the
        shared-file session and the other player's window automatically follows
        without asking for the file path again."""
        snap = self._read_with_retry()
        if snap.game_id != self.game_id:
            if not allow_rebind:
                raise WrongGameError(
                    f"File now belongs to a different game ({snap.game_id}). "
                    f"Expected {self.game_id}."
                )
            self.rebind_to_snapshot(snap)
            return snap
        self.last_seen = snap
        self._last_seen_mtime = self.file_mtime() or self._last_seen_mtime
        return snap

    def rebind_to_snapshot(self, snap: GameSnapshot, *, my_color: str | None = None) -> None:
        """Bind this client to a replacement game in the same file.

        By default the rebinding client becomes the non-host color. The client
        that initiated New Game passes my_color explicitly before writing, while
        the opponent simply reloads and lands on the opposite color."""
        self.game_id = snap.game_id
        if my_color in ('w', 'b'):
            self.my_color = my_color
        else:
            self.my_color = 'b' if snap.host_color == 'w' else 'w'
        self.last_seen = snap
        self._last_seen_mtime = self.file_mtime() or self._last_seen_mtime

    def _read_with_retry(self) -> GameSnapshot:
        """Read+parse with a few retries. SMB/NFS sometimes flap during
        the rename half of another writer's atomic update."""
        last_err: Optional[Exception] = None
        for attempt in range(self.READ_RETRIES):
            try:
                with open(self.file_path, 'r', encoding='utf-8') as f:
                    txt = f.read()
                if not txt.strip():
                    raise ValueError("empty file")
                return GameSnapshot.from_json(txt)
            except (OSError, json.JSONDecodeError, ValueError, KeyError) as e:
                last_err = e
                time.sleep(self.READ_BACKOFF_MS / 1000.0 * (attempt + 1))
        assert last_err is not None
        raise last_err

    # --- writes ------------------------------------------------------------

    def save(self,
             game: Game,
             *,
             timer: TimerState | None = None,
             status: str | None = None,
             result: str | None = None) -> GameSnapshot:
        """Commit `game` as the next state of this session.

        Performs the optimistic-concurrency check: re-reads the file
        and refuses if halfMoveCount advanced past last_seen. The
        caller should re-sync (call load) and prompt the user. Timer
        state is carried in the same atomic snapshot so clock handoff
        cannot get separated from the move.
        """
        self._check_current_for_write()
        new_snap = GameSnapshot.from_game(
            game, base=self.last_seen, timer=timer, status=status, result=result
        )
        self._write_atomic(new_snap)
        self.last_seen = new_snap
        self._last_seen_mtime = self.file_mtime() or self._last_seen_mtime
        return new_snap

    def save_snapshot(self, snapshot: GameSnapshot) -> GameSnapshot:
        """Commit a metadata-only snapshot, such as clock start/pause/timeout.

        The same half-move concurrency token is enforced so a timer-only
        write never overwrites a move that arrived while this client was
        updating clock metadata.
        """
        if snapshot.game_id != self.game_id:
            raise WrongGameError(
                f"Snapshot belongs to a different game ({snapshot.game_id})."
            )
        self._check_current_for_write()
        self._write_atomic(snapshot)
        self.last_seen = snapshot
        self._last_seen_mtime = self.file_mtime() or self._last_seen_mtime
        return snapshot

    def _check_current_for_write(self) -> GameSnapshot:
        # Stale-write check: did anyone (probably the opponent) write
        # since our last sync? If so, we'd be stomping their move/status.
        current = self._read_with_retry()
        if current.game_id != self.game_id:
            raise WrongGameError(
                f"File belongs to a different game ({current.game_id})."
            )
        if current.half_move_count != self.last_seen.half_move_count:
            raise StaleWriteError(
                f"Opponent wrote a new move "
                f"(disk={current.half_move_count}, "
                f"ours={self.last_seen.half_move_count}). "
                "Sync before retrying."
            )
        return current

    def start_new_game(self, snapshot: GameSnapshot, *, my_color: str) -> None:
        """Replace the shared file with a fresh game and bind this window to it.

        This is intentionally a bootstrap-style write: New Game is an explicit
        session reset, so it is allowed to replace the old finished-game file
        and notify the other client through the same path."""
        self._write_atomic(snapshot)
        self.rebind_to_snapshot(snapshot, my_color=my_color)
        self._last_seen_mtime = self.file_mtime() or 0.0

    def bootstrap(self, snapshot: GameSnapshot) -> None:
        """First write of a brand-new game. No stale check (file may not
        even exist). Locks this NetGame to the snapshot's game id."""
        self._write_atomic(snapshot)
        self.last_seen = snapshot
        self.game_id = snapshot.game_id
        self._last_seen_mtime = self.file_mtime() or 0.0

    def _write_atomic(self, snapshot: GameSnapshot) -> None:
        """Write snapshot to <path>.tmp.<random> in the same directory,
        then os.replace it onto the target. Same-directory rename is
        the only way to get atomicity on most filesystems."""
        directory = os.path.dirname(self.file_path) or '.'
        base = os.path.basename(self.file_path)
        suffix = secrets.token_hex(4)
        tmp_path = os.path.join(directory, f'.{base}.tmp.{suffix}')

        txt = snapshot.to_json()
        try:
            with open(tmp_path, 'w', encoding='utf-8') as f:
                f.write(txt)
                # Best-effort durability. Network drives often ignore
                # fsync; that's fine -- the rename is the real safety.
                try:
                    f.flush()
                    os.fsync(f.fileno())
                except OSError:
                    pass
            os.replace(tmp_path, self.file_path)
        except Exception:
            # Clean up the temp if we never got to the replace.
            try:
                if os.path.exists(tmp_path):
                    os.remove(tmp_path)
            except OSError:
                pass
            raise
