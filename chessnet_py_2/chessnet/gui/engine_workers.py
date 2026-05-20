"""QThread workers for Stockfish requests."""
from __future__ import annotations

import chess
from PySide6.QtCore import QObject, Signal, Slot

from ..engine import EngineAnalysis, EngineSettings, StockfishEngine


class EngineRequestWorker(QObject):
    finished = Signal(object, str)  # EngineAnalysis, request_id
    failed = Signal(str, str)       # error message, request_id

    def __init__(self, settings: EngineSettings, fen: str, request_id: str, *, mode: str = 'bestmove', timer_state=None):
        super().__init__()
        self.settings = EngineSettings.from_dict(settings.to_dict())
        self.fen = fen
        self.request_id = request_id
        self.mode = mode
        self.timer_state = timer_state.copy() if timer_state is not None and hasattr(timer_state, 'copy') else timer_state

    @Slot()
    def run(self) -> None:
        try:
            board = chess.Board(self.fen)
            with StockfishEngine(self.settings) as engine:
                if self.mode == 'bestmove':
                    result = engine.best_move(board, timer_state=self.timer_state)
                else:
                    result = engine.analyze(board, timer_state=self.timer_state)
            self.finished.emit(result, self.request_id)
        except Exception as e:
            self.failed.emit(str(e), self.request_id)
