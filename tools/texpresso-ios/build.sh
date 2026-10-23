#!/bin/sh
# build.sh [folder]
#
# TeXpresso's in-process engine (its eclipse branch: stock TeX Live engines through
# wasm and wasm2c to C, run on a coroutine in the app's own process) for the iPad
# app, as <folder>/Texpresso.xcframework (texpresso.h): Live Preview on a thread
# speaking TeXpresso's line protocol, and Compile's engine runs. Beside it, for
# checking on this Mac, <folder>/macos/texpresso is the same frontend as a
# program, which the core's tests can run as TEXLOCAL_TEXPRESSO.
#
# Needs Xcode (the iOS SDKs), Homebrew's mupdf (for the Mac program),
# and the engines' C: `make fetch-engine` downloads XeTeX's and pdfTeX's; with
# TEXPRESSO_IOS_FROM_SOURCE=1 they are built from TeX Live's sources with
# toolchain.sh's emscripten and wabt (an hour or two), as BibTeX, makeindex and
# xdvipdfmx (XeTeX's PDF writer) always are. TEXPRESSO_IOS_ENGINES says which
# programs go in; the first is Live Preview's.
set -eu
ECLIPSE=c3a321b25bc1f9755b2d486ac0f1fcedd3c0ba11 # let-def/texpresso, branch eclipse
MUPDF=1.28.5
MIN_IOS=17.0
ENGINES=${TEXPRESSO_IOS_ENGINES:-xetex pdftex bibtex makeindex xdvipdfmx}
LIVE=${ENGINES%% *}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=$(mkdir -p "${1:-$HERE/build}" && CDPATH= cd -- "${1:-$HERE/build}" && pwd)
JOBS=$(sysctl -n hw.ncpu)
SRC=$WORK/texpresso
cd "$WORK"

# --- sources ---------------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  git clone --branch eclipse https://github.com/let-def/texpresso.git "$SRC"
fi
git -C "$SRC" cat-file -e "$ECLIPSE^{commit}" 2>/dev/null || git -C "$SRC" fetch origin eclipse
# Already applied, as a rebuild finds it: build what's there.
if ! git -C "$SRC" apply --reverse --check "$HERE/eclipse-ios.patch" 2>/dev/null; then
  git -C "$SRC" checkout --quiet --force --detach "$ECLIPSE"
  git -C "$SRC" clean --quiet --force -d src scripts
  git -C "$SRC" apply "$HERE/eclipse-ios.patch"
fi
# Live Preview's loop and the Type 1 fonts' copies, as the Mac's program has them.
cp -R "$HERE/../texpresso/src/." "$SRC/src/"
if [ ! -d mupdf/.git ]; then
  git clone --depth 1 --branch "$MUPDF" --recurse-submodules --shallow-submodules \
    https://github.com/ArtifexSoftware/mupdf.git mupdf
fi

# --- the engines' C ----------------------------------------------------------------
if [ "${TEXPRESSO_IOS_FROM_SOURCE:-0}" = 1 ]; then
  sh "$HERE/toolchain.sh" "$WORK/toolchain"
  . "$WORK/toolchain/env.sh"
fi
for e in $ENGINES; do
  [ -f "$SRC/engines/build-wasm2c-$e/engine.c" ] && continue
  case $e:${TEXPRESSO_IOS_FROM_SOURCE:-0} in
    xetex:0|pdftex:0|luatex:0) make -C "$SRC" fetch-engine TEXPRESSO_ENGINE="$e" ;;
    xetex:1|pdftex:1|luatex:1) make -C "$SRC" engine-source TEXPRESSO_ENGINE="$e" ;;
    *:1)
      [ -f "$SRC/engines/build-wasm-tools/texk/web2c/bibtex.wasm" ] ||
        (cd "$SRC" && bash scripts/fetch-engines.sh && bash scripts/build-wasm-tools.sh)
      (cd "$SRC" && bash scripts/build-wasm2c-tool.sh "$e") ;;
    *) echo "$e is built from source only: TEXPRESSO_IOS_FROM_SOURCE=1" >&2; exit 1 ;;
  esac
done
# The wabt runtime: a fetched bundle has it beside engine.c, a source build in wabt.
rt() {
  for d in "$SRC/engines/build-wasm2c-$1" "${WABT_PREFIX:-/nonexistent}/share/wabt/wasm2c"; do
    [ -f "$d/wasm-rt-impl.c" ] && { echo "$d"; return; }
  done
  echo "no wasm2c runtime for $1" >&2
  exit 1
}
rtinc() {
  for d in "$SRC/engines/build-wasm2c-$1" "${WABT_PREFIX:-/nonexistent}/include"; do
    [ -f "$d/wasm-rt.h" ] && { echo "$d"; return; }
  done
}

# --- one platform: sdk, target triple, output folder -------------------------------
# Every engine is linked with its host into one object whose only external
# symbols are its prefixed API (<engine>_wasm_engine_init...), so two engines'
# identical wasm2c and runtime names don't meet.
#
# The wasm runtime checks bounds rather than relying on guard pages, which would
# reserve 8 GB of address space per instance, beyond what an iOS app can count on.
# Without guard pages the runtime counts calls instead, 500 deep by default, which
# deep TeX recursion can pass: 6000 of the engines' largest frame (4.4 KB) fit the
# coroutine's 32 MB (wasm_host.c) with room for the host's calls.
WASM_RT="-DWASM_RT_USE_MMAP=1 -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -DWASM_RT_MAX_CALL_STACK_DEPTH=6000"
FRONTEND="frontend/state.c frontend/fs.c frontend/incdvi.c frontend/myabort.c
  frontend/synctex.c frontend/prot_parser.c frontend/sexp_parser.c frontend/json_parser.c
  frontend/editor.c frontend/live.c frontend/engine_tex_xetex.c frontend/engine_tex_pdftex.c
  frontend/engine_tex_luatex.c common/utils.c common/tectonic_provider.c
  common/texlive_provider.c dvi/dvi_context.c dvi/dvi_interp.c dvi/dvi_prim.c
  dvi/dvi_special.c dvi/dvi_scratch.c dvi/dvi_fonttable.c dvi/dvi_resmanager.c
  dvi/tex_tfm.c dvi/tex_fontmap.c dvi/tex_vf.c dvi/tex_enc.c dvi/vstack.c dvi/pdf_lexer.c
  dvi/type1_cff.c"

# Compiles run in parallel; any failure ends the build.
pids=""
bg() { "$@" & pids="$pids $!"; }
join() { for p in $pids; do wait "$p" || exit 1; done; pids=""; }

inc="-I$SRC/src/frontend -I$SRC/src/dvi -I$SRC/src/include"

slice() { # name sdk target
  name=$1 sdk=$2 target=$3
  out=$WORK/$name
  mkdir -p "$out/obj"
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc="xcrun --sdk $sdk clang -target $target -isysroot $sysroot"

  # MuPDF without what TeX's pages never need: other document formats, its
  # fonts but the base 14, JavaScript, OCR. iOS has no <sys/random.h>.
  mu=$WORK/mupdf/build/$name
  if [ ! -f "$mu/libmupdf.a" ]; then
    flags="-target $target -isysroot $sysroot -I$HERE/ios-include -DTOFU -DTOFU_CJK
      -DFZ_ENABLE_XPS=0 -DFZ_ENABLE_SVG=0 -DFZ_ENABLE_CBZ=0 -DFZ_ENABLE_HTML=0
      -DFZ_ENABLE_MD=0 -DFZ_ENABLE_HTML_ENGINE=0 -DFZ_ENABLE_FB2=0 -DFZ_ENABLE_MOBI=0
      -DFZ_ENABLE_EPUB=0 -DFZ_ENABLE_OFFICE=0 -DFZ_ENABLE_TXT=0 -DFZ_ENABLE_JS=0
      -DFZ_ENABLE_BARCODE=0 -DFZ_ENABLE_HYPHEN=0 -DFZ_ENABLE_OCR_OUTPUT=0
      -DFZ_ENABLE_DOCX_OUTPUT=0 -DFZ_ENABLE_ODT_OUTPUT=0 -DFZ_ENABLE_BROTLI=0"
    flags=$(echo $flags)
    make -C "$WORK/mupdf" generate >/dev/null
    make -C "$WORK/mupdf" -j"$JOBS" libs OS=Darwin build=release ARCHFLAGS="-arch arm64" \
      XCFLAGS="$flags" XLDFLAGS="$flags" OUT="build/$name" HAVE_GLUT=no HAVE_X11=no \
      HAVE_LIBCRYPTO=no HAVE_CURL=no HAVE_TESSERACT=no HAVE_LEPTONICA=no \
      HAVE_ZXINGCPP=no HAVE_BROTLI=no HAVE_MUJS=no HAVE_EXTRACT=no HAVE_CMARK_GFM=no
  fi
  mu_inc="-I$WORK/mupdf/include -I$WORK/mupdf/thirdparty/freetype/include"

  objs=""
  for f in $FRONTEND; do
    o=$out/obj/$(echo "$f" | tr / _).o
    bg $cc -O2 -include "$SRC/src/embed/embed_config.h" $inc $mu_inc -c "$SRC/src/$f" -o "$o"
    objs="$objs $o"
  done
  bg $cc -O2 -include "$SRC/src/embed/embed_config.h" $inc $mu_inc -DTEXPRESSO_ENGINE="\"$LIVE\"" \
    -DTXP_HOST_PREFIX="${LIVE}_" -c "$SRC/src/frontend/engine_tex.c" -o "$out/obj/engine_tex.o"
  join
  objs="$objs $out/obj/engine_tex.o"

  # The engines txp_run knows, Live Preview's first.
  {
    echo '#include "engines.h"'
    for e in $ENGINES; do
      echo "int ${e}_wasm_engine_run_native(int, char **, const char *, int, char *const *, const volatile int *);"
      echo "void ${e}_wasm_engine_shutdown(void);"
    done
    echo "const struct txp_engine_entry txp_engines[] = {"
    for e in $ENGINES; do
      echo "  {\"$e\", ${e}_wasm_engine_run_native, ${e}_wasm_engine_shutdown},"
    done
    echo "  {0, 0, 0},"
    echo "};"
  } > "$out/obj/engines.c"
  cat > "$out/obj/engines.h" <<EOF
struct txp_engine_entry {
  const char *name;
  int (*run)(int, char **, const char *, int, char *const *, const volatile int *);
  void (*shutdown)(void);
};
extern const struct txp_engine_entry txp_engines[];
EOF
  $cc -O2 -I"$out/obj" -c "$out/obj/engines.c" -o "$out/obj/engines.o"
  $cc -O2 -I"$out/obj" $inc $mu_inc -c "$SRC/src/embed/embed.c" -o "$out/obj/embed.o"
  objs="$objs $out/obj/engines.o $out/obj/embed.o"

  for e in $ENGINES; do
    d=$SRC/engines/build-wasm2c-$e
    u=$out/obj/$e
    mkdir -p "$u"
    r=$(rt "$e") i=$(rtinc "$e")
    if [ ! -f "$u/engine.o" ] || [ "$d/engine.c" -nt "$u/engine.o" ]; then
      # -O1: the generated module is huge, and -O2 is far slower to build for little.
      bg $cc -O1 $WASM_RT -I"$i" -I"$d" -c "$d/engine.c" -o "$u/engine.o"
    fi
    for f in wasm-rt-impl wasm-rt-mem-impl wasm-rt-exceptions-impl; do
      bg $cc -O2 $WASM_RT -include "$SRC/src/embed/embed_config.h" -I"$i" -I"$r" \
        -c "$r/$f.c" -o "$u/$f.o"
    done
    # Its ucontext_t needs _XOPEN_SOURCE from the first header on, which the
    # forced include would otherwise come before.
    bg $cc -O2 $WASM_RT -D_XOPEN_SOURCE=700 -D_DARWIN_C_SOURCE=1 \
      -include "$SRC/src/embed/embed_config.h" -DWASM_HOST_NO_MAIN \
      -DTXP_HOST_PREFIX="${e}_" -I"$i" -I"$r" -I"$d" -c "$SRC/src/engine-wasm/wasm_host.c" \
      -o "$u/wasm_host.o"
    join
    nm -gU "$u/wasm_host.o" | awk '{print $3}' | grep "^_${e}_wasm_" > "$u/exported"
    xcrun ld -r -arch arm64 "$u/engine.o" "$u"/wasm-rt-*.o "$u/wasm_host.o" \
      -exported_symbols_list "$u/exported" -o "$u/unit.o"
    objs="$objs $u/unit.o"
  done

  xcrun libtool -static -o "$out/libtexpresso.a" $objs "$mu/libmupdf.a" "$mu/libmupdf-third.a" 2>/dev/null
}

slice ios-arm64 iphoneos "arm64-apple-ios$MIN_IOS"
slice ios-arm64-simulator iphonesimulator "arm64-apple-ios$MIN_IOS-simulator"

rm -rf "$WORK/include" "$WORK/Texpresso.xcframework"
mkdir -p "$WORK/include"
cp "$SRC/src/embed/texpresso.h" "$WORK/include/"
cat > "$WORK/include/module.modulemap" <<'EOF'
module Texpresso {
  header "texpresso.h"
  export *
}
EOF
xcodebuild -create-xcframework \
  -library "$WORK/ios-arm64/libtexpresso.a" -headers "$WORK/include" \
  -library "$WORK/ios-arm64-simulator/libtexpresso.a" -headers "$WORK/include" \
  -output "$WORK/Texpresso.xcframework" >/dev/null
mkdir -p "$WORK/icu"
cp -f "$SRC/engines/build-wasm2c-xetex"/icudt*.dat "$WORK/icu/"
# The iPad project includes this file when it's here (apps/ipados/TeXLocal.xcconfig): it links the
# engine, and bundles XeTeX's ICU data and the TeX tree that tree.py writes to texmf beside it.
cat > "$WORK/Engine.xcconfig" <<XCCONFIG
TEXPRESSO_BUILD = $WORK
OTHER_LDFLAGS[sdk=iphonesimulator*] = \$(inherited) $WORK/Texpresso.xcframework/ios-arm64-simulator/libtexpresso.a -lz -lc++
OTHER_LDFLAGS[sdk=iphoneos*] = \$(inherited) $WORK/Texpresso.xcframework/ios-arm64/libtexpresso.a -lz -lc++
SWIFT_INCLUDE_PATHS[sdk=iphonesimulator*] = \$(inherited) $WORK/Texpresso.xcframework/ios-arm64-simulator/Headers
SWIFT_INCLUDE_PATHS[sdk=iphoneos*] = \$(inherited) $WORK/Texpresso.xcframework/ios-arm64/Headers
SWIFT_ACTIVE_COMPILATION_CONDITIONS = \$(inherited) TEXPRESSO
XCCONFIG

# --- the Mac program, for the core's tests -----------------------------------------
mac=$WORK/macos
mkdir -p "$mac/obj"
d=$SRC/engines/build-wasm2c-$LIVE
r=$(rt "$LIVE") i=$(rtinc "$LIVE")
brew=$(brew --prefix)
objs=""
for f in $FRONTEND frontend/live_main.c; do
  o=$mac/obj/$(echo "$f" | tr / _).o
  bg cc -O2 $inc -I"$brew/include" -I"$brew/include/freetype2" -c "$SRC/src/$f" -o "$o"
  objs="$objs $o"
done
bg cc -O2 $inc -I"$brew/include" -DTEXPRESSO_ENGINE="\"$LIVE\"" -c "$SRC/src/frontend/engine_tex.c" \
  -o "$mac/obj/engine_tex.o"
bg cc -O2 -DWASM_HOST_NO_MAIN -I"$i" -I"$r" -I"$d" -c "$SRC/src/engine-wasm/wasm_host.c" \
  -o "$mac/obj/wasm_host.o"
[ -f "$mac/obj/engine.o" ] && [ "$mac/obj/engine.o" -nt "$d/engine.c" ] ||
  bg cc -O1 -I"$i" -I"$d" -c "$d/engine.c" -o "$mac/obj/engine.o"
for f in wasm-rt-impl wasm-rt-mem-impl wasm-rt-exceptions-impl; do
  bg cc -O2 -I"$i" -I"$r" -c "$r/$f.c" -o "$mac/obj/$f.o"
  objs="$objs $mac/obj/$f.o"
done
join
cc -o "$mac/texpresso" $objs "$mac/obj/engine_tex.o" "$mac/obj/wasm_host.o" "$mac/obj/engine.o" \
  -L"$brew/lib" -lmupdf $(cd "$SRC" && CC=cc ./mupdf-config.sh -L"$brew/lib") \
  -lz -ljpeg -lharfbuzz -lfreetype -lm
for f in "$d"/icudt*.dat; do [ -f "$f" ] && cp -f "$f" "$mac/"; done

echo "Built $WORK/Texpresso.xcframework and $mac/texpresso."
