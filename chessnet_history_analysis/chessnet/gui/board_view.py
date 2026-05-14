"""
The 8x8 board widget: paints squares + pieces, handles clicks, surfaces
move, promotion, and local-only premove events.
"""
from __future__ import annotations

import chess
from PySide6.QtCore import Qt, QRect, QSize, Signal, QPoint
from PySide6.QtGui import QPainter, QColor, QFont, QMouseEvent, QPen
from PySide6.QtWidgets import QWidget

from ..model import Game
from . import resources


TILE_PX = 80


# Palette -- same intent as the MATLAB version but tuned for Qt's
# alpha-blending so overlays look right against the piece sprites.
COLOR_LIGHT      = QColor(240, 217, 181)
COLOR_DARK       = QColor(181, 136, 99)
COLOR_SELECTED   = QColor(255, 220, 80, 180)
COLOR_LAST_MOVE  = QColor(190, 230, 145, 130)
COLOR_CHECK      = QColor(230, 70, 70, 180)
COLOR_DOT        = QColor(20, 20, 20, 90)
COLOR_CAP_RING   = QColor(200, 60, 60, 220)
COLOR_COORD      = QColor(0, 0, 0, 130)
COLOR_COORD_LITE = QColor(255, 255, 255, 160)
COLOR_PREMOVE    = QColor(80, 170, 255, 115)
COLOR_PREMOVE_SEL = QColor(80, 170, 255, 175)
COLOR_PREMOVE_DOT = QColor(30, 105, 220, 125)


class BoardView(QWidget):
    """Renders the board and emits signals on user interaction.

    Signals:
      move_made(san)                -- a non-promotion move was just pushed
      promotion_requested(from, to)  -- a pawn move that needs a piece pick;
                                       caller must call commit_promotion()
      premove_queued()              -- local premove queue changed
    """

    move_made = Signal(str)
    promotion_requested = Signal(int, int)
    premove_queued = Signal()

    def __init__(self, game: Game, orientation: chess.Color = chess.WHITE, parent=None):
        super().__init__(parent)
        self.game = game
        self.orientation = orientation

        # Selection state for normal moves.
        self.selected: int | None = None
        self.legal_targets: set[int] = set()

        # When True, ordinary clicks do not move immediately. In network mode
        # MainWindow turns this on while waiting for the opponent; if premoves
        # are enabled, those clicks are routed into the local premove queue.
        self.input_locked: bool = False

        # Premove state. This is intentionally local-only and never written to
        # the shared game file, so the opponent cannot see your queued premoves.
        self.premove_enabled: bool = False
        self.premove_color: chess.Color = chess.WHITE
        self.premove_selected: int | None = None
        self.premove_targets: set[int] = set()
        self.premove_queue: list[chess.Move] = []
        self.premove_queue_max: int = 4

        # Optional paint-only override used for replaying the last move. It does
        # not affect legal move generation or the real synchronized game state.
        self.display_board_override: chess.Board | None = None

        self.setFixedSize(QSize(8 * TILE_PX, 8 * TILE_PX))

    # --- public API --------------------------------------------------------

    def set_orientation(self, color: chess.Color) -> None:
        self.orientation = color
        self.clear_selection()
        self.update()

    def set_game(self, game: Game) -> None:
        """Swap in a new Game (e.g. after New Game or a network refresh)."""
        self.game = game
        self.display_board_override = None
        self.clear_selection()
        self.update()

    def set_display_board_override(self, board: chess.Board | None) -> None:
        """Temporarily paint a board that differs from self.game.board.

        Used by Replay Last Move to show the previous state without mutating the
        real game or the shared-file snapshot."""
        self.display_board_override = board.copy(stack=False) if board is not None else None
        self.update()

    def set_premove_mode(self, enabled: bool, color: chess.Color) -> None:
        self.premove_enabled = bool(enabled)
        self.premove_color = color
        if not self.premove_enabled:
            self.clear_premove_selection()
        self.update()

    def clear_selection(self) -> None:
        self.selected = None
        self.legal_targets = set()
        self.clear_premove_selection(update=False)
        self.update()

    def clear_premove_selection(self, *, update: bool = True) -> None:
        self.premove_selected = None
        self.premove_targets = set()
        if update:
            self.update()

    def clear_premoves(self) -> None:
        self.premove_queue.clear()
        self.clear_premove_selection(update=False)
        self.update()
        self.premove_queued.emit()

    def pop_next_premove(self) -> chess.Move | None:
        if not self.premove_queue:
            return None
        move = self.premove_queue.pop(0)
        self.update()
        self.premove_queued.emit()
        return move

    def commit_promotion(self, from_sq: int, to_sq: int, piece_type: int) -> None:
        """Called by the main window after the user picks a promotion piece."""
        move = chess.Move(from_sq, to_sq, promotion=piece_type)
        if move not in self.game.board.legal_moves:
            return
        self.game.push(move)
        self.update()
        self.move_made.emit(self.game.history[-1].san)

    # --- coordinate helpers ------------------------------------------------

    def _square_at(self, px: float, py: float) -> int | None:
        """Map a widget-space pixel to a chess square index (0..63), or None
        if outside the board."""
        col = int(px // TILE_PX)
        row = int(py // TILE_PX)
        if not (0 <= col < 8 and 0 <= row < 8):
            return None
        if self.orientation == chess.WHITE:
            file = col
            rank = 7 - row
        else:
            file = 7 - col
            rank = row
        return chess.square(file, rank)

    def _rect_for(self, sq: int) -> QRect:
        file = chess.square_file(sq)
        rank = chess.square_rank(sq)
        if self.orientation == chess.WHITE:
            col = file
            row = 7 - rank
        else:
            col = 7 - file
            row = rank
        return QRect(col * TILE_PX, row * TILE_PX, TILE_PX, TILE_PX)

    # --- click handling ----------------------------------------------------

    def mousePressEvent(self, e: QMouseEvent) -> None:
        if e.button() != Qt.LeftButton:
            return
        if self.game.is_game_over():
            return
        pos = e.position()
        sq = self._square_at(pos.x(), pos.y())
        if sq is None:
            return
        if self.input_locked:
            if self.premove_enabled:
                self._handle_premove_click(sq)
            return
        self._handle_click(sq)

    def _handle_click(self, sq: int) -> None:
        # Phase 1: nothing selected -- click must be one of our pieces.
        if self.selected is None:
            piece = self.game.piece_at(sq)
            if piece is None or piece.color != self.game.turn:
                return
            self._select(sq)
            return

        # Phase 2: same square clicked -> deselect.
        if sq == self.selected:
            self.clear_selection()
            return

        # Phase 2b: clicked another of our pieces -> re-anchor.
        piece = self.game.piece_at(sq)
        if piece is not None and piece.color == self.game.turn:
            self._select(sq)
            return

        # Phase 2c: clicked an illegal target -> deselect, ignore.
        if sq not in self.legal_targets:
            self.clear_selection()
            return

        # Phase 2d: legal destination. Promotion gets routed to the
        # dialog; the main window calls back via commit_promotion.
        from_sq = self.selected
        if self.game.is_promotion_move(from_sq, sq):
            self.clear_selection()
            self.promotion_requested.emit(from_sq, sq)
            return

        # Plain move.
        move = chess.Move(from_sq, sq)
        # Defensive: should always be legal because we filtered above.
        if move not in self.game.board.legal_moves:
            self.clear_selection()
            return
        self.game.push(move)
        self.clear_selection()
        self.move_made.emit(self.game.history[-1].san)

    def _select(self, sq: int) -> None:
        self.selected = sq
        self.legal_targets = self.game.legal_target_squares(sq)
        self.update()

    # --- premove handling --------------------------------------------------

    def _handle_premove_click(self, sq: int) -> None:
        """Queue a local premove while it is the opponent's turn.

        The candidate move is selected against the private preview board.
        Already queued premoves are replayed locally first, so the user can move
        a premoved piece again. The premove only fires later if it is legal in
        the real position after the opponent's move arrives.
        """
        if len(self.premove_queue) >= self.premove_queue_max and self.premove_selected is None:
            return

        if self.premove_selected is None:
            board = self._candidate_board_for_premove()
            piece = board.piece_at(sq)
            if piece is None or piece.color != self.premove_color:
                return
            self.premove_selected = sq
            self.premove_targets = self._premove_targets_from(sq)
            self.update()
            return

        if sq == self.premove_selected:
            self.clear_premove_selection()
            return

        board = self._candidate_board_for_premove()
        piece = board.piece_at(sq)
        if piece is not None and piece.color == self.premove_color:
            self.premove_selected = sq
            self.premove_targets = self._premove_targets_from(sq)
            self.update()
            return

        if sq not in self.premove_targets:
            self.clear_premove_selection()
            return

        from_sq = self.premove_selected
        move = self._make_premove(from_sq, sq)
        if move is None:
            self.clear_premove_selection()
            return

        # Preserve click order. If the queue is already full, replace the tail
        # with the newly-entered premove rather than silently doing nothing.
        if len(self.premove_queue) >= self.premove_queue_max:
            self.premove_queue[-1] = move
        else:
            self.premove_queue.append(move)
        self.clear_premove_selection(update=False)
        self.update()
        self.premove_queued.emit()

    def _preview_board_for_premoves(self) -> chess.Board:
        """Return the private local board after replaying queued premoves.

        This is deliberately *not* the real game board. It is the chess.com-style
        local preview: while waiting for the opponent, your premoved piece is
        shown on its destination and can be selected again for another queued
        premove. Because no opponent reply has arrived yet, each queued premove
        is evaluated with the turn temporarily set back to the local player's
        color.
        """
        board = self.game.board.copy(stack=False)
        for move in self.premove_queue:
            board.turn = self.premove_color
            if move not in board.legal_moves:
                # The queue can become stale after a refresh/opponent move. Stop
                # previewing at the first stale move instead of mutating the real
                # queue from inside paint/selection code. The firing path is
                # still responsible for discarding illegal premoves.
                break
            board.push(move)
        board.turn = self.premove_color
        return board

    def _board_for_painting(self) -> chess.Board:
        if self.display_board_override is not None:
            return self.display_board_override
        if self.premove_queue:
            return self._preview_board_for_premoves()
        return self.game.board

    def _candidate_board_for_premove(self) -> chess.Board:
        return self._preview_board_for_premoves()

    def _premove_targets_from(self, sq: int) -> set[int]:
        board = self._candidate_board_for_premove()
        return {m.to_square for m in board.legal_moves if m.from_square == sq}

    def _make_premove(self, from_sq: int, to_sq: int) -> chess.Move | None:
        board = self._candidate_board_for_premove()
        candidates = [m for m in board.legal_moves
                      if m.from_square == from_sq and m.to_square == to_sq]
        if not candidates:
            return None
        # If this is a promotion premove, default to queen. This mirrors the
        # common fast-premove behavior and avoids popping a modal dialog while
        # it is still the opponent's turn.
        queen = [m for m in candidates if m.promotion == chess.QUEEN]
        return queen[0] if queen else candidates[0]

    # --- painting ----------------------------------------------------------

    def paintEvent(self, _ev) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        p.setRenderHint(QPainter.SmoothPixmapTransform, True)
        paint_board = self._board_for_painting()

        # Layer 1: base squares.
        for sq in chess.SQUARES:
            rect = self._rect_for(sq)
            is_light = (chess.square_file(sq) + chess.square_rank(sq)) % 2 == 1
            p.fillRect(rect, COLOR_LIGHT if is_light else COLOR_DARK)

        # Layer 2: last-move highlight (under selection so a re-select
        # of the just-moved piece still reads clearly).
        if self.game.board.move_stack:
            last = self.game.board.move_stack[-1]
            p.fillRect(self._rect_for(last.from_square), COLOR_LAST_MOVE)
            p.fillRect(self._rect_for(last.to_square), COLOR_LAST_MOVE)

        # Layer 3: queued premoves. Blue from/to squares are local-only.
        for move in self.premove_queue:
            p.fillRect(self._rect_for(move.from_square), COLOR_PREMOVE)
            p.fillRect(self._rect_for(move.to_square), COLOR_PREMOVE)
        if self.premove_selected is not None:
            p.fillRect(self._rect_for(self.premove_selected), COLOR_PREMOVE_SEL)

        # Layer 4: check tint on the king in check.
        if paint_board.is_check():
            king_sq = paint_board.king(paint_board.turn)
            if king_sq is not None:
                p.fillRect(self._rect_for(king_sq), COLOR_CHECK)

        # Layer 5: selection.
        if self.selected is not None:
            p.fillRect(self._rect_for(self.selected), COLOR_SELECTED)

        # Layer 6: pieces. Queued premoves are painted from the private
        # preview board so the piece visibly moves while you are waiting.
        for sq in chess.SQUARES:
            piece = paint_board.piece_at(sq)
            if piece is None:
                continue
            pix = resources.piece_pixmap(piece)
            if pix.isNull():
                continue
            rect = self._rect_for(sq)
            pad = 6
            target = rect.adjusted(pad, pad, -pad, -pad)
            scaled = pix.scaled(target.size(),
                                Qt.KeepAspectRatio,
                                Qt.SmoothTransformation)
            x = target.x() + (target.width() - scaled.width()) // 2
            y = target.y() + (target.height() - scaled.height()) // 2
            p.drawPixmap(x, y, scaled)

        # Layer 7: legal-move overlays. Empty squares get a centered dot;
        # capture targets get a red ring around the existing piece.
        for sq in self.legal_targets:
            self._draw_target_overlay(p, sq, COLOR_CAP_RING, COLOR_DOT, self.game.board)

        # Layer 8: premove target overlays. Drawn after pieces so the user can
        # clearly see queued-target affordances while waiting.
        premove_target_board = self._candidate_board_for_premove()
        for sq in self.premove_targets:
            self._draw_target_overlay(p, sq, COLOR_PREMOVE_DOT, COLOR_PREMOVE_DOT, premove_target_board)

        # Layer 9: coordinate labels (a..h along bottom rank, 1..8 along
        # left file). Drawn in the square's contrasting corner so they
        # stay readable on both light and dark tiles.
        font = QFont()
        font.setPointSize(8)
        font.setBold(True)
        p.setFont(font)
        for file_idx in range(8):
            letter = chr(ord('a') + (file_idx if self.orientation == chess.WHITE
                                                else 7 - file_idx))
            # Bottom-right of the bottommost square in that column.
            x = file_idx * TILE_PX + TILE_PX - 12
            y = 8 * TILE_PX - 4
            # Color depends on whether the bottommost row's square is light.
            bottom_row = 7
            is_light = (file_idx + bottom_row) % 2 == 1
            p.setPen(COLOR_COORD_LITE if not is_light else COLOR_COORD)
            p.drawText(x, y, letter)
        for rank_idx in range(8):
            digit = (8 - rank_idx) if self.orientation == chess.WHITE \
                                   else (rank_idx + 1)
            # Top-left of the leftmost square in that row.
            is_light = (0 + rank_idx) % 2 == 1
            p.setPen(COLOR_COORD_LITE if not is_light else COLOR_COORD)
            p.drawText(4, rank_idx * TILE_PX + 12, str(digit))

        p.end()

    def _draw_target_overlay(self,
                             p: QPainter,
                             sq: int,
                             capture_color: QColor,
                             quiet_color: QColor,
                             board: chess.Board) -> None:
        rect = self._rect_for(sq)
        if board.piece_at(sq) is not None:
            pen = QPen(capture_color)
            pen.setWidth(4)
            p.setPen(pen)
            p.setBrush(Qt.NoBrush)
            p.drawRect(rect.adjusted(3, 3, -3, -3))
        else:
            p.setPen(Qt.NoPen)
            p.setBrush(quiet_color)
            cx = rect.x() + rect.width() // 2
            cy = rect.y() + rect.height() // 2
            r = TILE_PX // 8
            p.drawEllipse(QPoint(cx, cy), r, r)
