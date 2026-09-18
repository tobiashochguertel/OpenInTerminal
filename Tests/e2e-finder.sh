#!/bin/bash
#
# Fully automated GUI end-to-end test for the OpenInTerminal FinderSync
# extension. Triggers REAL Finder context-menu and toolbar menu() calls via
# accessibility automation, then asserts on the extension's os_log output.
#
#   ./Tests/e2e-finder.sh             # static checks + GUI triggers
#   ./Tests/e2e-finder.sh --gui-only  # skip the static e2e-check.sh phase
#   RUN_GUI_E2E=0 ./Tests/e2e-finder.sh   # static checks only (CI/headless)
#
# Requirements for the GUI phase:
#   - a logged-in GUI session with Finder running
#   - accessibility permission for the invoking terminal app
#     (System Settings > Privacy & Security > Accessibility)
#   - the signed app installed at /Applications/OpenInTerminal.app
#
# The test directory is ~/Library/oit-e2e — deliberately NOT inside Desktop,
# Documents, iCloud Drive, or third-party cloud-sync folders, because macOS
# suppresses FinderSync extensions there (rdar FB13109005 and the
# one-extension-per-directory rule).
#
set -uo pipefail
cd "$(dirname "$0")/.."

APP="/Applications/OpenInTerminal.app"
APPEX="$APP/Contents/PlugIns/OpenInTerminalFinderExtension.appex"
EXT_ID="wang.jianing.app.OpenInTerminal.OpenInTerminalFinderExtension"
GROUP="4ANN77GFL4.wang.jianing.app.OpenInTerminal"
GROUP_PLIST="$HOME/Library/Group Containers/$GROUP/Library/Preferences/$GROUP.plist"
TEST_DIR="$HOME/Library/oit-e2e"
TEST_FILE="testfile.txt"
OUT="Tests/.build"
LOG_PREDICATE='subsystem == "wang.jianing.app.OpenInTerminal"'
mkdir -p "$OUT"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP+1)); }
note() { echo "  ->  $1"; }

# ---------------------------------------------------------------------------
# Phase 0: static chain checks (delegates to e2e-check.sh)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--gui-only" ]; then
    echo "== static chain checks (Tests/e2e-check.sh)"
    if ./Tests/e2e-check.sh; then
        ok "static chain checks"
    else
        bad "static chain checks — fix these first"
        echo; echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
        exit 1
    fi
fi

if [ "${RUN_GUI_E2E:-1}" = "0" ]; then
    skip "GUI phase disabled (RUN_GUI_E2E=0)"
    echo; echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" -eq 0 ]
    exit $?
fi

if ! pgrep -x Finder >/dev/null; then
    bad "no GUI session / Finder not running — GUI phase cannot run headless"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1: deterministic preferences in the team-prefixed app group
# ---------------------------------------------------------------------------
echo "== 1. seed deterministic preferences"
mkdir -p "$(dirname "$GROUP_PLIST")"
cat > "$OUT/expected-prefs.json" <<'JSON'
[{"name": "iTerm", "type": "terminal"}, {"name": "WezTerm", "type": "terminal"}, {"name": "Alacritty", "type": "terminal"}]
JSON

if [ ! -f "$GROUP_PLIST" ]; then
    defaults write "$GROUP" FirstSetup -bool true 2>/dev/null
fi

# Write via defaults first so cfprefsd stays consistent; verify on disk.
defaults write "$GROUP" DefaultTerminal -string "Ghostty"
defaults write "$GROUP" ContextMenuPinDefaultTerminal -bool true
defaults write "$GROUP" ContextMenuUseSubmenu -bool true
defaults write "$GROUP" CustomMenuApplyToContext -bool true
defaults write "$GROUP" CustomMenuApplyToToolbar -bool true
defaults write "$GROUP" HideContextMenuItems -bool false
defaults write "$GROUP" CustomMenuOptions -data "$(xxd -p -c 4096 "$OUT/expected-prefs.json" | tr -d ' \n')"

sleep 0.5
if [ -f "$GROUP_PLIST" ] && plutil -p "$GROUP_PLIST" | grep -q '"DefaultTerminal" => "Ghostty"'; then
    ok "preferences seeded in app-group suite"
else
    # fall back to writing the plist directly and flushing cfprefsd
    note "defaults did not land in group plist — writing directly"
    plutil -replace DefaultTerminal -string "Ghostty" "$GROUP_PLIST" 2>/dev/null
    plutil -replace ContextMenuPinDefaultTerminal -bool true "$GROUP_PLIST"
    plutil -replace ContextMenuUseSubmenu -bool true "$GROUP_PLIST"
    plutil -replace CustomMenuApplyToContext -bool true "$GROUP_PLIST"
    plutil -replace CustomMenuApplyToToolbar -bool true "$GROUP_PLIST"
    plutil -replace HideContextMenuItems -bool false "$GROUP_PLIST"
    plutil -replace CustomMenuOptions -data "$(xxd -p -c 4096 "$OUT/expected-prefs.json" | tr -d ' \n')" "$GROUP_PLIST"
    killall cfprefsd 2>/dev/null
    sleep 0.5
    plutil -p "$GROUP_PLIST" | grep -q '"DefaultTerminal" => "Ghostty"' \
        && ok "preferences seeded (direct plist write)" \
        || bad "could not seed group preferences"
fi

# ---------------------------------------------------------------------------
# Phase 2: prepare test directory, helper, and log baseline
# ---------------------------------------------------------------------------
echo "== 2. prepare test directory + click helper"
mkdir -p "$TEST_DIR"
touch "$TEST_DIR/$TEST_FILE"

CLICK="$OUT/rightclick"
if [ ! -x "$CLICK" ] || [ "Tests/RightClickHelper/rightclick.swift" -nt "$CLICK" ]; then
    swiftc -O -o "$CLICK" Tests/RightClickHelper/rightclick.swift 2>/dev/null || rm -f "$CLICK"
fi
if [ ! -x "$CLICK" ]; then
    CLICK="$(command -v cliclick || true)"
fi
if [ -z "$CLICK" ]; then
    bad "no right-click helper (swiftc failed, cliclick not installed)"
    exit 1
fi
ok "click helper ready: $CLICK"

rightclick() {
    if [ "$(basename "$CLICK")" = "cliclick" ]; then
        "$CLICK" "rc:$1,$2" >/dev/null 2>&1
    else
        "$CLICK" "$1" "$2" >/dev/null 2>&1
    fi
}

# host app must have run once for FinderSync activation; extension spawns on demand
open -a "$APP" 2>/dev/null
sleep 1

START_TS=$(date '+%Y-%m-%d %H:%M:%S')
note "log window starts at $START_TS"

# ---------------------------------------------------------------------------
# Phase 3: real context-menu trigger
# ---------------------------------------------------------------------------
echo "== 3. trigger Finder context menu (kind=0)"
osascript <<'EOF' >/dev/null 2>&1
tell application "Finder"
    activate
    open folder "oit-e2e" of folder "Library" of home
    delay 1
    try
        set current view of front Finder window to list view
    end try
    select file "testfile.txt" of folder "oit-e2e" of folder "Library" of home
end tell
EOF
sleep 1

# locate the file row and its screen coordinates
COORDS=$(osascript <<'EOF' 2>/dev/null
tell application "System Events"
    tell process "Finder"
        set ol to outline 1 of scroll area 1 of splitter group 1 of splitter group 1 of window "oit-e2e"
        repeat with r in rows of ol
            try
                if value of text field 1 of UI element 1 of r is "testfile.txt" then
                    set p to position of r
                    set s to size of r
                    return (item 1 of p) & " " & (item 2 of p) & " " & (item 1 of s) & " " & (item 2 of s)
                end if
            end try
        end repeat
    end tell
end tell
EOF
)

COORDS=$(echo "$COORDS" | tr -d ',')
if [ -z "$COORDS" ]; then
    bad "could not locate '$TEST_FILE' row in Finder window (accessibility permission?)"
else
    read -r RX RY RW RH <<< "$COORDS"
    CX=$((RX + 120)); CY=$((RY + RH / 2))
    note "right-clicking '$TEST_FILE' at $CX,$CY (row $RX,$RY ${RW}x${RH})"
    rightclick "$CX" "$CY"
    sleep 2
    # dismiss whatever menu opened
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1

    CTX_LOG=$(log show --start "$START_TS" --predicate "$LOG_PREDICATE" 2>/dev/null | grep 'menu kind=0 ->' | tail -1)
    if [ -n "$CTX_LOG" ]; then
        note "$CTX_LOG"
        ITEMS=$(echo "$CTX_LOG" | sed -n 's/.*menu kind=0 -> \([0-9]*\) items.*/\1/p')
        if [ "${ITEMS:-0}" -gt 0 ]; then
            ok "context menu returned $ITEMS items"
            echo "$CTX_LOG" | grep -q "Ghostty" \
                && ok "context menu contains pinned default terminal (Ghostty)" \
                || bad "context menu missing Ghostty"
            echo "$CTX_LOG" | grep -qi "Open in" \
                && ok "context menu contains submenu" \
                || bad "context menu missing submenu"
        else
            bad "context menu() called but returned 0 items"
        fi
    else
        bad "menu kind=0 never logged — Finder did not query the extension"
        note "check: is $TEST_DIR under a cloud-sync path? is another FinderSync extension claiming it?"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 4: real toolbar-menu trigger
# ---------------------------------------------------------------------------
echo "== 4. trigger Finder toolbar menu (kind=3)"
osascript <<'EOF' >/dev/null 2>&1
tell application "System Events"
    tell process "Finder"
        click menu button "Open in Terminal" of toolbar 1 of window "oit-e2e"
    end tell
end tell
EOF
sleep 2
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1

TB_LOG=$(log show --start "$START_TS" --predicate "$LOG_PREDICATE" 2>/dev/null | grep 'menu kind=3 ->' | tail -1)
if [ -n "$TB_LOG" ]; then
    note "$TB_LOG"
    ITEMS=$(echo "$TB_LOG" | sed -n 's/.*menu kind=3 -> \([0-9]*\) items.*/\1/p')
    if [ "${ITEMS:-0}" -gt 0 ]; then
        ok "toolbar menu returned $ITEMS items"
        echo "$TB_LOG" | grep -q "Ghostty" \
            && ok "toolbar menu contains Ghostty" \
            || bad "toolbar menu missing Ghostty"
        echo "$TB_LOG" | grep -q "iTerm" \
            && ok "toolbar menu contains custom terminals" \
            || bad "toolbar menu missing custom terminals"
    else
        bad "toolbar menu() called but returned 0 items"
    fi
else
    bad "menu kind=3 never logged — toolbar button missing or never clicked"
    note "the 'Open in Terminal' toolbar item must be added to the Finder toolbar once"
fi

# ---------------------------------------------------------------------------
# Phase 5: no sandbox/preference denials during the run
# ---------------------------------------------------------------------------
echo "== 5. check for denials during this run"
DENIALS=$(log show --start "$START_TS" --predicate 'process == "OpenInTerminalFinderExtension"' 2>/dev/null \
    | grep -iE "deny|denied|REJECTED|requires user-preference-read|file-read-data" | tail -5)
if [ -z "$DENIALS" ]; then
    ok "no sandbox / TCC / CFPrefs denials from the extension"
else
    bad "denials detected during run"
    echo "$DENIALS" | sed 's/^/  ->  /'
fi

# ---------------------------------------------------------------------------
echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
