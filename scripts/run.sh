#!/bin/sh
set -eu
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app}
export CLANG_MODULE_CACHE_PATH="$REPO_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_DIR/.build/module-cache"
cd "$REPO_DIR"
exec swift run --disable-sandbox GCodeSender
