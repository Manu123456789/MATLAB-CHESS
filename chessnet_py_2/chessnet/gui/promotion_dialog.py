"""Promotion piece picker. Shown when a pawn reaches the last rank."""
from __future__ import annotations

import chess
from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QDialog, QHBoxLayout, QPushButton

from . import resources


class PromotionDialog(QDialog):
    """Modal picker offering Q/R/B/N for the player who's promoting.

    On accept, `choice` holds a chess piece-type constant (chess.QUEEN etc).
    """

    BUTTON_PX = 90

    def __init__(self, color: chess.Color, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Promote pawn")
        self.setModal(True)
        self.choice: int | None = None

        layout = QHBoxLayout(self)
        layout.setSpacing(6)
        for piece_type, label in [
            (chess.QUEEN,  'Queen'),
            (chess.ROOK,   'Rook'),
            (chess.BISHOP, 'Bishop'),
            (chess.KNIGHT, 'Knight'),
        ]:
            btn = QPushButton()
            btn.setToolTip(label)
            pix = resources.piece_pixmap(chess.Piece(piece_type, color))
            if not pix.isNull():
                btn.setIcon(QIcon(pix))
                btn.setIconSize(QSize(self.BUTTON_PX - 18, self.BUTTON_PX - 18))
            else:
                btn.setText(label)
            btn.setFixedSize(self.BUTTON_PX, self.BUTTON_PX)
            btn.clicked.connect(lambda _checked=False, pt=piece_type: self._pick(pt))
            layout.addWidget(btn)

    def _pick(self, piece_type: int) -> None:
        self.choice = piece_type
        self.accept()
