#!/bin/sh
set -eu
cd "$(dirname -- "$0")"
find build.sh underleaf-pdf.patch src -type f | LC_ALL=C sort | xargs shasum -a 256
