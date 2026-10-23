#!/bin/sh
# toolchain.sh <folder>
#
# What building the engines from TeX Live's sources needs, from git alone: emscripten
# 6.0.13 with its own LLVM and binaryen (the commits emsdk pins), wabt 1.0.42 and
# ninja. <folder>/env.sh puts them on PATH. LLVM is most of the hour this takes.
set -eu
LLVM=5f47feeedda059f88c30ca6f11109faa5ce5428c
BINARYEN=a631c1445ced72a905b3303b26f148fc706647dd
EMSCRIPTEN=5f63ff2e370da7e6fffd8f54379860bdd18118f9
WABT=1.0.42
NINJA=v1.13.1
TERSER=317f449862b8d48756818cdcaf67c22c31ec852c # v5.51.2
IMPORT_PHASES=2c01b4a7d6af4cac0f1e7c2970cb557432861fa6
TC=$(mkdir -p "$1" && CDPATH= cd -- "$1" && pwd)
J=$(sysctl -n hw.ncpu)
cd "$TC"

fetch() { # folder url commit-or-tag
  [ -d "$1/.git" ] || { git init -q "$1"; git -C "$1" remote add origin "$2"; }
  git -C "$1" fetch -q --depth 1 origin "$3"
  git -C "$1" checkout -q --detach FETCH_HEAD
}
fetch ninja-src https://github.com/ninja-build/ninja "$NINJA"
fetch llvm-project https://github.com/llvm/llvm-project "$LLVM"
fetch binaryen https://github.com/WebAssembly/binaryen "$BINARYEN"
git -C binaryen submodule update -q --init --depth 1
fetch emscripten https://github.com/emscripten-core/emscripten "$EMSCRIPTEN"
[ -d wabt/.git ] || git clone -q --depth 1 --branch "$WABT" --recurse-submodules \
  --shallow-submodules https://github.com/WebAssembly/wabt wabt

mkdir -p bin
[ -x bin/ninja ] || (cd ninja-src && python3 configure.py --bootstrap >/dev/null && cp ninja ../bin/)
PATH=$TC/bin:$PATH

if [ ! -x llvm/bin/wasm-ld ]; then
  cmake -S llvm-project/llvm -B llvm-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TARGETS_TO_BUILD=WebAssembly \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DCMAKE_INSTALL_PREFIX="$TC/llvm" >/dev/null
  ninja -C llvm-build -j"$J" install-clang install-lld install-clang-resource-headers \
    install-llvm-ar install-llvm-nm install-llvm-ranlib install-llvm-objcopy \
    install-llvm-dwarfdump >/dev/null
fi
if [ ! -x binaryen-install/bin/wasm-opt ]; then
  cmake -S binaryen -B binaryen-build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="$TC/binaryen-install" >/dev/null
  ninja -C binaryen-build -j"$J" install >/dev/null
fi
if [ ! -x wabt-install/bin/wasm2c ]; then
  cmake -S wabt -B wabt-build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF \
    -DBUILD_LIBWASM=OFF -DCMAKE_INSTALL_PREFIX="$TC/wabt-install" >/dev/null
  ninja -C wabt-build -j"$J" install >/dev/null
fi

cat > emscripten/.emscripten <<CFG
LLVM_ROOT = '$TC/llvm/bin'
BINARYEN_ROOT = '$TC/binaryen-install'
NODE_JS = '$(command -v node)'
CFG
(cd emscripten && python3 tools/maint/create_entry_points.py)
# emcc's JS optimizer needs acorn, acorn-import-phases and terser. Where npm is
# blocked they come from git (terser's ES modules run unbuilt), with acorn from
# any npm cache on the machine and a stand-in for the source maps never made.
if ! (cd emscripten && npm ci --omit=dev --no-audit --no-fund >/dev/null 2>&1); then
  NM=emscripten/node_modules
  mkdir -p "$NM/@jridgewell/source-map"
  fetch "$NM/terser" https://github.com/terser/terser "$TERSER"
  fetch "$NM/acorn-import-phases" https://github.com/nicolo-ribaudo/acorn-import-phases "$IMPORT_PHASES"
  if [ ! -f "$NM/acorn/package.json" ]; then
    acorn=$(find "$HOME/.npm" -path '*/node_modules/acorn/package.json' 2>/dev/null | head -1)
    [ -n "$acorn" ] || { echo "acorn 8 is needed in $NM/acorn" >&2; exit 1; }
    cp -R "$(dirname "$acorn")" "$NM/acorn"
  fi
  echo '{"name":"@jridgewell/source-map","type":"module","exports":{".":"./index.js"}}' \
    > "$NM/@jridgewell/source-map/package.json"
  echo 'export class SourceMapConsumer {} export class SourceMapGenerator {}' \
    > "$NM/@jridgewell/source-map/index.js"
fi
# What emcc checks bootstrap.py has done, which the steps above did.
mkdir -p emscripten/out
for s in npm_packages create_entry_points git_submodules install_hooks; do
  touch "emscripten/out/$s.stamp"
done

cat > env.sh <<ENV
export PATH="$TC/emscripten:$TC/wabt-install/bin:$TC/bin:\$PATH"
export EM_CONFIG="$TC/emscripten/.emscripten"
export EMCC_SKIP_SANITY_CHECK=1
export WABT_PREFIX="$TC/wabt-install"
ENV
echo "Built the toolchain in $TC: . $TC/env.sh"
