"""
Game state. Thin wrapper around python-chess that adds the metadata we
need for networked play (move timestamps, captured-piece codes, status
classification). The underlying chess.Board owns all rule enforcement.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

import chess


@dataclass
class MoveRecord:
    """One half-move + everything we want to display or persist about it."""
    san: str
    uci: str
    captured: Optional[str]   # piece symbol if any ('p', 'N', ...), else None
    timestamp: str            # ISO-8601 seconds
    fen_after: str            # full FEN of resulting position


def _captured_symbol(board: chess.Board, move: chess.Move) -> Optional[str]:
    """Resolve what piece was captured by `move` BEFORE the move is pushed.

    Handles en-passant (the captured pawn is not on the destination square).
    """
    if not board.is_capture(move):
        return None
    if board.is_en_passant(move):
        # The victim is the pawn of the opposite color on the same rank
        # as the moving pawn's source, on the file of the destination.
        return 'p' if board.turn == chess.WHITE else 'P'
    victim = board.piece_at(move.to_square)
    return victim.symbol() if victim is not None else None


@dataclass
class Game:
    """In-memory game state. Network sync (NetGame) will wrap this later."""
    board: chess.Board = field(default_factory=chess.Board)
    history: list[MoveRecord] = field(default_factory=list)
    initial_fen: str = chess.STARTING_FEN

    # --- queries -----------------------------------------------------------

    @property
    def turn(self) -> chess.Color:
        return self.board.turn

    def piece_at(self, square: int) -> Optional[chess.Piece]:
        return self.board.piece_at(square)

    def legal_moves_from(self, square: int) -> list[chess.Move]:
        """Every legal move whose source is `square`. Includes promotions
        as separate Move objects (one per promotion piece type)."""
        return [m for m in self.board.legal_moves if m.from_square == square]

    def legal_target_squares(self, square: int) -> set[int]:
        """De-duplicated set of destination squares reachable from `square`.

        Promotion moves collapse to a single destination (the dialog picks
        the piece type after the click).
        """
        return {m.to_square for m in self.legal_moves_from(square)}

    def is_promotion_move(self, from_sq: int, to_sq: int) -> bool:
        piece = self.board.piece_at(from_sq)
        if piece is None or piece.piece_type != chess.PAWN:
            return False
        target_rank = chess.square_rank(to_sq)
        return (piece.color == chess.WHITE and target_rank == 7) or \
               (piece.color == chess.BLACK and target_rank == 0)

    def status(self) -> str:
        """High-level state classification for the UI."""
        if self.board.is_checkmate():
            return 'checkmate'
        if self.board.is_stalemate():
            return 'stalemate'
        if self.board.is_insufficient_material():
            return 'draw_insufficient'
        if self.board.is_fivefold_repetition():
            return 'draw_repetition'
        if self.board.is_seventyfive_moves():
            return 'draw_75moves'
        if self.board.is_check():
            return 'check'
        return 'active'

    def is_game_over(self) -> bool:
        s = self.status()
        return s == 'checkmate' or s == 'stalemate' or s.startswith('draw_')

    def position_history(self) -> list[str]:
        """Full-position FEN sequence from the starting position through
        every recorded half-move. The first entry is the initial board; each
        later entry is the board after one move. This gives the GUI a stable
        review/replay timeline without re-applying moves during analysis."""
        return [self.initial_fen] + [m.fen_after for m in self.history]

    # --- mutations ---------------------------------------------------------

    def push(self, move: chess.Move) -> MoveRecord:
        """Apply `move` (must be legal). Returns the recorded half-move."""
        if move not in self.board.legal_moves:
            raise ValueError(f"illegal move: {move.uci()}")
        san = self.board.san(move)
        captured = _captured_symbol(self.board, move)
        self.board.push(move)
        record = MoveRecord(
            san=san,
            uci=move.uci(),
            captured=captured,
            timestamp=datetime.now().isoformat(timespec='seconds'),
            fen_after=self.board.fen(),
        )
        self.history.append(record)
        return record

    def pop(self) -> Optional[MoveRecord]:
        """Undo the last move. Returns the removed record, or None if empty."""
        if not self.history:
            return None
        self.board.pop()
        return self.history.pop()

    def reset(self) -> None:
        self.board.reset()
        self.history.clear()
        self.initial_fen = chess.STARTING_FEN
