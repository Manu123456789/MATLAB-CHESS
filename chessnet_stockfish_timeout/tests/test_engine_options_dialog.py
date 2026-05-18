"""Tests for the Stockfish options dialog.
    python -m tests.test_engine_options_dialog
"""
import os
import sys

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, '.')

from PySide6.QtWidgets import QApplication

from chessnet.engine import EngineSettings
from chessnet.gui.engine_options_dialog import StockfishOptionsDialog


def _app():
    return QApplication.instance() or QApplication([])


def test_nodes_field_accepts_values_larger_than_qspinbox_int_limit():
    app = _app()
    dlg = StockfishOptionsDialog(
        EngineSettings(search_mode='nodes', nodes=10_000_000_000),
        require_path=False,
    )
    assert dlg.nodes_spin.text() == '10000000000'
    assert dlg._read_big_int(dlg.nodes_spin, 1, 10_000_000_000, 'Nodes') == 10_000_000_000
    dlg.nodes_spin.setText('2,500,000,000')
    assert dlg._read_big_int(dlg.nodes_spin, 1, 10_000_000_000, 'Nodes') == 2_500_000_000
    dlg.close()
    app.processEvents()


if __name__ == '__main__':
    tests = [v for k, v in globals().items() if k.startswith('test_')]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  OK  {t.__name__}")
        except Exception as e:
            failed += 1
            print(f"FAIL  {t.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(0 if failed == 0 else 1)
