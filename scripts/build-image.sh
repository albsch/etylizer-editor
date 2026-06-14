#!/usr/bin/env bash
# Build the wasm BEAM's MEMFS image and link it into beam.{js,wasm,data}.
#
#   1. clone etylizer @ pinned ref + `rebar3 compile` (the wasm drivers + patches)
#   2. assemble the MEMFS image from a patched erlang OTP repo
#      host-compiled .beam libs + erts preloaded sources 
#      + freshly generated start_clean.boot + Elixir distribution + etylizer
#   3. relink the wasm emulator (erlang-otp-wasm) with --preload-file <image>
#
# A native `erl` + `rebar3` are needed only as build tools to compile etylizer and
# to generate the boot script.
# The image's OTP .beams come from patched OTP repo itself, so they always match the wasm erts.
set -euo pipefail

EDITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OTP_WASM=_build/erlang-otp-wasm
"$EDITOR_DIR/scripts/resolve-emsdk.sh" # bootstrap emsdk into _build/emsdk
export EMSDK=_build/emsdk # for relink-emulator.sh
BUILD="$EDITOR_DIR/_build"
STAGING="$BUILD/staging"
WEB="$EDITOR_DIR/_build/web"

ETYLIZER_REPO="${ETYLIZER_REPO:-https://github.com/etylizer/etylizer.git}"
ETYLIZER_REF="${ETYLIZER_REF:-as/etylizer-wasm}"
unzip -q -o vendor/elixir.zip -d _build/elixir # extract vendored Elixir into _build/
ELIXIR_LIB=_build/elixir/lib

# etylizer
mkdir -p "$BUILD"
[ -d "$BUILD/etylizer/.git" ] || git clone "$ETYLIZER_REPO" "$BUILD/etylizer"
git -C "$BUILD/etylizer" fetch -q --all
git -C "$BUILD/etylizer" checkout -q "$ETYLIZER_REF"
git -C "$BUILD/etylizer" rev-parse --short=12 HEAD > "$BUILD/etylizer.commit"   # stamped into the page by `make web`
( cd "$BUILD/etylizer" && rebar3 compile )
ETY_EBIN="$BUILD/etylizer/_build/default/lib/etylizer/ebin"

# MEMFS image, OTP taken from erlang-otp-wasm
appvsn() { sed -n 's/.*{vsn,[ ]*"\([0-9.]*\)".*/\1/p' "$1" | head -1; }
ERTS_VSN="$(sed -n 's/^VSN[[:space:]]*=[[:space:]]*//p' "$OTP_WASM/erts/vsn.mk" | head -1)"
ERTS="erts-$ERTS_VSN"
DEST="$STAGING/usr/local/lib/erlang"
rm -rf "$STAGING"
mkdir -p "$DEST/bin" "$DEST/$ERTS/bin" "$DEST/lib/$ERTS/src" \
         "$STAGING/etylizer/ebin" "$STAGING/usr/lib/elixir" "$STAGING/work"

# OTP apps etylizer needs, staged as versioned dirs (ebin/include/src) from the
# wasm tree's host-compiled output. These .beams are arch-independent.
KVSN=""; SVSN=""
for app in kernel stdlib compiler syntax_tools; do
  src="$OTP_WASM/lib/$app"
  [ -d "$src/ebin" ] || { echo "missing $src/ebin — run 'make otp-wasm' first" >&2; exit 1; }
  v="$(appvsn "$src/ebin/$app.app")"
  case "$app" in kernel) KVSN="$v";; stdlib) SVSN="$v";; esac
  for sub in ebin include src; do
    [ -d "$src/$sub" ] && { mkdir -p "$DEST/lib/$app-$v/$sub"; cp -r "$src/$sub/." "$DEST/lib/$app-$v/$sub/"; }
  done
done

# erts preloaded sources (erlang.erl etc.): stdtypes reads code:lib_dir(erts)/src.
cp "$OTP_WASM"/erts/preloaded/src/*.erl "$DEST/lib/$ERTS/src/"

# Generate start_clean.boot for the staged versions (native erl is just the tool;
# the boot embeds $ROOT-relative paths, so it works in the image at /usr/local/...).
printf '{release,{"etylizer-wasm","%s"},{erts,"%s"},[{kernel,"%s"},{stdlib,"%s"}]}.\n' \
  "$ERTS_VSN" "$ERTS_VSN" "$KVSN" "$SVSN" > "$BUILD/start_clean.rel"
( cd "$BUILD" && erl -noshell \
    -pa "$DEST/lib/kernel-$KVSN/ebin" "$DEST/lib/stdlib-$SVSN/ebin" \
    -eval 'case systools:make_script("start_clean",[silent,no_warn_sasl,{path,["'"$DEST"'/lib/*/ebin"]}]) of
             {ok,_,_} -> halt(0); ok -> halt(0); E -> io:format("BOOTGEN ~p~n",[E]), halt(1) end.' )
cp "$BUILD/start_clean.boot" "$DEST/bin/"
cp "$BUILD/start_clean.boot" "$DEST/$ERTS/bin/"

# Elixir distribution (arch-independent .beam) + etylizer beams (drivers + patches).
cp -r "$ELIXIR_LIB" "$STAGING/usr/lib/elixir/lib"
cp "$ETY_EBIN"/*.beam "$STAGING/etylizer/ebin/"

echo "Image staged at $STAGING ($(du -sh "$STAGING" | cut -f1))"

# espresso NIF, statically linked into the emulator
# etylizer minimizes type DNFs with espresso, called in-process via a NIF
# (espresso_nif). The browser BEAM has no fork/exec or dlopen, so the NIF must be
# linked statically into beam.wasm. Compile etylizer's c_src/espresso to wasm
# objects and archive them; relink-emulator.sh registers them via STATIC_NIFS.
ESPRESSO_SRC="$BUILD/etylizer/c_src/espresso"
STATIC_NIFS=""
if [ -f "$ESPRESSO_SRC/espresso_nif.c" ]; then
  source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1   # emcc / emar
  WASM_INC="$(dirname "$(find "$OTP_WASM/erts/include" -name erl_int_sizes_config.h 2>/dev/null | head -1)")"
  ESPRESSO_A="$BUILD/espresso_nif.a"
  ESPRESSO_OBJ="$BUILD/espresso-obj"; rm -rf "$ESPRESSO_OBJ"; mkdir -p "$ESPRESSO_OBJ"
  # pthreads beam.wasm uses shared memory; the statically-linked NIF objects must
  # match (-pthread) or the final wasm-ld step rejects the non-shared memory.
  PTHREAD_CFLAG=; [ "${THREADS:-pthreads}" = pthreads ] && PTHREAD_CFLAG=-pthread
  for f in "$ESPRESSO_SRC"/*.c; do
    [ "$(basename "$f")" = main.c ] && continue # skip any standalone CLI entry
    emcc -std=c99 -D_POSIX_C_SOURCE=200809L -O2 -DSTATIC_ERLANG_NIF $PTHREAD_CFLAG \
      -I"$OTP_WASM/erts/emulator/beam" -I"$WASM_INC" -I"$OTP_WASM/erts/include" \
      -c "$f" -o "$ESPRESSO_OBJ/$(basename "${f%.c}").o"
  done
  emar rcs "$ESPRESSO_A" "$ESPRESSO_OBJ"/*.o
  STATIC_NIFS="$ESPRESSO_A:espresso_nif"
  echo "espresso NIF -> $ESPRESSO_A (statically linked into beam.wasm)"
fi

# relink the emulator with the image preloaded (+ static espresso NIF) ---
STATIC_NIFS="$STATIC_NIFS" EXTRA_LDFLAGS="--preload-file $STAGING@/" \
  "$OTP_WASM/wasm/relink-emulator.sh"

TARGET="$OTP_WASM/bin/wasm32-unknown-emscripten"
mkdir -p "$WEB"
cp "$TARGET/beam.smp"  "$WEB/beam.js"
cp "$TARGET/beam.wasm" "$WEB/beam.wasm"
cp "$TARGET/beam.data" "$WEB/beam.data"
echo "Editor wasm BEAM -> $WEB/beam.{js,wasm,data}"
