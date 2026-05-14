"""Stockfish / UCI integration for ChessNet.

The GUI uses this module for two independent workflows:
  * play against Stockfish, where the engine returns a best move;
  * spectator / review evaluation, where the engine returns score + PV data.

The wrapper is deliberately small and process-per-request friendly so GUI
workers can run without sharing a mutable engine process between bot moves and
analysis refreshes.
"""
from __future__ import annotations

import json
import os
import platform
import subprocess
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional

import chess


@dataclass
class PrincipalVariation:
    multipv: int = 1
    depth: Optional[int] = None
    score_type: str = ''       # 'cp' | 'mate' | ''
    score_value: Optional[int] = None
    first_move: str = ''
    line: str = ''


@dataclass
class EngineAnalysis:
    bestmove: str = ''
    ponder: str = ''
    score_cp_white: Optional[int] = None
    mate_white: Optional[int] = None
    depth: Optional[int] = None
    pvs: list[PrincipalVariation] | None = None
    raw_lines: list[str] | None = None

    def is_empty(self) -> bool:
        return not self.bestmove and self.score_cp_white is None and self.mate_white is None


@dataclass
class EngineSettings:
    """UCI and search settings exposed in the options dialog."""

    engine_path: str = ''
    threads: int = 1
    hash_mb: int = 16
    multipv: int = 1
    skill_level: int = 20
    limit_strength: bool = False
    elo: int = 1320
    ponder: bool = False
    move_overhead_ms: int = 10
    show_wdl: bool = False
    syzygy_path: str = ''
    clear_hash: bool = False

    search_mode: str = 'movetime'   # movetime | depth | nodes
    movetime_ms: int = 800
    depth: int = 8
    nodes: int = 10000
    use_clock: bool = False
    white_increment_ms: int = 0
    black_increment_ms: int = 0

    uci_timeout_sec: float = 10.0
    ready_timeout_sec: float = 10.0
    search_timeout_sec: float = 60.0

    extra_setoptions: str = ''       # newline-delimited "Option=Value" pairs

    @classmethod
    def defaults(cls) -> 'EngineSettings':
        return cls()

    @classmethod
    def for_analysis(cls, base: 'EngineSettings') -> 'EngineSettings':
        """Stronger defaults for passive evaluation / review."""
        s = cls.from_dict(base.to_dict())
        s.limit_strength = False
        s.skill_level = 20
        s.multipv = max(3, int(s.multipv))
        s.ponder = False
        if s.search_mode == 'movetime':
            s.movetime_ms = max(1200, int(s.movetime_ms))
        else:
            s.search_mode = 'depth'
            s.depth = max(12, int(s.depth))
        s.search_timeout_sec = max(90.0, float(s.search_timeout_sec))
        return s

    @classmethod
    def from_dict(cls, d: Optional[dict]) -> 'EngineSettings':
        s = cls()
        if not isinstance(d, dict):
            return s.normalized()
        aliases = {
            'Hash': 'hash_mb', 'Threads': 'threads', 'MultiPV': 'multipv',
            'SkillLevel': 'skill_level', 'UCI_LimitStrength': 'limit_strength',
            'UCI_Elo': 'elo', 'Ponder': 'ponder', 'MoveOverhead': 'move_overhead_ms',
            'UCI_ShowWDL': 'show_wdl', 'SyzygyPath': 'syzygy_path',
            'ClearHash': 'clear_hash', 'SearchMode': 'search_mode',
            'SearchMoveTimeMs': 'movetime_ms', 'SearchDepth': 'depth',
            'SearchNodes': 'nodes', 'UseClock': 'use_clock',
            'WhiteIncrementMs': 'white_increment_ms',
            'BlackIncrementMs': 'black_increment_ms',
            'uciTimeoutSec': 'uci_timeout_sec', 'readyTimeoutSec': 'ready_timeout_sec',
            'searchTimeoutSec': 'search_timeout_sec', 'extraSetOptions': 'extra_setoptions',
            'enginePath': 'engine_path', 'stockfishPath': 'engine_path',
        }
        for key, value in d.items():
            attr = aliases.get(key, key)
            if hasattr(s, attr):
                setattr(s, attr, value)
        return s.normalized()

    def normalized(self) -> 'EngineSettings':
        self.engine_path = str(self.engine_path or '')
        self.threads = max(1, int(1 if self.threads is None else self.threads))
        self.hash_mb = max(1, int(16 if self.hash_mb is None else self.hash_mb))
        self.multipv = max(1, int(1 if self.multipv is None else self.multipv))
        self.skill_level = max(0, min(20, int(0 if self.skill_level is None else self.skill_level)))
        self.limit_strength = bool(self.limit_strength)
        self.elo = max(1320, min(3190, int(1320 if self.elo is None else self.elo)))
        self.ponder = bool(self.ponder)
        self.move_overhead_ms = max(0, int(0 if self.move_overhead_ms is None else self.move_overhead_ms))
        self.show_wdl = bool(self.show_wdl)
        self.syzygy_path = str(self.syzygy_path or '')
        self.clear_hash = bool(self.clear_hash)
        mode = str(self.search_mode or 'movetime').lower().strip()
        self.search_mode = mode if mode in ('movetime', 'depth', 'nodes') else 'movetime'
        self.movetime_ms = max(1, int(800 if self.movetime_ms is None else self.movetime_ms))
        self.depth = max(1, int(8 if self.depth is None else self.depth))
        self.nodes = max(1, int(10000 if self.nodes is None else self.nodes))
        self.use_clock = bool(self.use_clock)
        self.white_increment_ms = max(0, int(0 if self.white_increment_ms is None else self.white_increment_ms))
        self.black_increment_ms = max(0, int(0 if self.black_increment_ms is None else self.black_increment_ms))
        self.uci_timeout_sec = max(1.0, float(10.0 if self.uci_timeout_sec is None else self.uci_timeout_sec))
        self.ready_timeout_sec = max(1.0, float(10.0 if self.ready_timeout_sec is None else self.ready_timeout_sec))
        self.search_timeout_sec = max(1.0, float(60.0 if self.search_timeout_sec is None else self.search_timeout_sec))
        self.extra_setoptions = str(self.extra_setoptions or '')
        return self

    def to_dict(self) -> dict:
        d = asdict(self)
        d['search_mode'] = str(d.get('search_mode', 'movetime')).lower()
        return d

    def go_command(self, board: chess.Board, timer_state=None) -> str:
        if self.use_clock and timer_state is not None and getattr(timer_state, 'enabled', False):
            w = max(0, round(float(timer_state.remaining_for('w')) * 1000))
            b = max(0, round(float(timer_state.remaining_for('b')) * 1000))
            return (
                f"go wtime {w} btime {b} "
                f"winc {max(0, self.white_increment_ms)} "
                f"binc {max(0, self.black_increment_ms)}"
            )
        if self.search_mode == 'depth':
            return f"go depth {self.depth}"
        if self.search_mode == 'nodes':
            return f"go nodes {self.nodes}"
        return f"go movetime {self.movetime_ms}"


def _settings_path() -> Path:
    return Path.home() / '.chessnet_stockfish.json'


def load_saved_engine_settings() -> EngineSettings:
    try:
        path = _settings_path()
        if not path.exists():
            return EngineSettings.defaults()
        return EngineSettings.from_dict(json.loads(path.read_text(encoding='utf-8')))
    except Exception:
        return EngineSettings.defaults()


def save_engine_settings(settings: EngineSettings) -> None:
    try:
        path = _settings_path()
        path.write_text(json.dumps(settings.normalized().to_dict(), indent=2), encoding='utf-8')
    except Exception:
        pass


class StockfishEngine:
    """Minimal blocking UCI bridge.

    Construct and use this inside a worker thread for GUI work. Every public
    request validates the returned move against python-chess before the GUI
    applies it.
    """

    def __init__(self, settings: EngineSettings):
        self.settings = EngineSettings.from_dict(settings.to_dict())
        self.process: subprocess.Popen[str] | None = None
        self._last_lines: list[str] = []

    def start(self) -> None:
        path = os.path.abspath(os.path.expanduser(self.settings.engine_path))
        if not path:
            raise FileNotFoundError("Stockfish executable path is empty.")
        if not os.path.exists(path):
            raise FileNotFoundError(f"Stockfish executable was not found:\n{path}")
        if platform.system() != 'Windows' and not os.access(path, os.X_OK):
            raise PermissionError(f"Stockfish file is not executable:\n{path}")
        self.process = subprocess.Popen(
            [path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self._send('uci')
        self._wait_for('uciok', self.settings.uci_timeout_sec)
        self._apply_options()
        self.new_game()

    def close(self) -> None:
        p = self.process
        if p is None:
            return
        try:
            if p.poll() is None:
                self._send('quit')
                try:
                    p.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    p.kill()
        finally:
            self.process = None

    def __enter__(self) -> 'StockfishEngine':
        self.start()
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def new_game(self) -> None:
        self._ensure_running()
        self._send('ucinewgame')
        self.wait_ready()

    def wait_ready(self) -> None:
        self._ensure_running()
        self._send('isready')
        self._wait_for('readyok', self.settings.ready_timeout_sec)

    def best_move(self, board: chess.Board, timer_state=None) -> EngineAnalysis:
        """Return bestmove plus any score/PV info emitted before bestmove."""
        analysis = self.analyze(board, timer_state=timer_state)
        if analysis.bestmove and analysis.bestmove != '(none)':
            try:
                mv = chess.Move.from_uci(analysis.bestmove)
            except ValueError as e:
                raise ValueError(f"Stockfish returned an invalid move: {analysis.bestmove}") from e
            if mv not in board.legal_moves:
                raise ValueError(f"Stockfish returned illegal move {analysis.bestmove} for the current board.")
        return analysis

    def analyze(self, board: chess.Board, timer_state=None) -> EngineAnalysis:
        self._ensure_running()
        self._drain_available()
        self._send(f"position fen {board.fen()}")
        self.wait_ready()
        self._drain_available()
        self._send(self.settings.go_command(board, timer_state=timer_state))
        lines = self._wait_for('bestmove', self.settings.search_timeout_sec)
        self._last_lines = lines + self._drain_available()
        return parse_analysis_lines(self._last_lines, board.turn)

    def _apply_options(self) -> None:
        s = self.settings
        self._setoption('Threads', s.threads)
        self._setoption('Hash', s.hash_mb)
        self._setoption('MultiPV', s.multipv)
        self._setoption('Ponder', 'true' if s.ponder else 'false')
        self._setoption('Skill Level', s.skill_level)
        self._setoption('Move Overhead', s.move_overhead_ms)
        self._setoption('UCI_LimitStrength', 'true' if s.limit_strength else 'false')
        self._setoption('UCI_Elo', s.elo)
        self._setoption('UCI_ShowWDL', 'true' if s.show_wdl else 'false')
        if s.syzygy_path:
            self._setoption('SyzygyPath', s.syzygy_path)
        for raw in s.extra_setoptions.splitlines():
            line = raw.strip()
            if not line:
                continue
            if '=' in line:
                name, val = line.split('=', 1)
                self._setoption(name.strip(), val.strip())
            else:
                self._send(f"setoption name {line}")
        if s.clear_hash:
            self._send('setoption name Clear Hash')
        self.wait_ready()

    def _setoption(self, name: str, value) -> None:
        if value is None:
            return
        self._send(f"setoption name {name} value {value}")

    def _send(self, line: str) -> None:
        self._ensure_running(allow_starting=True)
        assert self.process is not None and self.process.stdin is not None
        self.process.stdin.write(str(line).rstrip() + '\n')
        self.process.stdin.flush()

    def _ensure_running(self, *, allow_starting: bool = False) -> None:
        if self.process is None:
            if allow_starting:
                return
            raise RuntimeError("Stockfish process has not been started.")
        if self.process.poll() is not None:
            raise RuntimeError("Stockfish process exited unexpectedly.")

    def _wait_for(self, token: str, timeout_sec: float) -> list[str]:
        self._ensure_running()
        assert self.process is not None and self.process.stdout is not None
        lines: list[str] = []
        deadline = time.monotonic() + float(timeout_sec)
        while time.monotonic() < deadline:
            line = self.process.stdout.readline()
            if line == '':
                if self.process.poll() is not None:
                    raise RuntimeError("Stockfish process exited while waiting for output.")
                time.sleep(0.01)
                continue
            line = line.rstrip('\r\n')
            lines.append(line)
            if token in line:
                return lines
        raise TimeoutError(f"Timed out waiting for Stockfish token {token!r}.")

    def _drain_available(self) -> list[str]:
        # Cross-platform non-blocking pipe draining is surprisingly fiddly.
        # For this GUI use case it is safe to skip draining; request boundaries
        # are enforced with isready/bestmove tokens. Kept as a hook for future
        # persistent-process optimization.
        return []


def parse_analysis_lines(lines: list[str], side_to_move: chess.Color) -> EngineAnalysis:
    bestmove = ''
    ponder = ''
    pv_by_multipv: dict[int, PrincipalVariation] = {}
    latest_score_type = ''
    latest_score_value: Optional[int] = None
    latest_depth: Optional[int] = None

    for line in lines or []:
        stripped = line.strip()
        if stripped.startswith('bestmove'):
            parts = stripped.split()
            if len(parts) >= 2:
                bestmove = parts[1]
            if len(parts) >= 4 and parts[2] == 'ponder':
                ponder = parts[3]
            continue
        if not stripped.startswith('info '):
            continue
        parts = stripped.split()
        if 'pv' not in parts:
            continue
        multipv = 1
        depth: Optional[int] = None
        score_type = ''
        score_value: Optional[int] = None
        try:
            if 'multipv' in parts:
                idx = parts.index('multipv')
                multipv = int(parts[idx + 1])
            if 'depth' in parts:
                idx = parts.index('depth')
                depth = int(parts[idx + 1])
            if 'score' in parts:
                idx = parts.index('score')
                score_type = parts[idx + 1]
                score_value = int(parts[idx + 2])
            pv_idx = parts.index('pv')
            pv_moves = parts[pv_idx + 1:]
        except (ValueError, IndexError):
            continue
        if not pv_moves:
            continue
        pv = PrincipalVariation(
            multipv=multipv,
            depth=depth,
            score_type=score_type,
            score_value=score_value,
            first_move=pv_moves[0],
            line=' '.join(pv_moves),
        )
        pv_by_multipv[multipv] = pv
        if multipv == 1 and score_value is not None:
            latest_score_type = score_type
            latest_score_value = score_value
            latest_depth = depth

    score_cp_white: Optional[int] = None
    mate_white: Optional[int] = None
    if latest_score_value is not None:
        sign = 1 if side_to_move == chess.WHITE else -1
        if latest_score_type == 'cp':
            score_cp_white = sign * latest_score_value
        elif latest_score_type == 'mate':
            mate_white = sign * latest_score_value
            # Use a saturating equivalent for the bar. Positive means White is
            # winning; negative means Black is winning.
            score_cp_white = 100000 if mate_white > 0 else -100000

    pvs = [pv_by_multipv[k] for k in sorted(pv_by_multipv)]
    return EngineAnalysis(
        bestmove=bestmove,
        ponder=ponder,
        score_cp_white=score_cp_white,
        mate_white=mate_white,
        depth=latest_depth,
        pvs=pvs,
        raw_lines=list(lines or []),
    )
