# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for building the ChessNet Windows executable.

Build from the project root with:
    pyinstaller --clean --noconfirm ChessNet.spec

The output executable will be created at:
    dist/ChessNet.exe

The build_windows_exe.bat script also copies that executable to:
    <your Desktop>/ChessNet.exe
"""
from PyInstaller.utils.hooks import collect_submodules

block_cipher = None

hiddenimports = []
hiddenimports += collect_submodules('chess')
hiddenimports += collect_submodules('PySide6')


a = Analysis(
    ['main.py'],
    pathex=[],
    binaries=[],
    datas=[('assets', 'assets')],
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

# Build a single-file executable so the finished ChessNet.exe can be copied
# directly to the user's Desktop and launched without a companion dist folder.
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='ChessNet',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
