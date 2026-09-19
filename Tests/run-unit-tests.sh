#!/bin/bash
# Builds libOpenInTerminalCore + an XCTest bundle for the unit tests in
# Tests/Unit, then runs it with Xcode's xctest runner.
#
# Env overrides keep the tests hermetic:
#   OIT_CONFIG_PATH  – config.json lives in a temp dir, never the real one
#   OIT_CATALOG_PATH – the repo's catalog (no framework bundle in tests)
set -e
cd "$(dirname "$0")/.."

OUT=/tmp/openinterminal-unittests
mkdir -p "$OUT"

DEVELOPER_DIR=$(xcode-select -p)
FRAMEWORKS_DIR="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"

if [ ! -f "$OUT/libOpenInTerminalCore.dylib" ]; then
  echo "==> Compiling OpenInTerminalCore dylib"
  swiftc -emit-library -emit-module -module-name OpenInTerminalCore \
    -import-objc-header OpenInTerminalCore/OpenInTerminalCore.h \
    OpenInTerminalCore/*.swift OpenInTerminalCore/*/*.swift \
    -o "$OUT/libOpenInTerminalCore.dylib" \
    -emit-module-path "$OUT/OpenInTerminalCore.swiftmodule" -O
fi

echo "==> Compiling XCTest bundle"
BUNDLE="$OUT/CoreConfigTests.xctest"
mkdir -p "$BUNDLE/Contents/MacOS"
swiftc -emit-library -emit-module -module-name CoreConfigTests \
  -I "$OUT" -L "$OUT" -lOpenInTerminalCore \
  -I "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib" \
  -L "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib" \
  -F "$FRAMEWORKS_DIR" -framework XCTest \
  Tests/Unit/*.swift \
  -o "$BUNDLE/Contents/MacOS/CoreConfigTests" -O

cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>wang.jianing.app.OpenInTerminal.CoreConfigTests</string>
  <key>CFBundleExecutable</key><string>CoreConfigTests</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict>
</plist>
EOF

echo "==> Running unit tests"
export OIT_CONFIG_PATH="$OUT/test-config.json"
export OIT_CATALOG_PATH="$PWD/OpenInTerminalCore/Resources/AppCatalog.json"
export DYLD_FRAMEWORK_PATH="$FRAMEWORKS_DIR"
rm -f "$OIT_CONFIG_PATH"

DYLD_LIBRARY_PATH="$OUT" "$DEVELOPER_DIR/usr/bin/xctest" "$BUNDLE"
