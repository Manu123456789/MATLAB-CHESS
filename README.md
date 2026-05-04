# MATLAB-CHESS

Chess in MATLAB on a shared network drive.

## Stockfish Setup

This project uses the Stockfish chess engine.

Stockfish repository:  
https://github.com/official-stockfish/Stockfish

---

## 1. Install MSYS2

Install MSYS2 using `winget`:

```bash
winget install MSYS2.MSYS2
```

Open the MSYS2 terminal after installation.

---

## 2. Update MSYS2 Packages

Clean the package cache:

```bash
pacman -Scc
```

Update package databases:

```bash
pacman -Syyu
```

If prompted, close and reopen the MSYS2 terminal, then run:

```bash
pacman -Syu
```

---

## 3. Install Required Compiler Tools

Install the required build tools:

```bash
pacman -S --needed base-devel mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-make
```

---

## 4. Verify Compiler Installation

Confirm that `g++` is installed:

```bash
which g++
g++ --version
```

Confirm that `make` is installed:

```bash
which make
make --version
```

---

## 5. Build Stockfish

Navigate to the Stockfish source directory:

```bash
cd /path/to/Stockfish/Stockfish-master/src
```

Clean any previous build files:

```bash
make clean
```

Build Stockfish:

```bash
make -j build
```

---

## Notes

- Replace `/path/to/Stockfish/Stockfish-master/src` with the actual location of the Stockfish `src` directory.
- The compiled Stockfish executable should be created in the `src` directory after the build completes.
- Make sure MATLAB has access to the shared network drive where the Stockfish executable is stored.
