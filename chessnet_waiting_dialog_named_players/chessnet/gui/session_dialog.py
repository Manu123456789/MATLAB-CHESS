"""
Session dialog: the first thing the user sees. Picks the play mode,
shared file, host color, and optional per-side chess clock settings.

Output is a SessionChoice dataclass consumed by main.py to wire up
either local-mode or network-mode play.
"""
from __future__ import annotations

import os
import re
import secrets
from datetime import datetime
from dataclasses import dataclass, field

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QFormLayout, QLabel, QComboBox,
    QLineEdit, QPushButton, QFileDialog, QMessageBox, QDialogButtonBox,
    QCheckBox, QSpinBox,
)

from ..engine import EngineSettings, load_saved_engine_settings
from .engine_options_dialog import StockfishOptionsDialog


MODE_LOCAL = 'local'
MODE_HOST = 'host'
MODE_JOIN = 'join'
MODE_BOT = 'bot'
MODE_SPECTATE = 'spectate'


@dataclass
class SessionChoice:
    """Result of the session dialog. `cancelled=True` means the user
    closed the dialog without committing -- caller should exit."""
    cancelled: bool = True
    mode: str = MODE_LOCAL
    color: str = 'w'              # 'w', 'b', or 'random' for host setup
    file_path: str = ''           # host uses generated file path; join/spectate use selected file
    white_player: str = 'White'   # host/join player's own display name
    black_player: str = 'Black'   # retained for compatibility
    timer_enabled: bool = False   # local/host only; join reads file setting
    white_seconds: int = 600
    black_seconds: int = 600
    increment_seconds: int = 0
    engine_settings: EngineSettings = field(default_factory=EngineSettings.defaults)


class SessionDialog(QDialog):

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("New Chess Game")
        self.setModal(True)
        self.setMinimumWidth(520)
        self._choice = SessionChoice()

        root = QVBoxLayout(self)
        root.setContentsMargins(16, 16, 16, 12)
        root.setSpacing(10)

        header = QLabel("How do you want to play?")
        f = header.font(); f.setPointSize(14); f.setBold(True)
        header.setFont(f)
        root.addWidget(header)

        form = QFormLayout()
        form.setLabelAlignment(Qt.AlignRight)
        form.setFormAlignment(Qt.AlignLeft)
        form.setHorizontalSpacing(10)
        form.setVerticalSpacing(8)

        # Mode picker
        self.mode_combo = QComboBox()
        self.mode_combo.addItem("Local (two players, one machine)", MODE_LOCAL)
        self.mode_combo.addItem("Host a new networked game",        MODE_HOST)
        self.mode_combo.addItem("Join an existing networked game",  MODE_JOIN)
        self.mode_combo.addItem("Play against Stockfish",           MODE_BOT)
        self.mode_combo.addItem("Spectate game with Stockfish eval", MODE_SPECTATE)
        self.mode_combo.currentIndexChanged.connect(self._on_mode_changed)
        form.addRow("Mode:", self.mode_combo)

        # Color picker. Host can choose a fixed color or random; join mode
        # automatically takes the opposite of the host color saved in the file.
        self.color_combo = QComboBox()
        self.color_combo.addItem("White", 'w')
        self.color_combo.addItem("Black", 'b')
        self.color_combo.addItem("Random", 'random')
        self.color_label = QLabel("Your color:")
        form.addRow(self.color_label, self.color_combo)

        # Shared file/folder path with Browse button. Host mode asks for a
        # directory and auto-generates the JSON game file name from the players
        # and current timestamp. Join/spectate still choose an existing JSON file.
        path_row = QHBoxLayout()
        self.path_edit = QLineEdit()
        self.path_edit.setPlaceholderText(r"e.g. \\share\chess")
        self.browse_btn = QPushButton("Browse...")
        self.browse_btn.clicked.connect(self._on_browse)
        path_row.addWidget(self.path_edit, 1)
        path_row.addWidget(self.browse_btn)
        self.path_label = QLabel("Shared game folder:")
        form.addRow(self.path_label, path_row)

        # Network setup now asks each person only for their own name.
        # The final White-vs-Black filename is created after the joiner arrives,
        # because random color mode is not resolved into names until both names
        # are known.
        self.white_player_edit = QLineEdit("Player")
        self.white_player_edit.setPlaceholderText("Your display name")
        self.white_player_label = QLabel("Your name:")
        form.addRow(self.white_player_label, self.white_player_edit)

        self.black_player_edit = QLineEdit("")
        self.black_player_edit.setPlaceholderText("Opponent player name")
        self.black_player_label = QLabel("Opponent:")
        form.addRow(self.black_player_label, self.black_player_edit)

        # Stockfish executable path + detailed options. The compact path row
        # keeps startup fast; the Options dialog exposes ELO/depth/hash/etc.
        self.engine_settings = load_saved_engine_settings()
        engine_row = QHBoxLayout()
        self.engine_path_edit = QLineEdit(self.engine_settings.engine_path)
        self.engine_path_edit.setPlaceholderText("Path to stockfish executable")
        self.engine_browse_btn = QPushButton("Browse...")
        self.engine_browse_btn.clicked.connect(self._on_browse_engine)
        self.engine_options_btn = QPushButton("Options...")
        self.engine_options_btn.clicked.connect(self._on_engine_options)
        engine_row.addWidget(self.engine_path_edit, 1)
        engine_row.addWidget(self.engine_browse_btn)
        engine_row.addWidget(self.engine_options_btn)
        form.addRow("Stockfish:", engine_row)

        # Timer controls. Seconds are used instead of minutes so uneven
        # games like White=30 seconds, Black=2 minutes are directly expressible.
        self.timer_check = QCheckBox("Enable chess clock")
        self.timer_check.toggled.connect(self._on_timer_toggled)
        form.addRow("Clock:", self.timer_check)

        self.white_sec_spin = QSpinBox()
        self.white_sec_spin.setRange(1, 24 * 60 * 60)
        self.white_sec_spin.setSingleStep(30)
        self.white_sec_spin.setValue(600)
        self.white_sec_spin.setSuffix(" sec")
        form.addRow("White time:", self.white_sec_spin)

        self.black_sec_spin = QSpinBox()
        self.black_sec_spin.setRange(1, 24 * 60 * 60)
        self.black_sec_spin.setSingleStep(30)
        self.black_sec_spin.setValue(600)
        self.black_sec_spin.setSuffix(" sec")
        form.addRow("Black time:", self.black_sec_spin)

        self.increment_check = QCheckBox("FIDE-style increment after each move")
        self.increment_check.setToolTip("Adds the increment to the player who just completed a legal move.")
        self.increment_check.toggled.connect(lambda _checked: self._on_timer_toggled(self.timer_check.isChecked()))
        form.addRow("Increment mode:", self.increment_check)

        self.increment_sec_spin = QSpinBox()
        self.increment_sec_spin.setRange(0, 60 * 60)
        self.increment_sec_spin.setSingleStep(1)
        self.increment_sec_spin.setValue(30)
        self.increment_sec_spin.setSuffix(" sec/move")
        form.addRow("Increment:", self.increment_sec_spin)

        root.addLayout(form)

        # Help text -- updates with the mode
        self.help_label = QLabel()
        self.help_label.setWordWrap(True)
        self.help_label.setStyleSheet("color: #555; font-size: 11px; padding: 4px;")
        root.addWidget(self.help_label)

        # OK / Cancel
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Ok).setText("Start")
        buttons.accepted.connect(self._on_accept)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

        # Apply initial mode-dependent enables.
        self._on_mode_changed(0)
        self._on_timer_toggled(False)

    # --- public ------------------------------------------------------------

    def choice(self) -> SessionChoice:
        return self._choice

    # --- handlers ----------------------------------------------------------

    def _on_mode_changed(self, _idx: int) -> None:
        mode = self.mode_combo.currentData()
        timer_allowed = mode in (MODE_LOCAL, MODE_HOST, MODE_BOT)
        file_allowed = mode in (MODE_HOST, MODE_JOIN, MODE_SPECTATE)
        engine_allowed = mode in (MODE_BOT, MODE_SPECTATE)

        self.path_edit.setEnabled(file_allowed)
        self.browse_btn.setEnabled(file_allowed)
        own_name_allowed = mode in (MODE_HOST, MODE_JOIN)
        self.white_player_label.setVisible(own_name_allowed)
        self.white_player_edit.setVisible(own_name_allowed)
        self.black_player_label.setVisible(False)
        self.black_player_edit.setVisible(False)
        self.engine_path_edit.setEnabled(engine_allowed)
        self.engine_browse_btn.setEnabled(engine_allowed)
        self.engine_options_btn.setEnabled(engine_allowed)

        if mode == MODE_HOST:
            self.path_label.setText("Shared game folder:")
            self.path_edit.setPlaceholderText(r"e.g. \\share\chess")
        else:
            self.path_label.setText("Shared game file:")
            self.path_edit.setPlaceholderText(r"e.g. \\share\chess\game.json")

        if mode == MODE_LOCAL:
            self.color_label.setText("Your color:")
            self.color_combo.setEnabled(False)
            self._set_color_options(allow_random=False)
            self.help_label.setText(
                "Two players share one screen. White moves first. "
                "If the chess clock is enabled, each side may have a different time."
            )
        elif mode == MODE_HOST:
            self.color_label.setText("Host color:")
            self._set_color_options(allow_random=True)
            self.color_combo.setEnabled(True)
            self.help_label.setText(
                "Creates a waiting game in the selected shared folder. Enter only "
                "your own name; after the opponent joins, ChessNet creates the "
                "final White-vs-Black file name automatically."
            )
        elif mode == MODE_JOIN:
            self.color_label.setText("Your color:")
            self._set_color_options(allow_random=False)
            self.color_combo.setEnabled(False)
            self.help_label.setText(
                "Opens a waiting or active game file. For a waiting game, enter "
                "your name and ChessNet automatically assigns you the opposite "
                "color from the host."
            )
        elif mode == MODE_BOT:
            self.color_label.setText("Your color:")
            self._set_color_options(allow_random=False)
            self.color_combo.setEnabled(True)
            self.help_label.setText(
                "Play locally against Stockfish. Choose your color, optional clock "
                "settings, the Stockfish executable, and engine strength/search options."
            )
        else:  # MODE_SPECTATE
            self.color_label.setText("Your color:")
            self._set_color_options(allow_random=False)
            self.color_combo.setEnabled(False)
            self.help_label.setText(
                "Open an existing shared game read-only. The board stays locked and "
                "Stockfish evaluates every refreshed position with the advantage bar."
            )
        self.timer_check.setEnabled(timer_allowed)
        if not timer_allowed:
            self.timer_check.setChecked(False)
        self._on_timer_toggled(self.timer_check.isChecked() and timer_allowed)


    def _set_color_options(self, *, allow_random: bool) -> None:
        """Keep one shared color combo but expose Random only for hosting.

        Join mode intentionally does not ask for a color: it reads the host
        color from the shared file and takes the opposite side so the two
        clients cannot accidentally choose the same color.
        """
        current = self.color_combo.currentData()
        self.color_combo.blockSignals(True)
        self.color_combo.clear()
        self.color_combo.addItem("White", 'w')
        self.color_combo.addItem("Black", 'b')
        if allow_random:
            self.color_combo.addItem("Random", 'random')
        idx = self.color_combo.findData(current)
        if idx < 0:
            idx = 0
        self.color_combo.setCurrentIndex(idx)
        self.color_combo.blockSignals(False)

    def _on_timer_toggled(self, checked: bool) -> None:
        enabled = checked and self.timer_check.isEnabled()
        self.white_sec_spin.setEnabled(enabled)
        self.black_sec_spin.setEnabled(enabled)
        self.increment_check.setEnabled(enabled)
        self.increment_sec_spin.setEnabled(enabled and self.increment_check.isChecked())

    def _on_browse(self) -> None:
        mode = self.mode_combo.currentData()
        if mode == MODE_HOST:
            path = QFileDialog.getExistingDirectory(
                self, "Choose shared game folder", self.path_edit.text() or ""
            )
        else:
            path, _ = QFileDialog.getOpenFileName(
                self, "Open existing game file",
                self.path_edit.text() or "",
                "JSON files (*.json);;All files (*)",
            )
        if path:
            self.path_edit.setText(path)


    def _on_browse_engine(self) -> None:
        filt = ("Stockfish executable (stockfish*.exe *.exe);;All files (*)"
                if os.name == 'nt' else
                "Stockfish executable (stockfish* *);;All files (*)")
        path, _ = QFileDialog.getOpenFileName(
            self, "Select Stockfish executable", self.engine_path_edit.text() or "", filt
        )
        if path:
            self.engine_path_edit.setText(path)
            self.engine_settings.engine_path = path

    def _on_engine_options(self) -> None:
        self.engine_settings.engine_path = self.engine_path_edit.text().strip()
        dlg = StockfishOptionsDialog(self.engine_settings, require_path=True, parent=self)
        if dlg.exec() == QDialog.Accepted:
            self.engine_settings = dlg.settings()
            self.engine_path_edit.setText(self.engine_settings.engine_path)

    def _on_accept(self) -> None:
        mode = self.mode_combo.currentData()
        color = self.color_combo.currentData()
        if mode == MODE_JOIN:
            # Joiners do not choose manually. They automatically take the
            # color opposite the host color saved in the shared game file.
            color = ''
        path = self.path_edit.text().strip()
        white_player = self.white_player_edit.text().strip() or "Player"
        black_player = self.black_player_edit.text().strip() or "Opponent"

        if mode in (MODE_HOST, MODE_JOIN, MODE_SPECTATE):
            if not path:
                QMessageBox.warning(
                    self, "Missing path",
                    "Please provide a shared game folder." if mode == MODE_HOST
                    else "Please provide a shared game file path."
                )
                return
            if mode == MODE_HOST:
                if not os.path.isdir(path):
                    QMessageBox.warning(
                        self, "Folder not found",
                        f"The folder does not exist:\n{path}"
                    )
                    return
                path = self._build_host_waiting_file_path(path, white_player)
            elif not os.path.exists(path):
                QMessageBox.warning(
                    self, "File not found",
                    f"The file does not exist:\n{path}\n\n"
                    "Ask the host to create it first."
                )
                return

        if mode in (MODE_BOT, MODE_SPECTATE):
            self.engine_settings.engine_path = self.engine_path_edit.text().strip()
            if not self.engine_settings.engine_path:
                QMessageBox.warning(self, "Missing Stockfish path", "Please choose a Stockfish executable.")
                return
            if not os.path.exists(self.engine_settings.engine_path):
                QMessageBox.warning(
                    self, "Stockfish not found",
                    f"The executable does not exist:\n{self.engine_settings.engine_path}"
                )
                return

        timer_enabled = bool(self.timer_check.isChecked()) if mode in (MODE_LOCAL, MODE_HOST, MODE_BOT) else False
        self._choice = SessionChoice(
            cancelled=False,
            mode=mode,
            color=color,
            file_path=path,
            white_player=white_player,
            black_player=black_player,
            timer_enabled=timer_enabled,
            white_seconds=int(self.white_sec_spin.value()),
            black_seconds=int(self.black_sec_spin.value()),
            increment_seconds=(int(self.increment_sec_spin.value()) if timer_enabled and self.increment_check.isChecked() else 0),
            engine_settings=self.engine_settings.normalized(),
        )
        self.accept()


    @staticmethod
    def _sanitize_player_name(name: str) -> str:
        cleaned = re.sub(r'\s+', '_', name.strip())
        cleaned = re.sub(r'[^A-Za-z0-9_.-]+', '', cleaned)
        cleaned = cleaned.strip('._-')
        return cleaned or 'Player'

    def _build_host_waiting_file_path(self, directory: str, host_player: str) -> str:
        now = datetime.now()
        hour_12 = now.hour % 12 or 12
        stamp = f"{hour_12}_{now.minute:02d}_{now:%m%d%y}"
        host = self._sanitize_player_name(host_player)
        filename = f"{host}_waiting_for_opponent_{stamp}.json"
        path = os.path.join(directory, filename)
        if not os.path.exists(path):
            return path
        for idx in range(2, 1000):
            candidate = os.path.join(directory, f"{host}_waiting_for_opponent_{stamp}_{idx}.json")
            if not os.path.exists(candidate):
                return candidate
        return path


@dataclass
class NewGameOptions:
    """Options for restarting the current session without asking for a file."""
    cancelled: bool = True
    color: str = 'w'
    timer_enabled: bool = False
    white_seconds: int = 600
    black_seconds: int = 600
    increment_seconds: int = 0
    engine_settings: EngineSettings = field(default_factory=EngineSettings.defaults)


class NewGameOptionsDialog(QDialog):
    """Small restart dialog used from an existing game window.

    Network mode reuses the current shared-file path; local mode reuses the
    current window. The user only chooses color/orientation and clock settings.
    """

    def __init__(self, *, network: bool, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Start New Game")
        self.setModal(True)
        self.setMinimumWidth(420)
        self._options = NewGameOptions()
        self._network = bool(network)

        root = QVBoxLayout(self)
        root.setContentsMargins(16, 16, 16, 12)
        root.setSpacing(10)

        header = QLabel("Start a new game")
        f = header.font(); f.setPointSize(14); f.setBold(True)
        header.setFont(f)
        root.addWidget(header)

        form = QFormLayout()
        form.setLabelAlignment(Qt.AlignRight)
        form.setHorizontalSpacing(10)
        form.setVerticalSpacing(8)

        self.color_combo = QComboBox()
        self.color_combo.addItem("White", 'w')
        self.color_combo.addItem("Black", 'b')
        label = "Your color:" if self._network else "Board starts from:"
        form.addRow(label, self.color_combo)

        self.timer_check = QCheckBox("Enable chess clock")
        self.timer_check.toggled.connect(self._on_timer_toggled)
        form.addRow("Clock:", self.timer_check)

        self.white_sec_spin = QSpinBox()
        self.white_sec_spin.setRange(1, 24 * 60 * 60)
        self.white_sec_spin.setSingleStep(30)
        self.white_sec_spin.setValue(600)
        self.white_sec_spin.setSuffix(" sec")
        form.addRow("White time:", self.white_sec_spin)

        self.black_sec_spin = QSpinBox()
        self.black_sec_spin.setRange(1, 24 * 60 * 60)
        self.black_sec_spin.setSingleStep(30)
        self.black_sec_spin.setValue(600)
        self.black_sec_spin.setSuffix(" sec")
        form.addRow("Black time:", self.black_sec_spin)

        self.increment_check = QCheckBox("FIDE-style increment after each move")
        self.increment_check.setToolTip("Adds the increment to the player who just completed a legal move.")
        self.increment_check.toggled.connect(lambda _checked: self._on_timer_toggled(self.timer_check.isChecked()))
        form.addRow("Increment mode:", self.increment_check)

        self.increment_sec_spin = QSpinBox()
        self.increment_sec_spin.setRange(0, 60 * 60)
        self.increment_sec_spin.setSingleStep(1)
        self.increment_sec_spin.setValue(30)
        self.increment_sec_spin.setSuffix(" sec/move")
        form.addRow("Increment:", self.increment_sec_spin)

        root.addLayout(form)

        help_label = QLabel(
            "The current shared game file will be reused; the other player will "
            "automatically load the new game." if self._network else
            "The current window will be reset; no file path is needed."
        )
        help_label.setWordWrap(True)
        help_label.setStyleSheet("color: #555; font-size: 11px; padding: 4px;")
        root.addWidget(help_label)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Ok).setText("Start")
        buttons.accepted.connect(self._on_accept)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

        self._on_timer_toggled(False)

    def options(self) -> NewGameOptions:
        return self._options


    def _set_color_options(self, *, allow_random: bool) -> None:
        """Keep one shared color combo but expose Random only for hosting.

        Join mode intentionally does not ask for a color: it reads the host
        color from the shared file and takes the opposite side so the two
        clients cannot accidentally choose the same color.
        """
        current = self.color_combo.currentData()
        self.color_combo.blockSignals(True)
        self.color_combo.clear()
        self.color_combo.addItem("White", 'w')
        self.color_combo.addItem("Black", 'b')
        if allow_random:
            self.color_combo.addItem("Random", 'random')
        idx = self.color_combo.findData(current)
        if idx < 0:
            idx = 0
        self.color_combo.setCurrentIndex(idx)
        self.color_combo.blockSignals(False)

    def _on_timer_toggled(self, checked: bool) -> None:
        enabled = bool(checked)
        self.white_sec_spin.setEnabled(enabled)
        self.black_sec_spin.setEnabled(enabled)
        self.increment_check.setEnabled(enabled)
        self.increment_sec_spin.setEnabled(enabled and self.increment_check.isChecked())

    def _on_accept(self) -> None:
        self._options = NewGameOptions(
            cancelled=False,
            color=self.color_combo.currentData(),
            timer_enabled=bool(self.timer_check.isChecked()),
            white_seconds=int(self.white_sec_spin.value()),
            black_seconds=int(self.black_sec_spin.value()),
            increment_seconds=(int(self.increment_sec_spin.value()) if self.timer_check.isChecked() and self.increment_check.isChecked() else 0),
        )
        self.accept()
