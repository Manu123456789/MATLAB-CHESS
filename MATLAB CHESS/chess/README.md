# Chess Masters — Networked Edition

MATLAB chess with two-player support over a shared file (network drive, 
Dropbox folder, or anything two machines can both read and write).

## Quick start

From MATLAB, `cd` into this folder, then run:

```matlab
ChessMasters
```

A session dialog appears. Pick one:

- **Local (hot-seat)** — original two-players-one-keyboard mode. File path 
  and color ignored.
- **Host a new networked game** — pick your color and a file path on the 
  shared drive (e.g. `Z:\games\manu-vs-alex.json`). A fresh game file is 
  written. Send the path to your opponent.
- **Join a networked game** — point to the host's file. You're assigned 
  the opposite color automatically. The board orients with your side on 
  the bottom.

For scripted/test use: `ChessMasters('local')` skips the dialog.

## Making a move

1. Click a piece of your color. The square highlights pale yellow and all 
   legal destinations are marked: a small dot for empty squares, a pale 
   red tint on any piece you can capture.
2. Click a destination to move. Click the same piece again (or any 
   non-legal square) to deselect.
3. In networked mode, your move is written to the shared file immediately. 
   The top bar updates to show you're waiting for the opponent.
4. Click **Refresh** whenever you think the opponent has moved. The board 
   rebuilds from the file and briefly highlights the squares the opponent 
   played (pale green flash). There is no background polling — the file 
   is only touched on explicit refresh or your own move.

## Architecture

Three layers, same MVC skeleton as the original:

- **Model** (`Model/`) — board data. Adds `GameState.m`, which is the 
  serializable snapshot class. All persistence goes through 
  `GameState.fromModel` / `GameState.applyToModel`, keeping the on-disk 
  format independent of the live handle-class graph.
- **Controller** (`Controller/`) — piece logic and game rules. Adds 
  `NetGame.m`, which owns the file path and does atomic write + stale-
  check on every save. `King.m` now uses `onCleanup` to guarantee the 
  board is restored if a virtual-move analysis throws.
- **View** (`View/`) — `ChessBoardGUI.m` is rewritten for orientation, 
  overlay highlights, status bar, and the Refresh button. 
  `SessionDialog.m` is new.

## The file format

JSON, schema version 1. Human-readable — you can open the file in any 
editor and understand what's going on. Key fields:

- `gameId` — 16-char hex, locks a session to one specific game. If the 
  file is ever replaced by a different game, the opponent's client will 
  refuse to write over it.
- `hostColor` — which side the host chose. The joiner uses this to pick 
  the opposite.
- `board` — 8 strings, row 1 (white back rank) first. Uppercase = white, 
  lowercase = black, `.` = empty.
- `moved` — 8×8 booleans; tracks which pieces have been moved (used by 
  the pawn double-step rule).
- `turn` — `"w"` or `"b"`, redundant with `moveNumber` but useful when 
  eyeballing the file.
- `moveNumber` — monotonic ply counter starting at 1. The stale-move 
  check compares this against what the writer last saw.
- `lastMove` — `{from, to, piece, color, capture, promotion}`. Used for 
  the highlight flash and as the audit-trail row.
- `history` — list of all `lastMove` objects. Grows forever; no pruning.
- `status` — `"active" | "check" | "checkmate" | "stalemate"`.

## Concurrency & correctness

Turn-based mutual exclusion is the whole story:

- Only the side-to-move can produce a legal state transition, so two 
  players can't legally write at the same time.
- Before writing, the client re-reads the file and verifies `moveNumber` 
  hasn't advanced. If it has (meaning the opponent somehow beat you to 
  the write), the local move is rolled back and you're told to refresh.
- Writes go to `game.json.tmp.XXXX` then `movefile(tmp, target, 'f')` — 
  atomic on POSIX, near-atomic on Windows. Readers mid-swap see either 
  the old file or the new file, not a truncated mess.
- Reads retry up to 3 times with a short backoff, covering the brief 
  window during a rename on network filesystems.

No lockfile. No polling timer. If the network drive is intermittently 
unavailable, moves simply fail with a dialog — click Refresh once the 
drive is reachable again.

## Known limitations

Inherited from the original engine, not fixed here:

- No castling.
- No en passant. (The `lastMove` schema carries enough info to detect 
  it, but the pawn logic doesn't act on it.)
- `checkCheckMate` is occasionally optimistic — it reports mate when the 
  king has no moves but a blocker exists. Same behavior as the original.
- The piece classes use `position = [file rank]` while `chessBoardMap` 
  is indexed `(rank, file)`. New code (`GameState`, `NetGame`, GUI 
  orientation) uses `[row col] = [rank file]` consistently, converting 
  at the boundary. I didn't rewrite the inner piece math because it 
  works and re-verifying every legal-move routine is a separate project.

## Files touched

New:
- `Model/GameState.m`
- `Controller/NetGame.m`
- `View/SessionDialog.m`

Rewritten:
- `View/ChessBoardGUI.m`
- `ChessMasters.m`

Patched:
- `Controller/GameController.m` (`setRound`, `gameStatus` added)
- `Controller/King.m` (`onCleanup` guards on virtual-move helpers)
