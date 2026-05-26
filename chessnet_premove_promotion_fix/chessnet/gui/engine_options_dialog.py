"""GUI editor for Stockfish path, UCI options, and search limits."""
from __future__ import annotations

import os

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QGridLayout, QGroupBox, QHBoxLayout, QLabel, QLineEdit, QMessageBox,
    QPushButton, QSpinBox, QTextEdit, QVBoxLayout,
)

from ..engine import EngineSettings, load_saved_engine_settings, save_engine_settings


class StockfishOptionsDialog(QDialog):
    """Modal Stockfish settings editor.

    The dialog intentionally exposes the controls that are most useful for a
    chess-game UI without trying to mirror every UCI option of every engine.
    Extra UCI setoption lines are available for power users.
    """

    def __init__(self, settings: EngineSettings | None = None, *, require_path: bool = True, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Stockfish Options")
        self.setModal(True)
        self.setMinimumWidth(660)
        self._require_path = bool(require_path)
        self._settings = EngineSettings.from_dict(
            (settings or load_saved_engine_settings()).to_dict()
        )

        root = QVBoxLayout(self)
        root.setContentsMargins(16, 16, 16, 12)
        root.setSpacing(10)

        header = QLabel("Stockfish engine settings")
        f = header.font(); f.setPointSize(14); f.setBold(True)
        header.setFont(f)
        root.addWidget(header)

        path_group = QGroupBox("Executable")
        path_layout = QHBoxLayout(path_group)
        self.path_edit = QLineEdit(self._settings.engine_path)
        self.path_edit.setPlaceholderText("Path to stockfish executable")
        self.path_browse_btn = QPushButton("Browse...")
        self.path_browse_btn.clicked.connect(self._on_browse_engine)
        path_layout.addWidget(self.path_edit, 1)
        path_layout.addWidget(self.path_browse_btn)
        root.addWidget(path_group)

        uci_group = QGroupBox("Strength / UCI options")
        uci = QGridLayout(uci_group)
        row = 0
        self.threads_spin = self._spin(1, 512, self._settings.threads)
        self.hash_spin = self._spin(1, 102400, self._settings.hash_mb, suffix=" MB")
        self.multipv_spin = self._spin(1, 20, self._settings.multipv)
        self.skill_spin = self._spin(0, 20, self._settings.skill_level)
        self.elo_spin = self._spin(1320, 3190, self._settings.elo)
        self.limit_strength_check = QCheckBox("Limit strength by ELO")
        self.limit_strength_check.setChecked(self._settings.limit_strength)
        self.ponder_check = QCheckBox("Ponder")
        self.ponder_check.setChecked(self._settings.ponder)
        self.show_wdl_check = QCheckBox("Show WDL")
        self.show_wdl_check.setChecked(self._settings.show_wdl)
        self.clear_hash_check = QCheckBox("Clear hash on start")
        self.clear_hash_check.setChecked(self._settings.clear_hash)
        self.syzygy_edit = QLineEdit(self._settings.syzygy_path)
        self.syzygy_edit.setPlaceholderText("Optional Syzygy tablebase path")

        self._add_row(uci, row, "Threads:", self.threads_spin, "Hash:", self.hash_spin); row += 1
        self._add_row(uci, row, "MultiPV:", self.multipv_spin, "Skill level:", self.skill_spin); row += 1
        uci.addWidget(self.limit_strength_check, row, 0, 1, 2)
        self._add_label_widget(uci, row, 2, "UCI ELO:", self.elo_spin); row += 1
        uci.addWidget(self.ponder_check, row, 0, 1, 2)
        uci.addWidget(self.show_wdl_check, row, 2, 1, 2); row += 1
        uci.addWidget(self.clear_hash_check, row, 0, 1, 2); row += 1
        uci.addWidget(QLabel("Syzygy path:"), row, 0, alignment=Qt.AlignRight)
        uci.addWidget(self.syzygy_edit, row, 1, 1, 3); row += 1
        root.addWidget(uci_group)

        search_group = QGroupBox("Search limit")
        search = QGridLayout(search_group)
        self.search_mode_combo = QComboBox()
        self.search_mode_combo.addItem("Move time", "movetime")
        self.search_mode_combo.addItem("Depth", "depth")
        self.search_mode_combo.addItem("Nodes", "nodes")
        idx = self.search_mode_combo.findData(self._settings.search_mode)
        self.search_mode_combo.setCurrentIndex(max(0, idx))
        self.search_mode_combo.currentIndexChanged.connect(self._refresh_search_enables)
        self.movetime_spin = self._spin(1, 600000, self._settings.movetime_ms, suffix=" ms")
        self.depth_spin = self._spin(1, 99, self._settings.depth)
        # QSpinBox is backed by a 32-bit signed integer in Qt, so very large
        # UCI node limits overflow it on Windows. Nodes can legitimately be
        # larger than INT_MAX, so this field is a validated QLineEdit instead.
        self.nodes_spin = self._big_int_edit(1, 10_000_000_000, self._settings.nodes)
        self.use_clock_check = QCheckBox("Use clock time when available")
        self.use_clock_check.setChecked(self._settings.use_clock)
        self.white_inc_spin = self._spin(0, 600000, self._settings.white_increment_ms, suffix=" ms")
        self.black_inc_spin = self._spin(0, 600000, self._settings.black_increment_ms, suffix=" ms")
        self.move_overhead_spin = self._spin(0, 60000, self._settings.move_overhead_ms, suffix=" ms")
        self.hard_timeout_spin = self._spin(2, 300, int(round(self._settings.search_timeout_sec)), suffix=" s")
        self.hard_timeout_spin.setToolTip("ChessNet watchdog timeout for one engine request. This is separate from Stockfish Move Overhead.")
        search.addWidget(QLabel("Mode:"), 0, 0, alignment=Qt.AlignRight)
        search.addWidget(self.search_mode_combo, 0, 1)
        self._add_label_widget(search, 0, 2, "Move time:", self.movetime_spin)
        self._add_label_widget(search, 1, 0, "Depth:", self.depth_spin)
        self._add_label_widget(search, 1, 2, "Nodes:", self.nodes_spin)
        search.addWidget(self.use_clock_check, 2, 0, 1, 2)
        self._add_label_widget(search, 2, 2, "Move overhead:", self.move_overhead_spin)
        self._add_label_widget(search, 3, 0, "White inc:", self.white_inc_spin)
        self._add_label_widget(search, 3, 2, "Black inc:", self.black_inc_spin)
        self._add_label_widget(search, 4, 0, "Engine hard timeout:", self.hard_timeout_spin)
        root.addWidget(search_group)

        extra_group = QGroupBox("Advanced extra UCI options")
        extra_layout = QVBoxLayout(extra_group)
        extra_help = QLabel("One option per line. Use either 'Name=Value' or 'Name' for button-style options.")
        extra_help.setStyleSheet("color: #555; font-size: 11px;")
        self.extra_edit = QTextEdit(self._settings.extra_setoptions)
        self.extra_edit.setFixedHeight(70)
        extra_layout.addWidget(extra_help)
        extra_layout.addWidget(self.extra_edit)
        root.addWidget(extra_group)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Ok).setText("Save")
        buttons.accepted.connect(self._on_accept)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

        self._refresh_search_enables()

    def settings(self) -> EngineSettings:
        return self._settings

    @staticmethod
    def _spin(minimum: int, maximum: int, value: int, *, suffix: str = "") -> QSpinBox:
        sp = QSpinBox()
        # QSpinBox uses signed 32-bit ints internally. Clamp defensively so a
        # saved config or future option cannot crash the dialog constructor.
        qt_min = max(-2_147_483_648, int(minimum))
        qt_max = min(2_147_483_647, int(maximum))
        sp.setRange(qt_min, qt_max)
        sp.setValue(max(qt_min, min(qt_max, int(value))))
        if suffix:
            sp.setSuffix(suffix)
        return sp

    @staticmethod
    def _big_int_edit(minimum: int, maximum: int, value: int) -> QLineEdit:
        edit = QLineEdit()
        edit.setAlignment(Qt.AlignRight)
        edit.setPlaceholderText(f"{minimum:,} to {maximum:,}")
        edit.setToolTip(f"Enter an integer from {minimum:,} to {maximum:,}. Commas are allowed.")
        try:
            v = int(value)
        except (TypeError, ValueError):
            v = int(minimum)
        v = max(int(minimum), min(int(maximum), v))
        edit.setText(f"{v}")
        return edit

    @staticmethod
    def _read_big_int(edit: QLineEdit, minimum: int, maximum: int, label: str) -> int | None:
        raw = edit.text().strip().replace(',', '').replace('_', '').replace(' ', '')
        try:
            value = int(raw)
        except ValueError:
            return None
        if value < minimum or value > maximum:
            return None
        return value

    @staticmethod
    def _add_label_widget(grid: QGridLayout, row: int, col: int, label: str, widget) -> None:
        grid.addWidget(QLabel(label), row, col, alignment=Qt.AlignRight)
        grid.addWidget(widget, row, col + 1)

    def _add_row(self, grid: QGridLayout, row: int, left_label: str, left_widget, right_label: str, right_widget) -> None:
        self._add_label_widget(grid, row, 0, left_label, left_widget)
        self._add_label_widget(grid, row, 2, right_label, right_widget)

    def _on_browse_engine(self) -> None:
        if os.name == 'nt':
            filt = "Stockfish executable (stockfish*.exe *.exe);;All files (*)"
        else:
            filt = "Stockfish executable (stockfish* *);;All files (*)"
        path, _ = QFileDialog.getOpenFileName(
            self, "Select Stockfish executable", self.path_edit.text() or "", filt
        )
        if path:
            self.path_edit.setText(path)

    def _refresh_search_enables(self) -> None:
        mode = self.search_mode_combo.currentData()
        self.movetime_spin.setEnabled(mode == 'movetime')
        self.depth_spin.setEnabled(mode == 'depth')
        self.nodes_spin.setEnabled(mode == 'nodes')

    def _on_accept(self) -> None:
        path = self.path_edit.text().strip()
        nodes_value = self._read_big_int(self.nodes_spin, 1, 10_000_000_000, "Nodes")
        if nodes_value is None:
            QMessageBox.warning(
                self,
                "Invalid node limit",
                "Nodes must be an integer from 1 to 10,000,000,000.",
            )
            return
        if self._require_path:
            if not path:
                QMessageBox.warning(self, "Missing Stockfish path", "Please choose a Stockfish executable.")
                return
            if not os.path.exists(path):
                QMessageBox.warning(self, "Stockfish not found", f"The executable does not exist:\n{path}")
                return
        self._settings = EngineSettings(
            engine_path=path,
            threads=int(self.threads_spin.value()),
            hash_mb=int(self.hash_spin.value()),
            multipv=int(self.multipv_spin.value()),
            skill_level=int(self.skill_spin.value()),
            limit_strength=bool(self.limit_strength_check.isChecked()),
            elo=int(self.elo_spin.value()),
            ponder=bool(self.ponder_check.isChecked()),
            move_overhead_ms=int(self.move_overhead_spin.value()),
            show_wdl=bool(self.show_wdl_check.isChecked()),
            syzygy_path=self.syzygy_edit.text().strip(),
            clear_hash=bool(self.clear_hash_check.isChecked()),
            search_mode=str(self.search_mode_combo.currentData()),
            movetime_ms=int(self.movetime_spin.value()),
            depth=int(self.depth_spin.value()),
            nodes=int(nodes_value),
            use_clock=bool(self.use_clock_check.isChecked()),
            white_increment_ms=int(self.white_inc_spin.value()),
            black_increment_ms=int(self.black_inc_spin.value()),
            search_timeout_sec=float(self.hard_timeout_spin.value()),
            extra_setoptions=self.extra_edit.toPlainText().strip(),
        ).normalized()
        save_engine_settings(self._settings)
        self.accept()
