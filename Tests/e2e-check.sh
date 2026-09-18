#!/bin/bash
#
# End-to-end verification of the OpenInTerminal Finder integration.
#
# Checks every link in the live chain:
#   1. appex signature (Developer ID, hardened runtime)
#   2. appex entitlements (sandbox + app group)
#   3. PlugInKit registration + enablement
#   4. extension process alive
#   5. sandboxed suite read (builds + signs the probe identically to the appex)
#   6. group-suite plist contents on disk
#   7. recent [OIT] menu() diagnostics from the running extension
#
#   ./Tests/e2e-check.sh
#
set -uo pipefail
cd "$(dirname "$0")/.."

APP="/Applications/OpenInTerminal.app"
APPEX="$APP/Contents/PlugIns/OpenInTerminalFinderExtension.appex"
EXT_ID="wang.jianing.app.OpenInTerminal.OpenInTerminalFinderExtension"
GROUP="group.wang.jianing.app.OpenInTerminal"
GROUP_PLIST="$HOME/Library/Group Containers/$GROUP/Library/Preferences/$GROUP.plist"
OUT="Tests/.build"
mkdir -p "$OUT"

PASS=0; FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
note() { echo "  ->  $1"; }

echo "== 1. appex signature"
SIG=$(codesign -dvv "$APPEX" 2>&1)
if echo "$SIG" | grep -q "Authority=Developer ID Application:"; then
    ok "appex signed with Developer ID"
    note "$(echo "$SIG" | grep 'Authority=Developer ID' | head -1)"
else
    bad "appex not Developer ID signed"; echo "$SIG" | head -8
fi
echo "$SIG" | grep -q "flags=.*runtime" && ok "hardened runtime enabled" || note "hardened runtime flag not found"

echo "== 2. appex entitlements"
ENT=$(codesign -d --entitlements - "$APPEX" 2>/dev/null)
echo "$ENT" | grep -q "com.apple.security.app-sandbox" \
    && ok "app-sandbox present" || bad "app-sandbox missing"
echo "$ENT" | grep -q "application-groups" \
    && ok "application-groups present" || bad "application-groups missing"

echo "== 3. PlugInKit registration + enablement"
PK=$(pluginkit -mAD -p com.apple.FinderSync 2>/dev/null | grep "$EXT_ID")
if [ -n "$PK" ]; then
    case "$PK" in
        +*) ok "extension registered and ENABLED" ;;
        -*) bad "extension registered but DISABLED" ;;
        *)  note "extension registered (unknown state): $PK" ;;
    esac
else
    bad "extension not registered in pluginkit"
fi

echo "== 4. extension process"
if pgrep -fl OpenInTerminalFinderExtension | grep -q "$APPEX"; then
    ok "extension process running from /Applications"
else
    note "extension not running (Finder starts it on demand)"
fi

echo "== 5. sandboxed suite probe"
SIGN_ID=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n1)
if [ -z "$SIGN_ID" ]; then
    note "no Developer ID identity — skipping probe"
else
    PROBE="$OUT/probe.app"
    mkdir -p "$PROBE/Contents/MacOS"
    cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>wang.jianing.app.OpenInTerminal.probe</string>
	<key>CFBundleExecutable</key><string>probe</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
    cat > "$OUT/probe-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.app-sandbox</key><true/>
	<key>com.apple.security.application-groups</key>
	<array><string>group.wang.jianing.app.OpenInTerminal</string></array>
</dict></plist>
PLIST
    swiftc -O -o "$PROBE/Contents/MacOS/probe" Tests/SandboxedPrefsProbe/probe.swift
    codesign --force --options runtime --sign "$SIGN_ID" \
        --entitlements "$OUT/probe-entitlements.plist" "$PROBE" >/dev/null 2>&1
    if timeout 20 "$PROBE/Contents/MacOS/probe" > "$OUT/probe-output.txt" 2>&1; then
        ok "sandboxed probe read the app-group suite"
    else
        bad "sandboxed probe failed (exit $?)"
    fi
    sed 's/^/  ->  /' "$OUT/probe-output.txt"
fi

echo "== 6. group-suite plist on disk"
if [ -f "$GROUP_PLIST" ]; then
    ok "group plist exists"
    plutil -p "$GROUP_PLIST" | sed 's/^/  ->  /'
else
    bad "group plist missing: $GROUP_PLIST"
fi

echo "== 7. recent [OIT] diagnostics from the extension (last 10 min)"
LINES=$(log show --last 10m --predicate 'process == "OpenInTerminalFinderExtension"' 2>/dev/null | grep '\[OIT\]' | tail -10)
if [ -n "$LINES" ]; then
    echo "$LINES" | sed 's/^/  ->  /'
    ok "extension produced menu() diagnostics"
else
    note "no [OIT] lines yet — right-click a Finder item, then re-run this script"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
