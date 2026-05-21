"""Left-of-board Stockfish advantage bar."""
from __future__ import annotations

import math
from typing import Optional

from PySide6.QtCore import QSize, Qt, QRectF
from PySide6.QtGui import QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import QWidget


class AdvantageBar(QWidget):
    """Vertical evaluation bar. Positive score favors White; negative Black."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._score_cp_white: Optional[int] = None
        self._mate_white: Optional[int] = None
        self._thinking = False
        self._message = "No eval"
        self.setFixedSize(QSize(42, 640))
        self.setToolTip("Stockfish advantage bar. White advantage fills upward; black advantage fills downward.")

    def set_thinking(self, thinking: bool, message: str = "Thinking...") -> None:
        self._thinking = bool(thinking)
        self._message = message
        self.update()

    def set_evaluation(self, score_cp_white: Optional[int], mate_white: Optional[int] = None, *, message: str = "") -> None:
        self._thinking = False
        self._score_cp_white = score_cp_white
        self._mate_white = mate_white
        self._message = message or self._format_score()
        self.update()

    def clear(self, message: str = "No eval") -> None:
        self._thinking = False
        self._score_cp_white = None
        self._mate_white = None
        self._message = message
        self.update()

    def _format_score(self) -> str:
        if self._mate_white is not None:
            side = "+" if self._mate_white > 0 else "-"
            return f"M{side}{abs(int(self._mate_white))}"
        if self._score_cp_white is None:
            return "0.0"
        pawns = float(self._score_cp_white) / 100.0
        return f"{pawns:+.1f}"

    def _white_fraction(self) -> float:
        if self._score_cp_white is None:
            return 0.5
        # Smoothly squash centipawns into [0,1]. Around +/-600 cp the bar is
        # nearly saturated but still not abrupt.
        val = math.tanh(float(self._score_cp_white) / 600.0)
        return max(0.0, min(1.0, 0.5 + 0.5 * val))

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        rect = self.rect().adjusted(4, 4, -4, -4)
        p.fillRect(rect, QColor(40, 40, 40))

        frac_white = self._white_fraction()
        white_h = int(round(rect.height() * frac_white))
        black_h = rect.height() - white_h
        black_rect = rect.adjusted(0, 0, 0, -white_h)
        white_rect = rect.adjusted(0, black_h, 0, 0)
        p.fillRect(black_rect, QColor(55, 55, 55))
        p.fillRect(white_rect, QColor(235, 235, 235))

        p.setPen(QPen(QColor(0, 0, 0), 1))
        p.drawRect(rect)
        mid_y = rect.top() + rect.height() / 2
        p.setPen(QPen(QColor(160, 160, 160), 1))
        p.drawLine(rect.left(), int(mid_y), rect.right(), int(mid_y))

        txt = "..." if self._thinking else self._message
        p.save()
        p.translate(self.width() / 2, self.height() / 2)
        p.rotate(-90)
        font = QFont()
        font.setPointSize(9)
        font.setBold(True)
        p.setFont(font)
        p.setPen(QColor(20, 20, 20) if frac_white > 0.62 else QColor(245, 245, 245))
        p.drawText(QRectF(-self.height()/2, -self.width()/2, self.height(), self.width()), Qt.AlignCenter, txt)
        p.restore()
        p.end()
