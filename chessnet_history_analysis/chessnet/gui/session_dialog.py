"""
Session dialog: the first thing the user sees. Picks the play mode,
shared file, host color, and optional per-side chess clock settings.

Output is a SessionChoice dataclass consumed by main.py to wire up
either local-mode or network-mode play.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QFormLayout, QLabel, QComboBox,
    QLineEdit, QPushButton, QFileDialog, QMessageBox, QDialogButtonBox,
    QCheckBox, QSpinBox,
)


MODE_LOCAL = 'local'
MODE_HOST = 'host'
MODE_JOIN = 'join'


@dataclass
class SessionChoice:
    """Result of the session dialog. `cancelled=True` means the user
    closed the dialog without committing -- caller should exit."""
    cancelled: bool = True
    mode: str = MODE_LOCAL
    color: str = 'w'              # 'w' or 'b' -- meaningful for host/local
    file_path: str = ''           # only meaningful for host/join
    timer_enabled: bool = False   # local/host only; join reads file setting
    white_seconds: int = 600
    black_seconds: int = 600


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
        self.mode_combo.currentIndexChanged.connect(self._on_mode_changed)
        form.addRow("Mode:", self.mode_combo)

        # Color picker (host only; local always starts from White's side)
        self.color_combo = QComboBox()
        self.color_combo.addItem("White", 'w')
        self.color_combo.addItem("Black", 'b')
        form.addRow("Your color:", self.color_combo)

        # File path with Browse button
        path_row = QHBoxLayout()
        self.path_edit = QLineEdit()
        self.path_edit.setPlaceholderText(r"e.g. \\share\chess\game.json")
        self.browse_btn = QPushButton("Browse...")
        self.browse_btn.clicked.connect(self._on_browse)
        path_row.addWidget(self.path_edit, 1)
        path_row.addWidget(self.browse_btn)
        form.addRow("Shared game file:", path_row)

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
        timer_allowed = mode in (MODE_LOCAL, MODE_HOST)
        if mode == MODE_LOCAL:
            self.color_combo.setEnabled(False)
            self.path_edit.setEnabled(False)
            self.browse_btn.setEnabled(False)
            self.help_label.setText(
                "Two players share one screen. White moves first. "
                "If the chess clock is enabled, each side may have a different time."
            )
        elif mode == MODE_HOST:
            self.color_combo.setEnabled(True)
            self.path_edit.setEnabled(True)
            self.browse_btn.setEnabled(True)
            self.help_label.setText(
                "Creates a new game file. Pick a location both players can read "
                "and write. Clock settings are written into the file; the joiner "
                "inherits them automatically."
            )
        else:  # MODE_JOIN
            self.color_combo.setEnabled(False)
            self.path_edit.setEnabled(True)
            self.browse_btn.setEnabled(True)
            self.help_label.setText(
                "Opens an existing game file written by the host. Color and clock "
                "settings are read from that file."
            )
        self.timer_check.setEnabled(timer_allowed)
        if not timer_allowed:
            self.timer_check.setChecked(False)
        self._on_timer_toggled(self.timer_check.isChecked() and timer_allowed)

    def _on_timer_toggled(self, checked: bool) -> None:
        enabled = checked and self.timer_check.isEnabled()
        self.white_sec_spin.setEnabled(enabled)
        self.black_sec_spin.setEnabled(enabled)

    def _on_browse(self) -> None:
        mode = self.mode_combo.currentData()
        if mode == MODE_HOST:
            path, _ = QFileDialog.getSaveFileName(
                self, "Create new game file",
                self.path_edit.text() or "game.json",
                "JSON files (*.json);;All files (*)",
            )
        else:
            path, _ = QFileDialog.getOpenFileName(
                self, "Open existing game file",
                self.path_edit.text() or "",
                "JSON files (*.json);;All files (*)",
            )
        if path:
            self.path_edit.setText(path)

    def _on_accept(self) -> None:
        mode = self.mode_combo.currentData()
        color = self.color_combo.currentData()
        path = self.path_edit.text().strip()

        if mode in (MODE_HOST, MODE_JOIN):
            if not path:
                QMessageBox.warning(
                    self, "Missing file path",
                    "Please provide a shared game file path."
                )
                return
            if mode == MODE_JOIN and not os.path.exists(path):
                QMessageBox.warning(
                    self, "File not found",
                    f"The file does not exist:\n{path}\n\n"
                    "Ask the host to create it first."
                )
                return
            if mode == MODE_HOST:
                directory = os.path.dirname(path) or '.'
                if not os.path.isdir(directory):
                    QMessageBox.warning(
                        self, "Folder not found",
                        f"The folder does not exist:\n{directory}"
                    )
                    return

        timer_enabled = bool(self.timer_check.isChecked()) if mode in (MODE_LOCAL, MODE_HOST) else False
        self._choice = SessionChoice(
            cancelled=False,
            mode=mode,
            color=color,
            file_path=path,
            timer_enabled=timer_enabled,
            white_seconds=int(self.white_sec_spin.value()),
            black_seconds=int(self.black_sec_spin.value()),
        )
        self.accept()


@dataclass
class NewGameOptions:
    """Options for restarting the current session without asking for a file."""
    cancelled: bool = True
    color: str = 'w'
    timer_enabled: bool = False
    white_seconds: int = 600
    black_seconds: int = 600


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

    def _on_timer_toggled(self, checked: bool) -> None:
        self.white_sec_spin.setEnabled(bool(checked))
        self.black_sec_spin.setEnabled(bool(checked))

    def _on_accept(self) -> None:
        self._options = NewGameOptions(
            cancelled=False,
            color=self.color_combo.currentData(),
            timer_enabled=bool(self.timer_check.isChecked()),
            white_seconds=int(self.white_sec_spin.value()),
            black_seconds=int(self.black_sec_spin.value()),
        )
        self.accept()
