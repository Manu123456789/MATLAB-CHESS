"""Piece sprite loading. PNGs are named e.g. 'PW.png' (white pawn),
'KB.png' (black king) -- letter + color suffix. Cached at module level
because QPixmap construction reads the file every time."""
from __future__ import annotations

from pathlib import Path

import chess
from PySide6.QtGui import QPixmap


# Assets live next to the package (./assets/) when run from source, and
# bundled by PyInstaller they'll be reached via sys._MEIPASS -- handled
# by _assets_dir() so we don't fork the code path.
def _assets_dir() -> Path:
    import sys
    base = getattr(sys, '_MEIPASS', None)
    if base is not None:
        return Path(base) / 'assets'
    # __file__ is .../chessnet/gui/resources.py
    return Path(__file__).resolve().parent.parent.parent / 'assets'


_cache: dict[str, QPixmap] = {}


def piece_pixmap(piece: chess.Piece) -> QPixmap:
    """Return the sprite for `piece`, cached after first load."""
    key = piece.symbol()
    pix = _cache.get(key)
    if pix is not None:
        return pix
    letter = piece.symbol().upper()
    color_suffix = 'W' if piece.color == chess.WHITE else 'B'
    path = _assets_dir() / f'{letter}{color_suffix}.png'
    pix = QPixmap(str(path))
    if pix.isNull():
        # Defensive: missing sprite shouldn't crash the GUI. Returning
        # an empty pixmap renders as a blank square, which is obvious.
        pix = QPixmap()
    _cache[key] = pix
    return pix
