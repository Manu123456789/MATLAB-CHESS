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

import chess
from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QPushButton, QStatusBar, QMessageBox, QDialog,
)

from ..model import Game
from ..netgame import NetGame, StaleWriteError, WrongGameError
from ..serialize import GameSnapshot, TimerState, now_iso, result_for_timeout
from ..watcher import FileWatcher
from .board_view import BoardView
from .promotion_dialog import PromotionDialog
from .session_dialog import NewGameOptionsDialog


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
                 timer_state: Optional[TimerState] = None):
        super().__init__()
        self.game = game
        self.netgame: Optional[NetGame] = netgame
        self.orientation = orientation
        self.is_network = netgame is not None

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

        # Analysis mode owns a private board/line. It never writes to the
        # shared file and does not alter the finished real game.
        self._analysis_mode = False
        self._analysis_game: Game | None = None
        self._analysis_positions: list[str] = []
        self._analysis_index = 0

        if self.is_network:
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
        root.addWidget(self.board_view, alignment=Qt.AlignHCenter)

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

            self._mark_network_player_opened()
        else:
            self._maybe_start_local_clock()

        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self._refresh_premove_ui()
        self._refresh_replay_button()

    # --- shutdown ----------------------------------------------------------

    def closeEvent(self, event) -> None:
        if self._clock_timer is not None:
            self._clock_timer.stop()
        if self._poll_timer is not None:
            self._poll_timer.stop()
        if self._watcher is not None:
            self._watcher.stop()
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
        self._refresh_replay_button()
        self._notify_game_over_once()

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

    def _refresh_replay_button(self) -> None:
        if self._analysis_mode:
            self.replay_btn.setEnabled(self._analysis_index > 0 and not self._replay_in_progress)
        else:
            self.replay_btn.setEnabled(
                len(self._position_fens_for_current_game()) > 1 and not self._replay_in_progress
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
        self.board_view.set_display_board_override(chess.Board(before_fen))
        QTimer.singleShot(650, self._finish_replay_last_move)

    def _finish_replay_last_move(self) -> None:
        self.board_view.set_display_board_override(None)
        self._replay_in_progress = False
        self._apply_input_lock()
        self._refresh_replay_button()
        self.board_view.update()

    def _enter_analysis_mode(self) -> None:
        """Review the stored game timeline and allow local alternate lines."""
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
        self._apply_input_lock()
        self._refresh_status()
        self._refresh_replay_button()

    def _load_analysis_position(self, idx: int) -> None:
        if not self._analysis_positions:
            return
        self._analysis_index = max(0, min(idx, len(self._analysis_positions) - 1))
        fen = self._analysis_positions[self._analysis_index]
        self._analysis_game = Game(board=chess.Board(fen), history=[], initial_fen=fen)
        self.board_view.set_game(self._analysis_game)
        self._apply_input_lock()
        self._refresh_analysis_ui()
        self._refresh_status()
        self._refresh_replay_button()

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
            "Navigate history or play an alternate move."
        )
        self.analysis_first_btn.setEnabled(self._analysis_index > 0)
        self.analysis_prev_btn.setEnabled(self._analysis_index > 0)
        self.analysis_next_btn.setEnabled(self._analysis_index < n - 1)
        self.analysis_last_btn.setEnabled(self._analysis_index < n - 1)

    def _on_analysis_move_made(self, san: str) -> None:
        if self._analysis_game is None:
            return
        # A variation replaces everything after the reviewed position.
        self._analysis_positions = self._analysis_positions[:self._analysis_index + 1]
        self._analysis_positions.append(self._analysis_game.board.fen())
        self._analysis_index += 1
        self.statusBar().showMessage(f"Analysis move: {san}", 4000)
        self._refresh_analysis_ui()
        self._refresh_status()
        self._refresh_replay_button()

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

        if self.is_network and self.netgame is not None:
            self.setWindowTitle(
                f"ChessNet -- Network ({'White' if self.netgame.my_color == 'w' else 'Black'})"
            )
            if new_session:
                self.orientation = chess.WHITE if self.netgame.my_color == 'w' else chess.BLACK
                self.board_view.set_orientation(self.orientation)

        if not self._analysis_mode:
            self.board_view.set_game(new_game)

        if new_session and self.is_network and self.timer_state.enabled and self.netgame is not None:
            self.timer_state.mark_opened(self.netgame.my_color)
            self._maybe_start_clock_if_ready()
            self._persist_metadata_snapshot(suppress_errors=True)
        else:
            self._maybe_start_network_clock_after_refresh(board_updated=board_updated)

        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self._refresh_replay_button()
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
        if self.netgame is None or not self.timer_state.enabled:
            return
        # A joiner's first metadata write marks both sides opened. Whichever
        # client observes the ready state first arms the clock once.
        if board_updated or self.timer_state.both_players_opened():
            started = self._maybe_start_clock_if_ready()
            if started:
                self._persist_metadata_snapshot(suppress_errors=True)

    def _maybe_start_clock_if_ready(self) -> bool:
        if not self.timer_state.enabled:
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
        if self.netgame is None:
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
        self.timer_white_label.setText(f"White {self._format_clock(w)}")
        self.timer_black_label.setText(f"Black {self._format_clock(b)}")

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

        status = self._effective_status()
        terminal_or_paused = (self._is_terminal_status(status)
                              or self.timer_state.paused
                              or self._replay_in_progress)
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
                                         opts.white_seconds, opts.black_seconds)
        else:
            self._start_local_new_game(opts.color, opts.timer_enabled,
                                       opts.white_seconds, opts.black_seconds)

    def _start_local_new_game(self, color: str, timer_enabled: bool, white_seconds: int, black_seconds: int) -> None:
        self.game = Game()
        self.snapshot_status = 'active'
        self.timer_state = TimerState.from_seconds(
            timer_enabled, white_seconds, black_seconds, local=True,
        )
        self._initial_timer_state = self.timer_state.copy()
        self._game_over_notified = False
        self._replay_in_progress = False
        self.orientation = chess.WHITE if color == 'w' else chess.BLACK
        self.board_view.clear_premoves()
        self.board_view.set_game(self.game)
        self.board_view.set_orientation(self.orientation)
        self._maybe_start_local_clock()
        self._apply_input_lock()
        self._refresh_timer_labels()
        self._refresh_status()
        self._refresh_replay_button()
        self.statusBar().clearMessage()

    def _start_network_new_game(self, color: str, timer_enabled: bool, white_seconds: int, black_seconds: int) -> None:
        if self.netgame is None:
            return
        timer = TimerState.from_seconds(
            timer_enabled, white_seconds, black_seconds, opened_color=color,
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
        self._refresh_replay_button()
