"""
The 8x8 board widget: paints squares + pieces, handles clicks, surfaces
move, promotion, and local-only premove events.
"""
from __future__ import annotations

import math

import chess
from PySide6.QtCore import Qt, QRect, QSize, Signal, QPoint, QPointF
from PySide6.QtGui import QPainter, QColor, QFont, QMouseEvent, QPen, QPolygonF, QPainterPath
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
COLOR_LAST_MOVE_TO = QColor(245, 210, 80, 145)
COLOR_CHECK      = QColor(230, 70, 70, 180)
COLOR_DOT        = QColor(20, 20, 20, 90)
COLOR_CAP_RING   = QColor(200, 60, 60, 220)
COLOR_COORD      = QColor(0, 0, 0, 130)
COLOR_COORD_LITE = QColor(255, 255, 255, 160)
COLOR_PREMOVE    = QColor(80, 170, 255, 115)
COLOR_PREMOVE_SEL = QColor(80, 170, 255, 175)
COLOR_PREMOVE_DOT = QColor(30, 105, 220, 125)
COLOR_ARROW      = QColor(235, 145, 25, 205)
COLOR_ARROW_HEAD = QColor(235, 145, 25, 230)


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

        # Local board-annotation arrow paths. These are paint-only, never serialized,
        # and are cleared by the next ordinary left click. Right-click drag
        # creates a single arrow; right-click/release on squares creates and extends
        # a path one square at a time (for example d2 -> d3 -> e3).
        self.annotation_arrows: list[tuple[int, ...]] = []
        self._active_annotation_path: list[int] = []
        self._arrow_drag_from: int | None = None
        self._arrow_drag_to: int | None = None

        # Optional paint-only override used for replaying the last move. It does
        # not affect legal move generation or the real synchronized game state.
        self.display_board_override: chess.Board | None = None
        # Optional history prefix that matches display_board_override. This
        # lets review/analysis views highlight the move that produced the
        # displayed position instead of always highlighting the real game's
        # final move.
        self.display_history_override = None

        self.setFixedSize(QSize(8 * TILE_PX, 8 * TILE_PX))
        self.setMouseTracking(True)

    # --- public API --------------------------------------------------------

    def set_orientation(self, color: chess.Color) -> None:
        self.orientation = color
        self.clear_selection()
        self.update()

    def set_game(self, game: Game) -> None:
        """Swap in a new Game (e.g. after New Game or a network refresh)."""
        self.game = game
        self.display_board_override = None
        self.display_history_override = None
        self.clear_selection()
        self.clear_annotation_arrows(update=False)
        self.update()

    def set_display_board_override(self, board: chess.Board | None, history=None) -> None:
        """Temporarily paint a board that differs from self.game.board.

        Used by Replay Last Move to show the previous state without mutating the
        real game or the shared-file snapshot."""
        self.display_board_override = board.copy(stack=False) if board is not None else None
        self.display_history_override = list(history) if history is not None else None
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

    def clear_annotation_arrows(self, *, update: bool = True) -> None:
        self.annotation_arrows.clear()
        self._active_annotation_path.clear()
        self._arrow_drag_from = None
        self._arrow_drag_to = None
        if update:
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

    def _center_for(self, sq: int) -> QPointF:
        rect = self._rect_for(sq)
        return QPointF(rect.x() + rect.width() / 2.0,
                       rect.y() + rect.height() / 2.0)

    # --- click handling ----------------------------------------------------

    def mousePressEvent(self, e: QMouseEvent) -> None:
        pos = e.position()
        sq = self._square_at(pos.x(), pos.y())

        if e.button() == Qt.RightButton:
            self._begin_annotation_arrow(sq)
            return

        if e.button() != Qt.LeftButton:
            return

        # Analysis arrows persist while the user is thinking and are cleared by
        # the next ordinary left click, matching chess.com-style board marks.
        if self.annotation_arrows or self._active_annotation_path or self._arrow_drag_from is not None:
            self.clear_annotation_arrows(update=False)

        if self.game.is_game_over():
            self.update()
            return
        if sq is None:
            self.update()
            return
        if self.input_locked:
            if self.premove_enabled:
                self._handle_premove_click(sq)
            else:
                self.update()
            return
        self._handle_click(sq)

    def mouseMoveEvent(self, e: QMouseEvent) -> None:
        if self._arrow_drag_from is None:
            return
        pos = e.position()
        sq = self._square_at(pos.x(), pos.y())
        if sq != self._arrow_drag_to:
            self._arrow_drag_to = sq
            self.update()

    def mouseReleaseEvent(self, e: QMouseEvent) -> None:
        if e.button() != Qt.RightButton or self._arrow_drag_from is None:
            return
        pos = e.position()
        sq = self._square_at(pos.x(), pos.y())
        self._finish_annotation_arrow(sq)

    def _begin_annotation_arrow(self, sq: int | None) -> None:
        if sq is None:
            self._arrow_drag_from = None
            self._arrow_drag_to = None
            return
        # Start from any square, not only occupied squares. This supports pure
        # analysis paths such as d2 -> d3 -> e3 as well as ordinary piece arrows.
        self._arrow_drag_from = sq
        self._arrow_drag_to = sq
        self.update()

    def _finish_annotation_arrow(self, sq: int | None) -> None:
        from_sq = self._arrow_drag_from
        drag_to = self._arrow_drag_to
        self._arrow_drag_from = None
        self._arrow_drag_to = None
        if from_sq is None or sq is None:
            self.update()
            return
        # A press/release on the same square is a path-building click. Each
        # subsequent right-click extends the active path from the previous square.
        if sq == from_sq and (drag_to is None or drag_to == from_sq):
            self._handle_annotation_path_click(sq)
            return
        # A true drag creates/toggles a standalone arrow and ends any click-path
        # currently being built.
        self._active_annotation_path.clear()
        self._toggle_annotation_path((from_sq, sq))
        self.update()

    def _handle_annotation_path_click(self, sq: int) -> None:
        if not self._active_annotation_path:
            self._active_annotation_path = [sq]
            self.update()
            return
        if sq == self._active_annotation_path[-1]:
            # Right-clicking the current endpoint again cancels the active path.
            self._active_annotation_path.clear()
            self.update()
            return
        self._active_annotation_path.append(sq)
        self.update()

    def _toggle_annotation_path(self, path: tuple[int, ...]) -> None:
        if len(path) < 2 or any(sq is None for sq in path):
            return
        if path in self.annotation_arrows:
            # Re-drawing the same arrow toggles it off, a common analysis-board
            # convenience that also prevents accidental duplicates.
            self.annotation_arrows.remove(path)
        else:
            self.annotation_arrows.append(path)

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
            # Preserve the useful "click another own piece to reselect" behavior,
            # except when the clicked friendly square is a plausible conditional
            # recapture square for the already-selected piece.
            if not self._piece_can_reach_own_occupied_premove_target(board, self.premove_selected, sq):
                self.premove_selected = sq
                self.premove_targets = self._premove_targets_from(sq)
                self.update()
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
            if not self._apply_preview_move(board, move):
                # The queue can become stale after a refresh/opponent move. Stop
                # previewing at the first stale move instead of mutating the real
                # queue from inside paint/selection code. The firing path is
                # still responsible for discarding illegal premoves.
                break
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
        targets = {m.to_square for m in board.legal_moves if m.from_square == sq}
        # Add friendly-occupied squares that the selected piece could recapture
        # onto if the opponent captures that friendly piece first. These are only
        # visual suggestions: the click handler now accepts any destination square
        # and the real board checks legality only when the premove fires.
        for target_sq in chess.SQUARES:
            if self._piece_can_reach_own_occupied_premove_target(board, sq, target_sq):
                targets.add(target_sq)
        return targets

    def _make_premove(self, from_sq: int, to_sq: int) -> chess.Move | None:
        if from_sq == to_sq:
            return None
        board = self._candidate_board_for_premove()
        mover = board.piece_at(from_sq)
        if mover is None or mover.color != self.premove_color:
            return None
        # Do not choose a promotion piece while the premove is only a local
        # preview. A pawn premoved to the back rank is painted as a pawn, and
        # MainWindow asks for the promotion piece only if/when the premove
        # actually becomes legal and fires after the opponent's move.
        return chess.Move(from_sq, to_sq)

    def _last_move_for_painting(self) -> chess.Move | None:
        """Return the last real move even after network reloads from FEN.

        python-chess move_stack is lost when a shared-file snapshot is rebuilt
        from FEN, but ChessNet persists UCI history. Reading history here keeps
        the yellow last-move cue active for both your own moves and opponent
        moves that arrive through refresh/poll/watchdog.
        """
        history = self.display_history_override if self.display_history_override is not None else self.game.history
        if history:
            try:
                return chess.Move.from_uci(history[-1].uci)
            except ValueError:
                return None
        if self.game.board.move_stack:
            return self.game.board.move_stack[-1]
        return None

    def _piece_can_reach_own_occupied_premove_target(self, board: chess.Board, from_sq: int, to_sq: int) -> bool:
        """Allow chess.com-style conditional recapture premoves.

        The target may currently contain one of our own pieces. That is illegal
        in the present position, but it is a valid premove intention: if the
        opponent captures that piece, our selected piece should recapture on
        that square. We validate by temporarily clearing the friendly target
        square and asking python-chess whether the movement pattern would be
        legal from the preview position.
        """
        mover = board.piece_at(from_sq)
        target = board.piece_at(to_sq)
        if mover is None or mover.color != self.premove_color:
            return False
        if target is None or target.color != self.premove_color:
            return False
        # Pawns are special: python-chess only generates diagonal pawn
        # captures when an opponent piece is present. For a conditional
        # recapture premove, the target is still occupied by our own piece, so
        # validate the pawn's diagonal capture geometry directly. The real move
        # will still be legality-checked when it fires.
        if mover.piece_type == chess.PAWN:
            df = chess.square_file(to_sq) - chess.square_file(from_sq)
            dr = chess.square_rank(to_sq) - chess.square_rank(from_sq)
            expected_dr = 1 if mover.color == chess.WHITE else -1
            return abs(df) == 1 and dr == expected_dr

        probe = board.copy(stack=False)
        probe.turn = self.premove_color
        probe.remove_piece_at(to_sq)
        return any(m.from_square == from_sq and m.to_square == to_sq
                   for m in probe.legal_moves)

    def _apply_preview_move(self, board: chess.Board, move: chess.Move) -> bool:
        """Apply one queued premove to the private preview board.

        The preview board represents intent, not legality. If a queued premove is
        currently legal, we push it normally. Otherwise we paint it directly by
        moving the piece to the requested destination, including diagonal pawn
        captures that are only expected to become legal after the opponent moves
        or en-passant rights appear. The real firing path still uses
        python-chess legal_moves and only writes the move if it is legal then.
        """
        board.turn = self.premove_color
        if move in board.legal_moves:
            board.push(move)
            return True
        piece = board.piece_at(move.from_square)
        if piece is None or piece.color != self.premove_color:
            return False
        board.remove_piece_at(move.from_square)
        board.remove_piece_at(move.to_square)
        piece_type = move.promotion if move.promotion is not None else piece.piece_type
        board.set_piece_at(move.to_square, chess.Piece(piece_type, piece.color))
        board.clear_stack()
        board.turn = self.premove_color
        return True

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
        # of the just-moved piece still reads clearly). Network snapshots are
        # reconstructed from FEN, so board.move_stack is often empty after an
        # opponent refresh. Use persisted move history first so both local and
        # opponent moves are highlighted reliably.
        last = self._last_move_for_painting()
        if last is not None:
            p.fillRect(self._rect_for(last.from_square), COLOR_LAST_MOVE)
            p.fillRect(self._rect_for(last.to_square), COLOR_LAST_MOVE_TO)

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

        # Layer 9: local analysis arrows. Drawn late so arrows remain visible
        # above pieces/highlights instead of disappearing behind the board.
        for path in self.annotation_arrows:
            self._draw_annotation_path(p, path)
        if len(self._active_annotation_path) == 1:
            self._draw_annotation_anchor(p, self._active_annotation_path[0])
        elif len(self._active_annotation_path) >= 2:
            self._draw_annotation_path(p, tuple(self._active_annotation_path))
        if self._arrow_drag_from is not None and self._arrow_drag_to is not None \
                and self._arrow_drag_to != self._arrow_drag_from:
            self._draw_annotation_path(p, (self._arrow_drag_from, self._arrow_drag_to), preview=True)

        # Layer 10: coordinate labels (a..h along bottom rank, 1..8 along
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

    def _draw_annotation_path(self,
                              p: QPainter,
                              squares: tuple[int, ...],
                              *,
                              preview: bool = False) -> None:
        points = self._points_for_annotation_path(squares)
        if len(points) < 2:
            return

        # Shorten only the first and last legs. Intermediate bends stay exactly
        # on square centers so manually-built paths read as intentional routes.
        draw_points = [QPointF(pt.x(), pt.y()) for pt in points]
        start_margin = TILE_PX * 0.18
        end_margin = TILE_PX * 0.25
        self._trim_endpoint(draw_points, 0, 1, start_margin)
        self._trim_endpoint(draw_points, -1, -2, end_margin)

        color = QColor(COLOR_ARROW)
        head_color = QColor(COLOR_ARROW_HEAD)
        if preview:
            color.setAlpha(145)
            head_color.setAlpha(175)

        pen = QPen(color)
        pen.setWidth(max(8, TILE_PX // 9))
        pen.setCapStyle(Qt.RoundCap)
        pen.setJoinStyle(Qt.RoundJoin)
        p.setPen(pen)
        p.setBrush(Qt.NoBrush)

        path = QPainterPath(draw_points[0])
        for pt in draw_points[1:]:
            path.lineTo(pt)
        p.drawPath(path)

        self._draw_annotation_arrowhead(p, draw_points[-2], draw_points[-1], head_color)

    def _points_for_annotation_path(self, squares: tuple[int, ...]) -> list[QPointF]:
        expanded = list(squares)
        if len(expanded) == 2:
            bend = self._knight_bend_square(expanded[0], expanded[1])
            if bend is not None:
                expanded = [expanded[0], bend, expanded[1]]
        points: list[QPointF] = []
        for sq in expanded:
            pt = self._center_for(sq)
            if points and math.hypot(pt.x() - points[-1].x(), pt.y() - points[-1].y()) < 1.0:
                continue
            points.append(pt)
        return points

    def _knight_bend_square(self, from_sq: int, to_sq: int) -> int | None:
        from_file = chess.square_file(from_sq)
        from_rank = chess.square_rank(from_sq)
        to_file = chess.square_file(to_sq)
        to_rank = chess.square_rank(to_sq)
        df = to_file - from_file
        dr = to_rank - from_rank
        if df == 0 or dr == 0:
            return None

        piece = self._board_for_painting().piece_at(from_sq)
        is_knight_piece = piece is not None and piece.piece_type == chess.KNIGHT
        is_knight_geometry = sorted((abs(df), abs(dr))) == [1, 2]
        if not (is_knight_piece or is_knight_geometry):
            return None

        # Use the long leg first. For b1 -> c3 this gives b3 -> c3; for a1 -> c2
        # this gives c1 -> c2. The board orientation is handled later by _center_for.
        if abs(dr) >= abs(df):
            bend_file, bend_rank = from_file, to_rank
        else:
            bend_file, bend_rank = to_file, from_rank
        if not (0 <= bend_file < 8 and 0 <= bend_rank < 8):
            return None
        return chess.square(bend_file, bend_rank)

    @staticmethod
    def _trim_endpoint(points: list[QPointF], endpoint_idx: int, neighbor_idx: int, margin: float) -> None:
        end = points[endpoint_idx]
        neighbor = points[neighbor_idx]
        dx = end.x() - neighbor.x()
        dy = end.y() - neighbor.y()
        length = math.hypot(dx, dy)
        if length < 1.0:
            return
        ux = dx / length
        uy = dy / length
        if endpoint_idx == 0:
            points[endpoint_idx] = QPointF(end.x() - ux * margin, end.y() - uy * margin)
        else:
            points[endpoint_idx] = QPointF(end.x() - ux * margin, end.y() - uy * margin)

    def _draw_annotation_arrowhead(self,
                                   p: QPainter,
                                   prev: QPointF,
                                   tip: QPointF,
                                   head_color: QColor) -> None:
        dx = tip.x() - prev.x()
        dy = tip.y() - prev.y()
        length = math.hypot(dx, dy)
        if length < 1.0:
            return
        ux = dx / length
        uy = dy / length
        head_len = TILE_PX * 0.26
        head_w = TILE_PX * 0.18
        base = QPointF(tip.x() - ux * head_len, tip.y() - uy * head_len)
        perp_x = -uy
        perp_y = ux
        left = QPointF(base.x() + perp_x * head_w, base.y() + perp_y * head_w)
        right = QPointF(base.x() - perp_x * head_w, base.y() - perp_y * head_w)
        p.setPen(Qt.NoPen)
        p.setBrush(head_color)
        p.drawPolygon(QPolygonF([tip, left, right]))

    def _draw_annotation_anchor(self, p: QPainter, sq: int) -> None:
        center = self._center_for(sq)
        color = QColor(COLOR_ARROW_HEAD)
        color.setAlpha(185)
        pen = QPen(color)
        pen.setWidth(4)
        p.setPen(pen)
        p.setBrush(Qt.NoBrush)
        r = TILE_PX * 0.16
        p.drawEllipse(center, r, r)

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
