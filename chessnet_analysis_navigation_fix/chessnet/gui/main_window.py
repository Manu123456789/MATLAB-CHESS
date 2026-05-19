"""
Main window. Supports two modes:

  * Local hot-seat -- no network, both players click on the same window.
  * Network        -- shared-file via NetGame, watchdog + fallback poll
                      for refresh, input lock when it is not our turn.

The two modes share the BoardView. Network-only differences are confined to
shared-file commit/refresh and local-only premove handling.
"""
from __future__ import annotations

from typing import Optional
import secrets

import chess
from PySide6.QtCore import Qt, QTimer, QThread
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QPushButton, QStatusBar, QMessageBox, QDialog,
)

from ..model import Game
from ..netgame import NetGame, StaleWriteError, WrongGameError
from ..serialize import GameSnapshot, TimerState, now_iso, result_for_timeout
from ..engine import EngineSettings, EngineAnalysis
from ..watcher import FileWatcher
from .board_view import BoardView
from .promotion_dialog import PromotionDialog
from .session_dialog import NewGameOptionsDialog
from .advantage_bar import AdvantageBar
from .engine_options_dialog import StockfishOptionsDialog
from .engine_workers import EngineRequestWorker
from .graveyard import CapturedPiecesWidget


# Fallback poll interval. Watchdog handles instant updates on supported
# filesystems; this catches SMB/NFS shares where events don't cross hosts.
FALLBACK_POLL_MS = 1000
CLOCK_TICK_MS = 250


def _color_code(color: chess.Color) -> str:
    return 'w' if color == chess.WHITE else 'b'


def _color_name(color_code: str) -> str:
    return 'White' if color_code == 'w' else 'Black'


class MainWindow(QMainWindow):

    def __init__(self,
                 game: Game,
                 *,
                 netgame: Optional[NetGame] = None,
                 orientation: chess.Color = chess.WHITE,
                 timer_state: Optional[TimerState] = None,
                 bot_color: Optional[chess.Color] = None,
                 engine_settings: Optional[EngineSettings] = None,
                 spectator: bool = False,
                 evaluation_enabled: bool = False):
        super().__init__()
        self.game = game
        self.netgame: Optional[NetGame] = netgame
        self.orientation = orientation
        self.is_network = netgame is not None
        self.spectator = bool(spectator)
        self.bot_color: Optional[chess.Color] = bot_color
        self.engine_settings = (EngineSettings.from_dict(engine_settings.to_dict())
                                if engine_settings is not None else None)
        self.evaluation_enabled = bool(evaluation_enabled and self.engine_settings is not None)
        self._bot_thinking = False
        self._bot_request_id = ''
        self._bot_request_fen = ''
        self._eval_request_id = ''
        self._eval_request_fen = ''
        self._eval_last_completed_fen = ''
        self._engine_threads: list[QThread] = []

        # Snapshot-level status is needed for timeout because python-chess does
        # not know about clock expiration. For normal chess states we defer to
        # Game.status().
        self.snapshot_status = netgame.last_seen.status if self.is_network else 'active'
        if self.is_network:
            self.timer_state = netgame.last_seen.timer.copy()
        else:
            self.timer_state = (timer_state.copy() if timer_state is not None
                                else TimerState.disabled())
        self._initial_timer_state = self.timer_state.copy()
        self._last_snapshot_updated_at = (netgame.last_seen.updated_at
                                          if self.is_network else '')
        self._game_over_notified = False
        self._replay_in_progress = False
        # Live review index for normal play. None means the board is showing
        # the current live position; an int means a historical position is
        # being painted read-only while the real game remains unchanged.
        self._view_index: int | None = None

        # Analysis mode owns a private board/line. It never writes to the
        # shared file and does not alter the finished real game.
        self._analysis_mode = False
        self._analysis_game: Game | None = None
        self._analysis_positions: list[str] = []
        self._analysis_index = 0

        if self.spectator:
            self.setWindowTitle("ChessNet -- Spectator + Stockfish")
        elif self.bot_color is not None:
            human = 'White' if self.bot_color == chess.BLACK else 'Black'
            self.setWindowTitle(f"ChessNet -- Play Stockfish ({human})")
        elif self.is_network:
            self.setWindowTitle(
                f"ChessNet -- Network ({'White' if netgame.my_color == 'w' else 'Black'})"
            )
        else:
            self.setWindowTitle("ChessNet -- Local Hot-Seat")

        # --- layout --------------------------------------------------------
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(10, 10, 10, 10)
        root.setSpacing(8)

        self.status_label = QLabel()
        self.status_label.setStyleSheet(
            "font-size: 18px; font-weight: bold; padding: 4px;"
        )
        root.addWidget(self.status_label)

        timer_row = QHBoxLayout()
        self.timer_white_label = QLabel("White --:--")
        self.timer_black_label = QLabel("Black --:--")
        for lbl in (self.timer_white_label, self.timer_black_label):
            lbl.setMinimumWidth(130)
            lbl.setStyleSheet("font-size: 14px; padding: 2px 6px;")
        timer_row.addStretch(1)
        timer_row.addWidget(self.timer_white_label)
        timer_row.addWidget(self.timer_black_label)
        timer_row.addStretch(1)
        root.addLayout(timer_row)

        self.board_view = BoardView(self.game, orientation=self.orientation)
        self.advantage_bar = AdvantageBar()
        self.advantage_bar.setVisible(self.evaluation_enabled)
        self.graveyard = CapturedPiecesWidget()
        board_row = QHBoxLayout()
        board_row.addStretch(1)
        board_row.addWidget(self.advantage_bar)
        board_row.addWidget(self.board_view, alignment=Qt.AlignHCenter)
        board_row.addWidget(self.graveyard)
        board_row.addStretch(1)
        root.addLayout(board_row)

        # Bottom action row
        row = QHBoxLayout()
        self.new_btn = QPushButton("New Game")
        self.new_btn.clicked.connect(self._on_new_game)
        row.addWidget(self.new_btn)

        self.flip_btn = QPushButton("Flip Board")
        self.flip_btn.clicked.connect(self._on_flip)
        row.addWidget(self.flip_btn)

        self.replay_btn = QPushButton("Replay Last Move")
        self.replay_btn.clicked.connect(self._on_replay_last_move)
        row.addWidget(self.replay_btn)

        self.back_btn = QPushButton("< Back")
        self.back_btn.clicked.connect(lambda: self._set_live_review_index(self._current_live_review_index() - 1))
        row.addWidget(self.back_btn)

        self.forward_btn = QPushButton("Forward >")
        self.forward_btn.clicked.connect(lambda: self._set_live_review_index(self._current_live_review_index() + 1))
        row.addWidget(self.forward_btn)

        # Undo only makes sense in local mode -- networked moves are
        # committed remotely the moment they're made.
        self.undo_btn = QPushButton("Undo")
        self.undo_btn.clicked.connect(self._on_undo)
        if self.is_network:
            self.undo_btn.setVisible(False)
        row.addWidget(self.undo_btn)

        self.clear_premoves_btn = QPushButton("Clear Premoves")
        self.clear_premoves_btn.clicked.connect(self._on_clear_premoves)
        self.clear_premoves_btn.setVisible(self.is_network)
        self.clear_premoves_btn.setEnabled(False)
        row.addWidget(self.clear_premoves_btn)

        self.pause_btn = QPushButton("Pause Clock")
        self.pause_btn.clicked.connect(self._on_pause_resume)
        row.addWidget(self.pause_btn)

        self.engine_options_btn = QPushButton("Engine Options")
        self.engine_options_btn.clicked.connect(self._on_engine_options)
        self.engine_options_btn.setVisible(self.engine_settings is not None)
        row.addWidget(self.engine_options_btn)

        self.analyze_btn = QPushButton("Analyze Position")
        self.analyze_btn.clicked.connect(lambda: self._schedule_engine_evaluation(force=True))
        self.analyze_btn.setVisible(self.evaluation_enabled)
        row.addWidget(self.analyze_btn)

        # Manual refresh is a safety valve in network mode -- watchdog
        # + poll should make it unnecessary, but the button is still
        # nice to have for the user.
        self.refresh_btn = QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self._on_manual_refresh)
        if not self.is_network:
            self.refresh_btn.setVisible(False)
        row.addWidget(self.refresh_btn)

        row.addStretch(1)
        root.addLayout(row)

        self.analysis_widget = QWidget()
        analysis_row = QHBoxLayout(self.analysis_widget)
        analysis_row.setContentsMargins(0, 0, 0, 0)
        self.analysis_label = QLabel("Analysis mode")
        self.analysis_first_btn = QPushButton("|<")
        self.analysis_prev_btn = QPushButton("<")
        self.analysis_next_btn = QPushButton(">")
        self.analysis_last_btn = QPushButton(">|")
        self.analysis_exit_btn = QPushButton("Exit Analysis")
        self.analysis_first_btn.clicked.connect(lambda: self._set_analysis_index(0))
        self.analysis_prev_btn.clicked.connect(lambda: self._set_analysis_index(self._analysis_index - 1))
        self.analysis_next_btn.clicked.connect(lambda: self._set_analysis_index(self._analysis_index + 1))
        self.analysis_last_btn.clicked.connect(lambda: self._set_analysis_index(len(self._analysis_positions) - 1))
        self.analysis_exit_btn.clicked.connect(self._exit_analysis_mode)
        analysis_row.addWidget(self.analysis_label, 1)
        analysis_row.addWidget(self.analysis_first_btn)
        analysis_row.addWidget(self.analysis_prev_btn)
        analysis_row.addWidget(self.analysis_next_btn)
        analysis_row.addWidget(self.analysis_last_btn)
        analysis_row.addWidget(self.analysis_exit_btn)
        self.analysis_widget.setVisible(False)
        root.addWidget(self.analysis_widget)

        self.setCentralWidget(central)
        self.setStatusBar(QStatusBar())

        # Wire board signals.
        self.board_view.move_made.connect(self._on_move_made)
        self.board_view.promotion_requested.connect(self._on_promotion_requested)
        self.board_view.premove_queued.connect(self._refresh_premove_ui)

        # --- timers ---------------------------------------------------------
        self._clock_timer = QTimer(self)
        self._clock_timer.setInterval(CLOCK_TICK_MS)
        self._clock_timer.timeout.connect(self._on_clock_tick)
        self._clock_timer.start()

        # --- network plumbing ---------------------------------------------
        self._watcher: Optional[FileWatcher] = None
        self._poll_timer: Optional[QTimer] = None
        # Guard against re-entrant refreshes (watchdog fires while we're
        # still applying a previous event).
        self._refresh_in_flight = False

        if self.is_network:
            assert self.netgame is not None
            self._watcher = FileWatcher(self.netgame.file_path, parent=self)
            self._watcher.file_changed.connect(
                self._on_file_changed, type=Qt.QueuedConnection
            )
            self._watcher.start()

            self._poll_timer = QTimer(self)
            self._poll_timer.setInterval(FALLBACK_POLL_MS)
            self._poll_timer.timeout.connect(self._on_poll_tick)
            self._poll_timer.start()

            if not self.spectator:
                self._mark_network_player_opened()
        else:
            self._maybe_start_local_clock()

        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self._refresh_premove_ui()
        self._refresh_graveyard()
        self._refresh_replay_button()
        self._refresh_history_nav_buttons()
        self._refresh_engine_buttons()
        self._schedule_engine_evaluation(force=True)
        QTimer.singleShot(0, self._schedule_bot_move_if_needed)

    # --- shutdown ----------------------------------------------------------

    def closeEvent(self, event) -> None:
        if self._clock_timer is not None:
            self._clock_timer.stop()
        if self._poll_timer is not None:
            self._poll_timer.stop()
        if self._watcher is not None:
            self._watcher.stop()
        for thread in list(self._engine_threads):
            try:
                thread.quit()
                thread.wait(200)
            except RuntimeError:
                pass
        super().closeEvent(event)

    # --- move handling -----------------------------------------------------

    def _on_move_made(self, san: str) -> None:
        """The board pushed a move on the active board.

        In normal play the active board is self.game and network mode writes it
        to the share. In analysis mode the active board is a private variation,
        so moves only extend the local analysis line."""
        if self._analysis_mode:
            self._on_analysis_move_made(san)
            return

        # A real move returns the live board to the current position.
        self._exit_live_review_mode()

        # Show in status bar regardless of mode.
        n_full = (len(self.game.history) + 1) // 2
        if self.game.turn == chess.BLACK:
            tag = f"{n_full}. {san}"
        else:
            tag = f"{n_full}... {san}"
        self.statusBar().showMessage(tag, 4000)

        mover = chess.BLACK if self.game.turn == chess.WHITE else chess.WHITE
        prev_timer = self.timer_state.copy()
        self._clock_after_completed_move(mover)

        if self.is_network:
            if not self._commit_move_to_network(prev_timer):
                return

        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self._refresh_graveyard()
        self._refresh_replay_button()
        self._refresh_history_nav_buttons()
        self._refresh_engine_buttons()
        self._schedule_engine_evaluation(force=True)
        self._notify_game_over_once()
        QTimer.singleShot(0, self._schedule_bot_move_if_needed)

    def _commit_move_to_network(self, prev_timer: TimerState) -> bool:
        """Push self.game's new state to the shared file. Handles the
        stale-write race by re-syncing if the opponent beat us."""
        assert self.netgame is not None
        try:
            snap = self.netgame.save(
                self.game,
                timer=self.timer_state,
                status=self._status_for_snapshot(),
                result=self._result_for_snapshot(),
            )
            self.snapshot_status = snap.status
            self._last_snapshot_updated_at = snap.updated_at
            return True
        except StaleWriteError:
            QMessageBox.warning(
                self, "Move not saved",
                "The shared file changed while you were moving. "
                "Reloading the latest state -- please try your move again."
            )
            self.timer_state = prev_timer
            self.game.pop()
            self.board_view.update()
            self._force_refresh()
            return False
        except WrongGameError as e:
            QMessageBox.critical(
                self, "Wrong game file",
                f"The shared file no longer belongs to this game:\n\n{e}\n\n"
                "Closing the game."
            )
            self.close()
            return False
        except OSError as e:
            QMessageBox.warning(
                self, "Save failed",
                f"Could not write the shared file:\n\n{e}\n\n"
                "Your move was rolled back. Refresh, then move again."
            )
            self.timer_state = prev_timer
            self.game.pop()
            self.board_view.update()
            self._apply_input_lock()
            self._refresh_timer_labels()
            self._refresh_status()
            return False

    def _on_promotion_requested(self, from_sq: int, to_sq: int) -> None:
        dlg = PromotionDialog(self.board_view.game.turn, parent=self)
        if dlg.exec() != QDialog.Accepted or dlg.choice is None:
            return
        self.board_view.commit_promotion(from_sq, to_sq, dlg.choice)

    def _refresh_graveyard(self) -> None:
        if not hasattr(self, 'graveyard'):
            return
        if self._analysis_mode and self._analysis_game is not None:
            self.graveyard.set_game(self._analysis_game)
            return
        if self._view_index is not None:
            fens = self._position_fens_for_current_game()
            idx = max(0, min(self._view_index, len(fens) - 1)) if fens else 0
            review_game = Game(
                board=chess.Board(fens[idx]) if fens else chess.Board(),
                history=self._history_prefix_for_position(idx),
                initial_fen=fens[0] if fens else chess.STARTING_FEN,
            )
            self.graveyard.set_game(review_game)
            return
        self.graveyard.set_game(self.game)

    # --- premoves ----------------------------------------------------------

    def _on_clear_premoves(self) -> None:
        self.board_view.clear_premoves()
        self.statusBar().showMessage("Premoves cleared.", 2500)

    def _refresh_premove_ui(self) -> None:
        n = len(self.board_view.premove_queue)
        self.clear_premoves_btn.setEnabled(n > 0)
        if n > 0:
            self.clear_premoves_btn.setText(f"Clear Premoves ({n})")
        else:
            self.clear_premoves_btn.setText("Clear Premoves")

    def _try_fire_premove(self) -> None:
        """After a network refresh gives us the turn, fire the oldest queued
        premove if it is legal in the new real position. Invalid premoves are
        discarded locally and never written to the shared file."""
        if not self.is_network or self.netgame is None:
            return
        if not self.netgame.my_turn:
            return
        if self._is_terminal_status(self._effective_status()) or self.timer_state.paused:
            return

        while self.board_view.premove_queue and self.netgame.my_turn:
            move = self.board_view.pop_next_premove()
            if move is None:
                return
            if move not in self.game.board.legal_moves:
                self.statusBar().showMessage(
                    f"Discarded illegal premove {move.uci()}.", 3000
                )
                continue
            self.game.push(move)
            self.board_view.update()
            self.statusBar().showMessage(
                f"Premove fired: {self.game.history[-1].san}", 4000
            )
            self._on_move_made(self.game.history[-1].san)
            return

    # --- replay / analysis -------------------------------------------------

    def _position_fens_for_current_game(self) -> list[str]:
        """Return initial + every after-move FEN for the real game."""
        if self.is_network and self.netgame is not None:
            fens = list(self.netgame.last_seen.position_history)
        else:
            fens = self.game.position_history()
        if not fens:
            fens = [chess.STARTING_FEN]
        # If a very old file has incomplete positionHistory, append the current
        # board so replay/analysis still has a correct final state.
        if fens[-1] != self.game.board.fen():
            fens = fens + [self.game.board.fen()]
        return fens

    def _move_history_for_current_game(self):
        """Return real-game MoveRecord history, preferring the loaded network snapshot."""
        if self.is_network and self.netgame is not None:
            return list(self.netgame.last_seen.history)
        return list(self.game.history)

    def _history_prefix_for_position(self, idx: int):
        return self._move_history_for_current_game()[:max(0, idx)]

    def _analysis_game_at_index(self, idx: int) -> Game:
        fens = self._analysis_positions or self._position_fens_for_current_game()
        idx = max(0, min(idx, len(fens) - 1))
        g = Game(board=chess.Board(fens[idx]),
                 history=self._history_prefix_for_position(idx),
                 initial_fen=fens[0])
        return g

    def _current_live_review_index(self) -> int:
        fens = self._position_fens_for_current_game()
        if self._view_index is None:
            return len(fens) - 1
        return max(0, min(self._view_index, len(fens) - 1))

    def _exit_live_review_mode(self) -> None:
        if self._view_index is None:
            return
        self._view_index = None
        self.board_view.set_display_board_override(None)

    def _set_live_review_index(self, idx: int) -> None:
        if self._analysis_mode:
            return
        fens = self._position_fens_for_current_game()
        if not fens:
            return
        idx = max(0, min(idx, len(fens) - 1))
        if idx >= len(fens) - 1:
            self._exit_live_review_mode()
        else:
            self._view_index = idx
            self.board_view.set_display_board_override(
                chess.Board(fens[idx]),
                history=self._history_prefix_for_position(idx),
            )
        self._apply_input_lock()
        self._refresh_status()
        self._refresh_graveyard()
        self._refresh_history_nav_buttons()
        self._refresh_replay_button()
        self._schedule_engine_evaluation(force=True)

    def _refresh_history_nav_buttons(self) -> None:
        enabled = (not self._analysis_mode) and (not self._replay_in_progress)
        fens = self._position_fens_for_current_game()
        idx = self._current_live_review_index() if fens else 0
        self.back_btn.setEnabled(enabled and idx > 0)
        self.forward_btn.setEnabled(enabled and bool(fens) and idx < len(fens) - 1)

    def _refresh_replay_button(self) -> None:
        if self._analysis_mode:
            self.replay_btn.setEnabled(self._analysis_index > 0 and not self._replay_in_progress)
        else:
            self.replay_btn.setEnabled(
                len(self._position_fens_for_current_game()) > 1 and not self._replay_in_progress and self._view_index is None
            )

    def _on_replay_last_move(self) -> None:
        """Briefly show the position before the last move, then restore."""
        if self._replay_in_progress:
            return

        if self._analysis_mode:
            if self._analysis_index <= 0:
                return
            before_fen = self._analysis_positions[self._analysis_index - 1]
            label = f"Replaying analysis move {self._analysis_index}."
        else:
            fens = self._position_fens_for_current_game()
            if len(fens) < 2:
                return
            before_fen = fens[-2]
            label = "Replaying last move."

        self._replay_in_progress = True
        self._apply_input_lock()
        self._refresh_replay_button()
        self.statusBar().showMessage(label, 1500)
        hist_prefix = self._history_prefix_for_position(max(0, self._analysis_index - 1)) if self._analysis_mode else self._history_prefix_for_position(max(0, len(self._position_fens_for_current_game()) - 2))
        self.board_view.set_display_board_override(chess.Board(before_fen), history=hist_prefix)
        QTimer.singleShot(650, self._finish_replay_last_move)

    def _finish_replay_last_move(self) -> None:
        self.board_view.set_display_board_override(None)
        self._replay_in_progress = False
        self._apply_input_lock()
        self._refresh_replay_button()
        self._refresh_history_nav_buttons()
        self.board_view.update()

    def _enter_analysis_mode(self) -> None:
        """Review the stored game timeline and allow local alternate lines."""
        self._exit_live_review_mode()
        self._analysis_positions = self._position_fens_for_current_game()
        self._analysis_index = len(self._analysis_positions) - 1
        self._analysis_mode = True
        self.board_view.clear_premoves()
        self.analysis_widget.setVisible(True)
        self._load_analysis_position(self._analysis_index)
        self.statusBar().showMessage(
            "Analysis mode: step backward, then make any legal alternate move.",
            5000,
        )

    def _exit_analysis_mode(self) -> None:
        if not self._analysis_mode:
            return
        self._analysis_mode = False
        self._analysis_game = None
        self._analysis_positions = []
        self._analysis_index = 0
        self.analysis_widget.setVisible(False)
        self.board_view.set_game(self.game)
        self._refresh_graveyard()
        self._apply_input_lock()
        self._refresh_status()
        self._refresh_graveyard()
        self._refresh_replay_button()

    def _load_analysis_position(self, idx: int) -> None:
        if not self._analysis_positions:
            return
        self._analysis_index = max(0, min(idx, len(self._analysis_positions) - 1))
        self._analysis_game = self._analysis_game_at_index(self._analysis_index)
        self.board_view.set_game(self._analysis_game)
        self._apply_input_lock()
        self._refresh_analysis_ui()
        self._refresh_status()
        self._refresh_graveyard()
        self._refresh_replay_button()
        self._schedule_engine_evaluation(force=True)

    def _set_analysis_index(self, idx: int) -> None:
        if not self._analysis_mode:
            return
        self._load_analysis_position(idx)

    def _refresh_analysis_ui(self) -> None:
        if not self._analysis_mode or not self._analysis_positions:
            return
        n = len(self._analysis_positions)
        self.analysis_label.setText(
            f"Analysis: position {self._analysis_index + 1} of {n}. "
            "Alternate moves are temporary; Back/Forward restores the saved game line."
        )
        self.analysis_first_btn.setEnabled(self._analysis_index > 0)
        self.analysis_prev_btn.setEnabled(self._analysis_index > 0)
        self.analysis_next_btn.setEnabled(self._analysis_index < n - 1)
        self.analysis_last_btn.setEnabled(self._analysis_index < n - 1)

    def _on_analysis_move_made(self, san: str) -> None:
        if self._analysis_game is None:
            return
        # Do not mutate the stored real-game timeline. The alternate line lives
        # only on self._analysis_game. Navigating to another stored position
        # discards the temporary variation and reloads from _analysis_positions.
        self.statusBar().showMessage(f"Analysis move: {san}", 4000)
        self._refresh_analysis_ui()
        self._refresh_status()
        self._refresh_graveyard()
        self._refresh_replay_button()


    # --- engine / Stockfish handling ---------------------------------------

    def _on_engine_options(self) -> None:
        if self.engine_settings is None:
            return
        dlg = StockfishOptionsDialog(self.engine_settings, require_path=True, parent=self)
        if dlg.exec() == QDialog.Accepted:
            self.engine_settings = dlg.settings()
            self.evaluation_enabled = True
            self.advantage_bar.setVisible(True)
            self._refresh_engine_buttons()
            self._schedule_engine_evaluation(force=True)
            QTimer.singleShot(0, self._schedule_bot_move_if_needed)

    def _refresh_engine_buttons(self) -> None:
        has_engine = self.engine_settings is not None
        self.engine_options_btn.setVisible(has_engine)
        self.engine_options_btn.setEnabled(has_engine and not self._bot_thinking)
        self.analyze_btn.setVisible(self.evaluation_enabled)
        self.analyze_btn.setEnabled(
            self.evaluation_enabled and self.engine_settings is not None and not self._eval_request_id
        )
        if hasattr(self, 'advantage_bar'):
            self.advantage_bar.setVisible(self.evaluation_enabled)

    def _engine_request(self, *, mode: str, board: chess.Board, request_id: str, timer_state: TimerState | None = None) -> None:
        if self.engine_settings is None:
            return
        thread = QThread(self)
        worker = EngineRequestWorker(
            self.engine_settings,
            board.fen(),
            request_id,
            mode=mode,
            timer_state=timer_state,
        )
        # Keep a Python reference; otherwise the QObject can be garbage
        # collected before QThread.started invokes run().
        thread._worker = worker  # type: ignore[attr-defined]
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        if mode == 'bestmove':
            worker.finished.connect(self._on_bot_engine_result)
            worker.failed.connect(self._on_bot_engine_failed)
        else:
            worker.finished.connect(self._on_engine_eval_result)
            worker.failed.connect(self._on_engine_eval_failed)
        worker.finished.connect(thread.quit)
        worker.failed.connect(thread.quit)
        worker.finished.connect(worker.deleteLater)
        worker.failed.connect(worker.deleteLater)
        thread.finished.connect(thread.deleteLater)
        thread.finished.connect(lambda th=thread: self._engine_threads.remove(th) if th in self._engine_threads else None)
        self._engine_threads.append(thread)
        thread.start()

    def _schedule_bot_move_if_needed(self) -> None:
        if self.bot_color is None or self.engine_settings is None:
            return
        if self._analysis_mode or self.spectator or self.is_network:
            return
        if self._bot_thinking or self._replay_in_progress:
            return
        if self.game.turn != self.bot_color:
            return
        if self._is_terminal_status(self._effective_status()) or self.timer_state.paused:
            return
        self._bot_thinking = True
        self._bot_request_id = secrets.token_hex(8)
        self._bot_request_fen = self.game.board.fen()
        self._apply_input_lock()
        self._refresh_status()
        self._refresh_engine_buttons()
        self.statusBar().showMessage("Stockfish is thinking...", 2500)
        self._engine_request(
            mode='bestmove',
            board=self.game.board.copy(stack=False),
            request_id=self._bot_request_id,
            timer_state=self.timer_state,
        )

    def _on_bot_engine_result(self, result: object, request_id: str) -> None:
        if request_id != self._bot_request_id:
            return
        self._bot_request_id = ''
        self._bot_thinking = False
        try:
            analysis = result if isinstance(result, EngineAnalysis) else None
            if self.game.board.fen() != self._bot_request_fen:
                self.statusBar().showMessage("Discarded stale Stockfish move after board changed.", 3000)
                return
            if analysis is None or not analysis.bestmove or analysis.bestmove == '(none)':
                self.statusBar().showMessage("Stockfish returned no legal move.", 4000)
                return
            move = chess.Move.from_uci(analysis.bestmove)
            if self.game.turn != self.bot_color or move not in self.game.board.legal_moves:
                self.statusBar().showMessage(f"Discarded illegal Stockfish move {analysis.bestmove}.", 4000)
                return
            self.game.push(move)
            self.board_view.update()
            self.statusBar().showMessage(f"Stockfish played {self.game.history[-1].san}.", 4000)
            self._on_move_made(self.game.history[-1].san)
        except Exception as e:
            QMessageBox.warning(self, "Stockfish move failed", str(e))
        finally:
            self._bot_request_fen = ''
            self._apply_input_lock()
            self._refresh_status()
            self._refresh_engine_buttons()

    def _on_bot_engine_failed(self, message: str, request_id: str) -> None:
        if request_id != self._bot_request_id:
            return
        self._bot_request_id = ''
        self._bot_request_fen = ''
        self._bot_thinking = False
        self._apply_input_lock()
        self._refresh_status()
        self._refresh_engine_buttons()
        QMessageBox.warning(self, "Stockfish error", f"Stockfish could not move:\n\n{message}")

    def _schedule_engine_evaluation(self, *, force: bool = False) -> None:
        if not self.evaluation_enabled or self.engine_settings is None:
            return
        if self._analysis_mode and self._analysis_game is None:
            return
        board = (self._analysis_game.board if self._analysis_mode and self._analysis_game is not None
                 else self.board_view.display_board_override if self._view_index is not None and self.board_view.display_board_override is not None
                 else self.game.board)
        fen = board.fen()
        if not force and (fen == self._eval_last_completed_fen or self._eval_request_id):
            return
        if self._eval_request_id:
            # Do not stack multiple Stockfish processes while one analysis is
            # still running. The finished/stale callback will schedule a fresh
            # evaluation if the board changed.
            return
        self._eval_request_id = secrets.token_hex(8)
        self._eval_request_fen = fen
        self.advantage_bar.set_thinking(True)
        self._refresh_engine_buttons()
        eval_settings = EngineSettings.for_analysis(self.engine_settings)
        original = self.engine_settings
        self.engine_settings = eval_settings
        try:
            self._engine_request(
                mode='analysis',
                board=board.copy(stack=False),
                request_id=self._eval_request_id,
                timer_state=self.timer_state,
            )
        finally:
            self.engine_settings = original

    def _on_engine_eval_result(self, result: object, request_id: str) -> None:
        if request_id != self._eval_request_id:
            return
        self._eval_request_id = ''
        analysis = result if isinstance(result, EngineAnalysis) else None
        if analysis is None:
            self.advantage_bar.clear("No eval")
            return
        current_board = (self._analysis_game.board if self._analysis_mode and self._analysis_game is not None
                         else self.board_view.display_board_override if self._view_index is not None and self.board_view.display_board_override is not None
                         else self.game.board)
        if current_board.fen() != self._eval_request_fen:
            self._refresh_engine_buttons()
            self._schedule_engine_evaluation(force=True)
            return
        self._eval_last_completed_fen = self._eval_request_fen
        label = self._format_engine_score(analysis)
        self.advantage_bar.set_evaluation(analysis.score_cp_white, analysis.mate_white, message=label)
        if analysis.bestmove and analysis.bestmove != '(none)':
            self.statusBar().showMessage(
                f"Stockfish eval {label}; best move {analysis.bestmove}.", 5000
            )
        self._refresh_engine_buttons()

    def _on_engine_eval_failed(self, message: str, request_id: str) -> None:
        if request_id != self._eval_request_id:
            return
        self._eval_request_id = ''
        self.advantage_bar.clear("Eval err")
        self.statusBar().showMessage(f"Stockfish evaluation failed: {message}", 5000)
        self._refresh_engine_buttons()

    def _format_engine_score(self, analysis: EngineAnalysis) -> str:
        if analysis.mate_white is not None:
            side = "+" if analysis.mate_white > 0 else "-"
            return f"M{side}{abs(int(analysis.mate_white))}"
        if analysis.score_cp_white is None:
            return "0.0"
        return f"{analysis.score_cp_white / 100.0:+.1f}"

    # --- network refresh ---------------------------------------------------

    def _on_file_changed(self) -> None:
        """Watchdog says the file moved. Pull the latest state."""
        self._refresh_from_file()

    def _on_poll_tick(self) -> None:
        """Fallback poller. Only does real work if mtime changed."""
        if self.netgame is None:
            return
        if not self.netgame.mtime_changed():
            return
        self._refresh_from_file()

    def _on_manual_refresh(self) -> None:
        self._force_refresh()

    def _force_refresh(self) -> None:
        """Refresh ignoring debounce. Used after a stale-write error."""
        if not self.is_network:
            return
        self._refresh_from_file(force=True)

    def _refresh_from_file(self, *, force: bool = False) -> None:
        """Reload the shared file and rebuild the board if the snapshot
        actually changed. Idempotent: safe to call from both watchdog
        and the poll timer for the same underlying write."""
        if self.netgame is None:
            return
        if self._refresh_in_flight and not force:
            return
        self._refresh_in_flight = True
        try:
            try:
                old_game_id = self.netgame.game_id
                snap = self.netgame.load(allow_rebind=True)
                new_session = (snap.game_id != old_game_id)
            except WrongGameError as e:
                QMessageBox.critical(
                    self, "Wrong game file",
                    f"The shared file no longer belongs to this game:\n\n{e}"
                )
                self.close()
                return
            except (OSError, ValueError) as e:
                # Transient read errors are normal during the opposing
                # writer's atomic rename. Suppress; the next event or
                # poll tick will retry.
                self.statusBar().showMessage(f"Refresh skipped: {e}", 2000)
                return

            same_board = (not new_session and len(self.game.history) == snap.half_move_count)
            same_metadata = (snap.updated_at == self._last_snapshot_updated_at
                             and snap.status == self.snapshot_status
                             and snap.timer.to_dict() == self.timer_state.to_dict())
            if same_board and same_metadata and not force and not new_session:
                return

            self._apply_snapshot(snap, board_updated=not same_board, new_session=new_session)
        finally:
            self._refresh_in_flight = False

    def _apply_snapshot(self, snap: GameSnapshot, *, board_updated: bool, new_session: bool = False) -> None:
        """Replace the in-memory real game with one rebuilt from `snap`."""
        if new_session:
            self._view_index = None
            self._analysis_mode = False
            self._analysis_game = None
            self._analysis_positions = []
            self._analysis_index = 0
            self.analysis_widget.setVisible(False)
            self.board_view.clear_premoves()
            self._game_over_notified = False

        new_game = snap.to_game()
        self.game = new_game
        self.snapshot_status = snap.status
        self.timer_state = snap.timer.copy()
        self._initial_timer_state = self.timer_state.copy()
        self._last_snapshot_updated_at = snap.updated_at

        if self.spectator:
            self.setWindowTitle("ChessNet -- Spectator + Stockfish")
        elif self.is_network and self.netgame is not None:
            self.setWindowTitle(
                f"ChessNet -- Network ({'White' if self.netgame.my_color == 'w' else 'Black'})"
            )
            if new_session:
                self.orientation = chess.WHITE if self.netgame.my_color == 'w' else chess.BLACK
                self.board_view.set_orientation(self.orientation)

        if not self._analysis_mode:
            if board_updated or new_session:
                self._view_index = None
            self.board_view.set_game(new_game)

        if (new_session and self.is_network and not self.spectator
                and self.timer_state.enabled and self.netgame is not None):
            self.timer_state.mark_opened(self.netgame.my_color)
            self._maybe_start_clock_if_ready()
            self._persist_metadata_snapshot(suppress_errors=True)
        else:
            self._maybe_start_network_clock_after_refresh(board_updated=board_updated)

        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self._refresh_graveyard()
        self._refresh_replay_button()
        self._refresh_history_nav_buttons()
        self._refresh_engine_buttons()
        self._schedule_engine_evaluation(force=True)
        if not self._analysis_mode:
            self._notify_game_over_once()
        if board_updated and not new_session and not self._analysis_mode:
            self._try_fire_premove()

    # --- clock handling ----------------------------------------------------

    def _maybe_start_local_clock(self) -> None:
        if not self.timer_state.enabled:
            return
        if self.timer_state.running or self.timer_state.paused or self.timer_state.expired_color:
            return
        self.timer_state.white_opened = True
        self.timer_state.black_opened = True
        self.timer_state.start(_color_code(self.game.turn))

    def _mark_network_player_opened(self) -> None:
        if self.netgame is None or not self.timer_state.enabled:
            return
        self.timer_state.mark_opened(self.netgame.my_color)
        self._maybe_start_clock_if_ready()
        self._persist_metadata_snapshot(suppress_errors=True)

    def _maybe_start_network_clock_after_refresh(self, *, board_updated: bool) -> None:
        if self.netgame is None or self.spectator or not self.timer_state.enabled:
            return
        # A joiner's first metadata write marks both sides opened. Whichever
        # client observes the ready state first arms the clock once.
        if board_updated or self.timer_state.both_players_opened():
            started = self._maybe_start_clock_if_ready()
            if started:
                self._persist_metadata_snapshot(suppress_errors=True)

    def _maybe_start_clock_if_ready(self) -> bool:
        if self.spectator or not self.timer_state.enabled:
            return False
        if self.timer_state.running or self.timer_state.paused or self.timer_state.expired_color:
            return False
        if self.is_network and not self.timer_state.both_players_opened():
            return False
        if self._is_terminal_status(self._effective_status()):
            return False
        self.timer_state.start(_color_code(self.game.turn))
        return True

    def _clock_after_completed_move(self, mover: chess.Color) -> None:
        if not self.timer_state.enabled:
            return
        if self._is_terminal_status(self.game.status()):
            self.timer_state.stop(now_iso())
            return
        # If the opponent has not opened a network game yet, do not burn time.
        # The active side is still handed off so the clock starts correctly once
        # both players are present.
        if self.is_network and not self.timer_state.both_players_opened():
            self.timer_state.active_color = _color_code(self.game.turn)
            self.timer_state.running = False
            self.timer_state.started_at = ''
            return
        self.timer_state.switch_after_move(
            _color_code(mover), _color_code(self.game.turn), now_iso()
        )
        if self.timer_state.expired_color:
            self.snapshot_status = 'timeout'

    def _on_clock_tick(self) -> None:
        if not self.timer_state.enabled:
            self._refresh_timer_labels()
            self._refresh_pause_button()
            return

        active = self.timer_state.active_color
        if (self.timer_state.running and not self.timer_state.paused
                and self.timer_state.remaining_for(active) <= 0):
            self.timer_state.apply_elapsed(now_iso())
            if not self.timer_state.expired_color:
                self.timer_state.expired_color = active
            self.snapshot_status = 'timeout'
            self._apply_input_lock()
            self._refresh_timer_labels()
            self._refresh_status()
            self._persist_metadata_snapshot(suppress_errors=True)
            self._notify_game_over_once()
            return

        self._refresh_timer_labels()
        self._refresh_pause_button()

    def _on_pause_resume(self) -> None:
        if not self.timer_state.enabled or self.timer_state.expired_color:
            return
        if self.timer_state.paused:
            self.timer_state.resume(now_iso())
            self.snapshot_status = self.game.status()
            msg = "Clock resumed."
        else:
            paused_by = self.netgame.my_color if self.netgame is not None else ''
            self.timer_state.pause(paused_by=paused_by, now=now_iso())
            msg = "Clock paused."
        self._persist_metadata_snapshot(suppress_errors=False)
        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self.statusBar().showMessage(msg, 2500)

    def _persist_metadata_snapshot(self, *, suppress_errors: bool) -> None:
        if self.netgame is None or self.spectator:
            return
        snap = GameSnapshot.from_game(
            self.game,
            base=self.netgame.last_seen,
            timer=self.timer_state,
            status=self._status_for_snapshot(),
            result=self._result_for_snapshot(),
        )
        try:
            saved = self.netgame.save_snapshot(snap)
            self.snapshot_status = saved.status
            self._last_snapshot_updated_at = saved.updated_at
        except StaleWriteError:
            self._force_refresh()
        except (WrongGameError, OSError) as e:
            if suppress_errors:
                self.statusBar().showMessage(f"Clock metadata not saved: {e}", 2500)
            else:
                QMessageBox.warning(self, "Clock update failed", str(e))

    def _refresh_timer_labels(self) -> None:
        if not self.timer_state.enabled:
            self.timer_white_label.setText("White --:--")
            self.timer_black_label.setText("Black --:--")
            self.timer_white_label.setStyleSheet("font-size: 14px; padding: 2px 6px;")
            self.timer_black_label.setStyleSheet("font-size: 14px; padding: 2px 6px;")
            return

        w = self.timer_state.remaining_for('w')
        b = self.timer_state.remaining_for('b')
        inc_w = self.timer_state.increment_for('w')
        inc_b = self.timer_state.increment_for('b')
        inc_w_txt = f" +{inc_w}" if inc_w > 0 else ""
        inc_b_txt = f" +{inc_b}" if inc_b > 0 else ""
        self.timer_white_label.setText(f"White {self._format_clock(w)}{inc_w_txt}")
        self.timer_black_label.setText(f"Black {self._format_clock(b)}{inc_b_txt}")

        base = "font-size: 14px; padding: 2px 6px;"
        active_style = base + " font-weight: bold; border: 1px solid #444;"
        expired_style = base + " font-weight: bold; color: #b00020;"
        self.timer_white_label.setStyleSheet(
            expired_style if self.timer_state.expired_color == 'w'
            else active_style if self.timer_state.running and self.timer_state.active_color == 'w'
            else base
        )
        self.timer_black_label.setStyleSheet(
            expired_style if self.timer_state.expired_color == 'b'
            else active_style if self.timer_state.running and self.timer_state.active_color == 'b'
            else base
        )
        self._refresh_pause_button()

    def _refresh_pause_button(self) -> None:
        self.pause_btn.setVisible(self.timer_state.enabled)
        self.pause_btn.setEnabled(self.timer_state.enabled and not self.timer_state.expired_color)
        self.pause_btn.setText("Resume Clock" if self.timer_state.paused else "Pause Clock")

    def _format_clock(self, seconds: float) -> str:
        total = max(0, int(round(seconds)))
        h = total // 3600
        m = (total % 3600) // 60
        s = total % 60
        if h > 0:
            return f"{h}:{m:02d}:{s:02d}"
        return f"{m}:{s:02d}"

    # --- view-state helpers ------------------------------------------------

    def _apply_input_lock(self) -> None:
        """Decide whether the board should accept clicks."""
        if self._analysis_mode:
            terminal = self._analysis_game.is_game_over() if self._analysis_game is not None else True
            self.board_view.input_locked = self._replay_in_progress or terminal
            self.board_view.set_premove_mode(False, chess.WHITE)
            return

        if self._view_index is not None:
            self.board_view.input_locked = True
            self.board_view.set_premove_mode(False, chess.WHITE)
            return

        status = self._effective_status()
        terminal_or_paused = (self._is_terminal_status(status)
                              or self.timer_state.paused
                              or self._replay_in_progress)
        if self.spectator:
            self.board_view.input_locked = True
            self.board_view.set_premove_mode(False, chess.WHITE)
            return
        if self.bot_color is not None:
            bot_turn = self.game.turn == self.bot_color
            self.board_view.input_locked = terminal_or_paused or bot_turn or self._bot_thinking
            self.board_view.set_premove_mode(False, chess.WHITE)
            return
        if not self.is_network:
            self.board_view.input_locked = terminal_or_paused
            self.board_view.set_premove_mode(False, chess.WHITE)
            return
        assert self.netgame is not None
        waiting = not self.netgame.my_turn
        self.board_view.input_locked = terminal_or_paused or waiting
        premove_ok = waiting and not terminal_or_paused and not self.timer_state.expired_color
        premove_color = chess.WHITE if self.netgame.my_color == 'w' else chess.BLACK
        self.board_view.set_premove_mode(premove_ok, premove_color)

    def _effective_status(self) -> str:
        if self.snapshot_status == 'timeout':
            return 'timeout'
        return self.game.status()

    def _status_for_snapshot(self) -> str:
        if self.timer_state.enabled and self.timer_state.expired_color:
            return 'timeout'
        return self.game.status()

    def _result_for_snapshot(self) -> Optional[str]:
        if self.timer_state.enabled and self.timer_state.expired_color:
            return result_for_timeout(self.timer_state.expired_color)
        return None

    def _is_terminal_status(self, status: str) -> bool:
        return status == 'timeout' or status == 'checkmate' or status == 'stalemate' or status.startswith('draw_')

    def _refresh_status(self) -> None:
        if self._analysis_mode:
            if self._analysis_game is not None:
                side = 'White' if self._analysis_game.turn == chess.WHITE else 'Black'
                suffix = ' Game over in this line.' if self._analysis_game.is_game_over() else f' {side} to move in this line.'
            else:
                suffix = ''
            self.status_label.setText(f"Analysis mode -- position {self._analysis_index + 1} of {max(1, len(self._analysis_positions))}.{suffix}")
            return

        if self._view_index is not None:
            fens = self._position_fens_for_current_game()
            n = len(fens)
            self.status_label.setText(
                f"Reviewing saved position {self._current_live_review_index() + 1} of {n}. "
                "Press Forward to return to the live game."
            )
            return

        status = self._effective_status()
        side = 'White' if self.game.turn == chess.WHITE else 'Black'

        if status == 'timeout':
            loser = _color_name(self.timer_state.expired_color)
            winner = _color_name('b' if self.timer_state.expired_color == 'w' else 'w')
            self.status_label.setText(f"{loser} flagged -- {winner} wins on time.")
            return

        if self.timer_state.enabled and self.timer_state.paused:
            if self.timer_state.paused_by:
                self.status_label.setText(f"Clock paused by {_color_name(self.timer_state.paused_by)}.")
            else:
                self.status_label.setText("Clock paused.")
            return

        if self.timer_state.enabled and self.is_network and not self.timer_state.both_players_opened():
            self.status_label.setText("Waiting for both players to open the game before starting the clock.")
            return

        # Terminal states.
        if status == 'checkmate':
            winner = 'Black' if self.game.turn == chess.WHITE else 'White'
            self.status_label.setText(f"Checkmate -- {winner} wins.")
            return
        if status == 'stalemate':
            self.status_label.setText("Stalemate. Draw.")
            return
        if status == 'draw_insufficient':
            self.status_label.setText("Draw -- insufficient material.")
            return
        if status == 'draw_repetition':
            self.status_label.setText("Draw -- fivefold repetition.")
            return
        if status == 'draw_75moves':
            self.status_label.setText("Draw -- 75-move rule.")
            return

        # Active or check.
        check_suffix = " -- check" if status == 'check' else ""

        if self.spectator:
            suffix = " Engine evaluating." if self._eval_request_id else ""
            self.status_label.setText(f"Spectating: {side} to move{check_suffix}.{suffix}")
            return

        if self.bot_color is not None:
            bot_name = 'White' if self.bot_color == chess.WHITE else 'Black'
            human_name = 'Black' if self.bot_color == chess.WHITE else 'White'
            if self._bot_thinking:
                self.status_label.setText(f"Stockfish ({bot_name}) is thinking...")
            elif self.game.turn == self.bot_color:
                self.status_label.setText(f"Waiting for Stockfish ({bot_name}){check_suffix}.")
            else:
                self.status_label.setText(f"Your move ({human_name}){check_suffix}.")
            return

        if self.is_network:
            assert self.netgame is not None
            if self.netgame.my_turn:
                self.status_label.setText(f"Your move ({side}){check_suffix}.")
            else:
                them = 'Black' if self.netgame.my_color == 'w' else 'White'
                queued = len(self.board_view.premove_queue)
                suffix = f" {queued} premove(s) queued." if queued else ""
                self.status_label.setText(f"Waiting for {them}{check_suffix}.{suffix}")
        else:
            self.status_label.setText(f"{side} to move{check_suffix}.")

    def _notify_game_over_once(self) -> None:
        if self._game_over_notified or self._analysis_mode:
            return
        if not self._is_terminal_status(self._effective_status()):
            return
        self._game_over_notified = True
        self._show_game_over_choices()

    def _show_game_over_choices(self) -> None:
        box = QMessageBox(self)
        box.setWindowTitle("Game over")
        box.setIcon(QMessageBox.Information)
        box.setText(self.status_label.text())
        box.setInformativeText("What would you like to do next?")
        new_btn = box.addButton("New Game", QMessageBox.AcceptRole)
        analyze_btn = box.addButton("Analyze Game", QMessageBox.ActionRole)
        close_btn = box.addButton("Close Game", QMessageBox.RejectRole)
        box.setDefaultButton(analyze_btn)
        box.exec()
        clicked = box.clickedButton()
        if clicked == new_btn:
            self._on_new_game(from_game_over=True)
        elif clicked == analyze_btn:
            self._enter_analysis_mode()
        elif clicked == close_btn:
            self.close()

    # --- buttons -----------------------------------------------------------

    def _on_new_game(self, checked: bool = False, *, from_game_over: bool = False) -> None:
        if self.spectator:
            QMessageBox.information(self, "Spectator mode", "Spectators cannot start a new shared game.")
            return

        if self._analysis_mode:
            self._exit_analysis_mode()

        if self.game.history and not from_game_over and not self._is_terminal_status(self._effective_status()):
            r = QMessageBox.question(
                self, "New Game",
                "Start a new game? The current game will be discarded for this session.",
                QMessageBox.Yes | QMessageBox.No, QMessageBox.No,
            )
            if r != QMessageBox.Yes:
                return

        dlg = NewGameOptionsDialog(network=self.is_network, parent=self)
        if dlg.exec() != QDialog.Accepted:
            return
        opts = dlg.options()
        if opts.cancelled:
            return

        if self.is_network:
            self._start_network_new_game(opts.color, opts.timer_enabled,
                                         opts.white_seconds, opts.black_seconds, opts.increment_seconds)
        else:
            self._start_local_new_game(opts.color, opts.timer_enabled,
                                       opts.white_seconds, opts.black_seconds, opts.increment_seconds)

    def _start_local_new_game(self, color: str, timer_enabled: bool, white_seconds: int, black_seconds: int, increment_seconds: int = 0) -> None:
        self.game = Game()
        self.snapshot_status = 'active'
        self.timer_state = TimerState.from_seconds(
            timer_enabled, white_seconds, black_seconds, increment_seconds=increment_seconds, local=True,
        )
        self._initial_timer_state = self.timer_state.copy()
        self._game_over_notified = False
        self._replay_in_progress = False
        self._view_index = None
        self.orientation = chess.WHITE if color == 'w' else chess.BLACK
        if self.bot_color is not None:
            # In Stockfish mode the restart color is the human color.
            self.bot_color = chess.BLACK if color == 'w' else chess.WHITE
        self.board_view.clear_premoves()
        self.board_view.set_game(self.game)
        self.board_view.set_orientation(self.orientation)
        self._maybe_start_local_clock()
        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self._refresh_graveyard()
        self._refresh_replay_button()
        self._refresh_history_nav_buttons()
        self._refresh_engine_buttons()
        self._schedule_engine_evaluation(force=True)
        self.statusBar().clearMessage()
        QTimer.singleShot(0, self._schedule_bot_move_if_needed)

    def _start_network_new_game(self, color: str, timer_enabled: bool, white_seconds: int, black_seconds: int, increment_seconds: int = 0) -> None:
        if self.netgame is None:
            return
        timer = TimerState.from_seconds(
            timer_enabled, white_seconds, black_seconds, increment_seconds=increment_seconds, opened_color=color,
        )
        snap = GameSnapshot.initial(color, timer=timer)
        try:
            self.netgame.start_new_game(snap, my_color=color)
        except OSError as e:
            QMessageBox.warning(
                self, "New game failed",
                f"Could not write the new game to the shared file:\n\n{e}"
            )
            return
        self._apply_snapshot(snap, board_updated=True, new_session=True)
        self.statusBar().showMessage("New networked game started in the same file.", 4000)

    def _on_flip(self) -> None:
        new_o = chess.BLACK if self.board_view.orientation == chess.WHITE else chess.WHITE
        self.board_view.set_orientation(new_o)

    def _on_undo(self) -> None:
        if self.is_network:
            return
        if not self.game.history:
            return
        self._exit_live_review_mode()
        self.game.pop()
        self.snapshot_status = 'active'
        # Undo is primarily for board correction; reset clock handoff to the
        # side now to move without restoring historical elapsed seconds.
        if self.timer_state.enabled and not self.timer_state.expired_color:
            self.timer_state.stop(now_iso())
            self.timer_state.start(_color_code(self.game.turn))
        self.board_view.clear_selection()
        self.board_view.update()
        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self._refresh_graveyard()
        self._refresh_replay_button()
