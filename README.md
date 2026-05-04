# MATLAB-CHESS
Chess in MATLAB on a shared network drive!

Install and compile the stockfish: https://github.com/official-stockfish/Stockfish

For compiler:
winget install MSYS2.MSYS2

pacman -Scc \n
pacman -Syyu
pacman -Syu
pacman -S --needed base-devel mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-make

For verificaiton:
which g++
g++ --version
which make
make --version

Build Stockfish:
cd /path/to/Stockfish/.../Stockfish-master/src
make clean
make -j build
