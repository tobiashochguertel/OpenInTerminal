#!/bin/bash
#
# Build and run the menu-structure tests.
#
# Compiles OpenInTerminalCore into a dylib, then compiles the real
# OpenInTerminalFinderExtension/FinderSync.swift plus the test main
# against it — so the tests exercise the same code the appex runs.
#
#   ./Tests/run-menu-tests.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Tests/.build"
mkdir -p "$OUT"

echo "==> Compiling OpenInTerminalCore dylib"
# -import-objc-header replicates what Xcode does for the framework target:
# the umbrella header (OpenInTerminalCore.h) imports <Cocoa/Cocoa.h>, which is
# how files that only 'import Foundation' still see NSImage.
find OpenInTerminalCore -name '*.swift' | sort > "$OUT/core-sources.txt"
swiftc \
  -emit-library -emit-module \
  -module-name OpenInTerminalCore \
  -emit-module-path "$OUT/OpenInTerminalCore.swiftmodule" \
  -o "$OUT/libOpenInTerminalCore.dylib" \
  -import-objc-header OpenInTerminalCore/OpenInTerminalCore.h \
  @"$OUT/core-sources.txt" \
  -O

echo "==> Compiling menu test binary"
swiftc \
  -I "$OUT" -L "$OUT" -lOpenInTerminalCore \
  -framework FinderSync \
  OpenInTerminalFinderExtension/FinderSync.swift \
  Tests/MenuStructure/main.swift \
  -o "$OUT/menutest" \
  -O

echo "==> Running tests"
# OIT_CONFIG_PATH: test-local config.json (canonical config source)
# OIT_CATALOG_PATH: the repo's bundled catalog (no framework bundle here)
export OIT_CONFIG_PATH="$OUT/test-config.json"
export OIT_CATALOG_PATH="$PWD/OpenInTerminalCore/Resources/AppCatalog.json"
rm -f "$OUT/test-config.json"
DYLD_LIBRARY_PATH="$OUT" "$OUT/menutest"
