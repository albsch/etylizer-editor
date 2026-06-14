#!/usr/bin/env bash
# Bootstrap the pinned Emscripten SDK into _build/emsdk
# Run from the project root.
set -euo pipefail

VER="6.0.0"

if [ ! -f _build/emsdk/.emscripten ]; then # check if full setup is ready
  git clone --depth 1 https://github.com/emscripten-core/emsdk _build/emsdk
  cd _build/emsdk && ./emsdk install "$VER" && ./emsdk activate "$VER"
fi
