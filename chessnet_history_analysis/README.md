# ChessNet (Python port)

A Python rewrite of the MATLAB chess game, replacing MATLAB's `timer`-based
polling with OS-level file watching for instant refresh, on track for a
single-file `.exe` distribution.

## Status: Milestone 5 -- networked play, premoves, clocks, replay, and analysis work

You can now host a game, point a teammate at the same shared file, and
play. Refresh is instant (watchdog event) with a 1s fallback poll so it
still works on SMB/NFS shares that don't propagate filesystem events.

### What works
- **Local hot-seat** -- two players on one machine, full chess rules,
  check/mate, promotion picker, castling, en passant.
- **Optional per-side chess clock** -- set White and Black independently
  in seconds, so unbalanced games like White=30s and Black=120s work.
- **Networked play** via a shared JSON file:
  - Session dialog: Local / Host / Join, pick color (host only),
    pick file path with native Browse dialog.
  - Atomic writes (temp + `os.replace`) so readers never see a torn file.
  - Optimistic concurrency on `halfMoveCount` -- the second of two
    racing writers gets a clear "opponent moved, please retry" error
    rather than clobbering the move.
  - `watchdog` filesystem events for instant refresh (sub-50ms on
    Linux/Windows/Mac local filesystems).
  - 1-second fallback poll catches SMB shares where events don't
    cross hosts.
  - Input lock when it's not your turn (board ignores clicks).
  - Game-id binding for safety, with an intentional same-file New Game path that lets one player restart and the other window automatically follows.
  - Status header: "Your move", "Waiting for {opponent}", check/mate.
  - Clock state is serialized in the shared file and supports unequal White/Black time.
  - Network clock waits for both players to open the game before it starts.
  - Pause/resume clock is available and synchronized through the shared file.
  - Local-only premove queue while waiting for the opponent; queued premoves are shown on your private preview board and are never serialized, so the opponent cannot see them.
- **Replay Last Move** button -- briefly rewinds the board to the previous FEN, then restores the current position without changing the real game state.
- **End-of-game workflow** -- when the game ends, choose New Game, Analyze Game, or Close Game.
  - New Game reuses the same shared file in network mode, so neither player has to re-enter the game-file path.
  - Analyze Game loads stored positions, lets you step through the timeline, and lets you play alternate local-only moves from any reviewed state.
- **31 unit tests pass** covering rules, serialization, timers, premove preview behavior, persistent history, analysis variations, replay behavior, and the network layer.

### What's coming
| Milestone | Adds |
|-----------|------|
| 3 | Done: Premove queue (chess.com-style, local-only), status-bar polish |
| 4 | Done: Per-color timer with pause that syncs across clients |
| 5 | Done: Stored position history, Replay Last Move, end-game analysis mode with alternate local lines |
| 6 | Captured-piece graveyard panel |
| 7 | PyInstaller bundle (single `chess.exe`, no Python install needed) |

## Run

```bash
python -m pip install -r requirements.txt
python main.py
```

Tested on Python 3.10+. Requires PySide6, python-chess, watchdog.

## Run the tests

```bash
python -m tests.test_model
python -m tests.test_serialize
python -m tests.test_netgame
python -m tests.test_timer
python -m tests.test_premove_preview
python -m tests.test_history_analysis
```

## Architecture

```
chessnet/
  model.py             # Game wrapper around python-chess (state + history)
  serialize.py         # GameSnapshot: shared-file JSON schema (FEN + move/position history)
  netgame.py           # NetGame: atomic reads/writes, stale-write detection
  watcher.py           # FileWatcher: watchdog bridged into Qt signals
  gui/
    main_window.py     # QMainWindow, wires together model + netgame + watcher
    board_view.py      # 8x8 widget: paint + click handling
    session_dialog.py  # Local / Host / Join picker
    promotion_dialog.py
    resources.py       # piece sprite cache
assets/                # piece sprites (PB.png ... KW.png) -- carried over
                       # from the MATLAB version
tests/
  test_model.py            # 7 tests: rules, captures, promotion, mate, undo
  test_serialize.py        # 7 tests: snapshot round-trip, schema validation
  test_netgame.py          # 6 tests: atomic writes, stale detection, 2-client sim
  test_timer.py            # 3 tests: unbalanced clocks, handoff, timeout
  test_premove_preview.py  # 3 tests: private preview board + chained premoves
  test_history_analysis.py # 5 tests: position history, same-file restart, analysis, replay
main.py
```

## Why this fixes the MATLAB refresh bug

MATLAB's `timer` object reschedules itself in `onCleanup`. If MATLAB's
event loop is briefly busy (figure resize, GC pause, modal dialog), the
reschedule can fail silently and the polling loop dies. You then have
to click Refresh manually to re-arm it.

The Python version uses two parallel mechanisms:

1. **`watchdog`** -- OS-level filesystem notifications (inotify on
   Linux, `ReadDirectoryChangesW` on Windows, FSEvents on macOS). The
   opponent's atomic rename fires a callback in <50ms with zero
   polling overhead.
2. **`QTimer`** at 1Hz -- a cheap mtime check that runs even if
   watchdog goes silent. Idempotent with the watchdog path (same
   `_refresh_from_file()` slot, debounced by `_refresh_in_flight`).

Even on a NAS that drops every filesystem event, max staleness is 1s
vs MATLAB's 5-10s -- and the manual Refresh button is now a safety
valve rather than a requirement.

## Shared-file schema (v1)

```jsonc
{
  "schemaVersion": 1,
  "gameId": "a3f2b1c4d5e6f708",        // 16 hex chars, set once at bootstrap
  "hostColor": "w",                    // 'w' or 'b'
  "createdAt": "2026-05-14T10:00:00",
  "updatedAt": "2026-05-14T10:32:11",
  "fen": "rnbqkbnr/pppp...",           // python-chess FEN: position + castling
                                       // rights + en passant + halfmove clock
                                       // + fullmove number, all in one string
  "halfMoveCount": 14,                 // strictly increases each move; used for
                                       // optimistic-concurrency stale check
  "history": [
    {"uci": "e2e4", "san": "e4", "captured": null,
     "timestamp": "...", "fenAfter": "..."},
    ...
  ],
  "positionHistory": [                 // initial FEN + every after-move FEN
    "rnbqkbnr/pppp...",
    "rnbqkbnr/pppp... after e4",
    ...
  ],
  "status": "active",                  // active|check|checkmate|stalemate|draw_*|timeout
  "result": null,                      // "1-0" | "0-1" | "1/2-1/2" once decided
  "timer": {                           // optional clock state; disabled by default
    "enabled": true,
    "whiteInitialSec": 30,
    "blackInitialSec": 120,
    "whiteRemainingSec": 30,
    "blackRemainingSec": 120,
    "running": false,
    "activeColor": "w"
  }
}
```
