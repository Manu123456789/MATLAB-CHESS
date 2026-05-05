# Stockfish Bot Setup

This project now supports a local game against a UCI-compatible Stockfish executable.

## Important

The startup dialog expects the path to a compiled Stockfish executable, not just the Stockfish source folder.

On Windows, this usually means selecting a file like:

```text
stockfish-windows-x86-64-avx2.exe
```

If you only have the Stockfish source code, compile it first or download an official prebuilt Stockfish executable.

## In the MATLAB startup dialog

1. Run `ChessMasters`.
2. Choose **Play against Stockfish**.
3. Pick your human color.
4. Browse to the Stockfish executable.
5. Click **Stockfish Options...** to configure UCI options.
6. Start the game.

## Supported option categories

The dialog exposes the common Stockfish UCI options, including:

- Threads
- Hash
- MultiPV
- Skill Level
- UCI_LimitStrength
- UCI_Elo
- Move Overhead
- Ponder
- UCI_ShowWDL
- UCI_Chess960
- Syzygy options
- EvalFile / EvalFileSmall
- Debug Log File
- NumaPolicy

It also includes a raw **Extra setoption lines** field. Use this for any Stockfish option not explicitly shown by the dialog:

```text
Option Name=value
```

For UCI button options, use only the option name:

```text
Clear Hash
```

## Search controls

Search can be limited by:

- `movetime`
- `depth`
- `nodes`
- `mate`
- the live game clock using `wtime`, `btime`, `winc`, and `binc`

## Post-game Stockfish analysis

After a game ends, click **Review Game** in the result dialog. The right-side **Stockfish Analysis** panel becomes active.

Workflow:

1. Use **<**, **>**, **Live**, or **History** to move to the position you want to review.
2. Click **Analyze Position**.
3. The panel shows the best move and up to three Stockfish principal variations.
4. Click **Play Best Move** to place Stockfish's recommended move on the review board and continue exploring the line.
5. You can also ignore the engine recommendation and move pieces manually in review mode to test your own candidate moves.

For analysis, the code sends the current board as FEN using the UCI `position fen ...` command. Analysis is forced to full-strength settings by disabling `UCI_LimitStrength`, setting `Skill Level` to 20, and using a deeper bounded search. If the original game was not a Stockfish game, click **Engine...** or analyze once and select a compiled Stockfish executable when prompted.
