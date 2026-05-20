"""Captured-piece graveyard widgets."""
from __future__ import annotations

import chess
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QWidget, QLabel, QGridLayout, QVBoxLayout, QFrame

from ..model import Game
from . import resources


_ORDER = {
    chess.QUEEN: 0,
    chess.ROOK: 1,
    chess.BISHOP: 2,
    chess.KNIGHT: 3,
    chess.PAWN: 4,
    chess.KING: 5,
}


class CapturedPiecesWidget(QWidget):
    """Small side panel showing captured white and black pieces.

    MoveRecord.captured stores the captured piece symbol using python-chess
    convention: uppercase for a white victim, lowercase for a black victim.
    The panel therefore shows pieces by victim color, which is the usual
    graveyard representation: every piece no longer on the board.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        root = QVBoxLayout(self)
        root.setContentsMargins(6, 0, 0, 0)
        root.setSpacing(6)

        self.white_panel, self.white_grid = self._make_panel("Captured White")
        self.black_panel, self.black_grid = self._make_panel("Captured Black")
        root.addWidget(self.white_panel)
        root.addWidget(self.black_panel)
        root.addStretch(1)
        self.setMinimumWidth(150)

    def _make_panel(self, title: str) -> tuple[QFrame, QGridLayout]:
        frame = QFrame()
        frame.setFrameShape(QFrame.StyledPanel)
        layout = QVBoxLayout(frame)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(4)
        label = QLabel(title)
        label.setAlignment(Qt.AlignCenter)
        label.setStyleSheet("font-weight: bold;")
        grid = QGridLayout()
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setSpacing(2)
        layout.addWidget(label)
        layout.addLayout(grid)
        return frame, grid

    def set_game(self, game: Game) -> None:
        white: list[chess.Piece] = []
        black: list[chess.Piece] = []
        for rec in game.history:
            symbol = rec.captured
            if not symbol:
                continue
            piece = chess.Piece.from_symbol(symbol)
            if piece.color == chess.WHITE:
                white.append(piece)
            else:
                black.append(piece)
        white.sort(key=lambda p: (_ORDER.get(p.piece_type, 99), p.symbol()))
        black.sort(key=lambda p: (_ORDER.get(p.piece_type, 99), p.symbol()))
        self._fill_grid(self.white_grid, white)
        self._fill_grid(self.black_grid, black)

    def _fill_grid(self, grid: QGridLayout, pieces: list[chess.Piece]) -> None:
        while grid.count():
            item = grid.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()
        if not pieces:
            empty = QLabel("—")
            empty.setAlignment(Qt.AlignCenter)
            grid.addWidget(empty, 0, 0)
            return
        for i, piece in enumerate(pieces):
            lbl = QLabel()
            lbl.setAlignment(Qt.AlignCenter)
            pix = resources.piece_pixmap(piece)
            if not pix.isNull():
                lbl.setPixmap(pix.scaled(26, 26, Qt.KeepAspectRatio, Qt.SmoothTransformation))
            else:
                lbl.setText(piece.unicode_symbol())
            grid.addWidget(lbl, i // 4, i % 4)
