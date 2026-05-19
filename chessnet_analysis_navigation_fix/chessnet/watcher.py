"""
File watcher: bridges watchdog's threaded events into Qt signals.

watchdog gives us OS-level filesystem notifications (inotify on Linux,
ReadDirectoryChangesW on Windows, FSEvents on macOS). Cost is tiny --
no polling, no missed-tick failure mode -- but events arrive on a
worker thread, so we need to bounce them onto the GUI thread before
touching widgets.

PySide6 handles this automatically when a Signal is emitted from a
non-GUI thread to a slot whose owning QObject lives on the GUI thread:
the connection type is auto-promoted to QueuedConnection. So all we
do is emit a Signal from the watchdog callback and let Qt cross the
thread boundary for us.

Some shared drives (SMB, especially older NetApp / NAS configs) don't
propagate filesystem notifications across hosts -- the host that wrote
the file sees the event, the other host doesn't. The fallback poller
in main_window.py handles that case. Both mechanisms feed the same
refresh slot, and the slot is idempotent so duplicate triggers are
cheap.
"""
from __future__ import annotations

import os

from PySide6.QtCore import QObject, Signal
from watchdog.events import FileSystemEvent, FileSystemEventHandler
from watchdog.observers import Observer


class FileWatcher(QObject):
    """Watches one file for any modify/move/create event.

    Signal `file_changed` fires (on the GUI thread) whenever the target
    file is touched by anyone -- including atomic rename completions,
    which appear as `on_moved` events on the destination path.
    """

    file_changed = Signal()

    def __init__(self, file_path: str, parent: QObject | None = None):
        super().__init__(parent)
        self._path = os.path.abspath(file_path)
        self._directory = os.path.dirname(self._path) or '.'
        self._basename = os.path.basename(self._path)
        self._observer: Observer | None = None

    def start(self) -> None:
        if self._observer is not None:
            return
        handler = _Handler(self._basename, self)
        obs = Observer()
        obs.schedule(handler, self._directory, recursive=False)
        obs.daemon = True
        obs.start()
        self._observer = obs

    def stop(self) -> None:
        if self._observer is None:
            return
        try:
            self._observer.stop()
            self._observer.join(timeout=2.0)
        except Exception:
            # Best-effort teardown -- we don't care if the worker thread
            # has already wound itself down.
            pass
        self._observer = None


class _Handler(FileSystemEventHandler):
    """Filters directory-level events down to just our one file.

    We listen for modify, create, and move-into-place events. Atomic
    writes appear as a rename whose destination is our file, so
    `on_moved` matters as much as `on_modified`. `on_created` covers
    the case where the file was missing when we started watching and
    appeared later.
    """

    def __init__(self, target_basename: str, owner: FileWatcher):
        super().__init__()
        self._target = target_basename
        self._owner = owner

    def _matches(self, path: str) -> bool:
        return os.path.basename(path) == self._target

    def on_modified(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            return
        if self._matches(event.src_path):
            self._owner.file_changed.emit()

    def on_created(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            return
        if self._matches(event.src_path):
            self._owner.file_changed.emit()

    def on_moved(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            return
        # Atomic rename: dest_path is the file's new (final) name.
        dest = getattr(event, 'dest_path', '') or ''
        if self._matches(dest):
            self._owner.file_changed.emit()
