"""Stockfish best-move list widget."""
from __future__ import annotations

import chess
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QWidget, QLabel, QVBoxLayout, QFrame

from ..engine import EngineAnalysis, PrincipalVariation


class BestMovesWidget(QWidget):
    """Right-side panel showing ranked Stockfish principal variations.

    The advantage bar gives a scalar evaluation. This widget complements it by
    showing the concrete candidate moves, ranked by Stockfish MultiPV for the
    side to move in the currently displayed/analyzed position.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        frame = QFrame()
        frame.setFrameShape(QFrame.StyledPanel)
        layout = QVBoxLayout(frame)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(4)

        self.title = QLabel("Stockfish Best Moves")
        self.title.setAlignment(Qt.AlignCenter)
        self.title.setStyleSheet("font-weight: bold;")
        self.body = QLabel("Analyze a position to show ranked moves.")
        self.body.setAlignment(Qt.AlignTop | Qt.AlignLeft)
        self.body.setWordWrap(True)
        self.body.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.body.setMinimumWidth(150)

        layout.addWidget(self.title)
        layout.addWidget(self.body)
        root.addWidget(frame)

    def clear(self, message: str = "Analyze a position to show ranked moves.") -> None:
        self.title.setText("Stockfish Best Moves")
        self.body.setText(message)

    def set_thinking(self) -> None:
        self.title.setText("Stockfish Best Moves")
        self.body.setText("Thinking…")

    def set_analysis(self, analysis: EngineAnalysis, board: chess.Board, *, max_moves: int = 5) -> None:
        side = "White" if board.turn == chess.WHITE else "Black"
        self.title.setText(f"{side} to move — best moves")
        pvs = list(analysis.pvs or [])[:max(1, int(max_moves))]
        if not pvs:
            if analysis.bestmove and analysis.bestmove != '(none)':
                pvs = [PrincipalVariation(multipv=1, first_move=analysis.bestmove, line=analysis.bestmove)]
            else:
                self.body.setText("No legal engine move returned.")
                return

        rows: list[str] = []
        for rank, pv in enumerate(pvs, start=1):
            first_san = self._first_move_san(board, pv.first_move)
            score = self._format_pv_score(pv, board.turn)
            continuation = self._line_san(board, pv.line, max_halfmoves=5)
            if continuation and continuation != first_san:
                rows.append(f"{rank}. {first_san}  {score}\n   {continuation}")
            else:
                rows.append(f"{rank}. {first_san}  {score}")
        self.body.setText("\n".join(rows))

    def _first_move_san(self, board: chess.Board, uci: str) -> str:
        try:
            move = chess.Move.from_uci(uci)
            if move not in board.legal_moves:
                return uci
            return board.san(move)
        except Exception:
            return uci or "—"

    def _line_san(self, board: chess.Board, line: str, *, max_halfmoves: int = 5) -> str:
        if not line:
            return ""
        b = board.copy(stack=False)
        san_moves: list[str] = []
        for raw in line.split()[:max_halfmoves]:
            try:
                move = chess.Move.from_uci(raw)
                if move not in b.legal_moves:
                    break
                san_moves.append(b.san(move))
                b.push(move)
            except Exception:
                break
        return " ".join(san_moves)

    def _format_pv_score(self, pv: PrincipalVariation, side_to_move: chess.Color) -> str:
        if pv.score_value is None or not pv.score_type:
            return ""
        # UCI scores are reported from the side-to-move perspective for a PV.
        # Present them from the side-to-move perspective here because the title
        # already says which side's candidate moves are being ranked.
        if pv.score_type == 'mate':
            sign = '+' if int(pv.score_value) > 0 else '-'
            return f"M{sign}{abs(int(pv.score_value))}"
        if pv.score_type == 'cp':
            return f"{int(pv.score_value) / 100.0:+.2f}"
        return ""
