#!/bin/bash
#
# e2e-vm.sh — run the Finder GUI e2e inside the shared Tart test VM.
# Zero host-side disturbance: all clicks, focus changes and menus happen
# inside the guest.
#
#   ./Tests/e2e-vm.sh                 # full run (static checks + GUI)
#   ./Tests/e2e-vm.sh --gui-only      # skip static host checks
#
# Prereqs:
#   - external drive mounted at /Volumes/ExternalData
#   - e2e-base VM provisioned (vmtest.py provision)
#   - signed app built + installed on the HOST at /Applications/OpenInTerminal.app
#     (the host bundle is mounted read-only into the guest and copied to the
#     guest's /Applications before the test run)
#
set -euo pipefail
cd "$(dirname "$0")/.."

VMTEST="/Volumes/ExternalData/tart-test-infra/scripts/vmtest.py"
VM="e2e-base"
APP="/Applications/OpenInTerminal.app"
SHARE="/Volumes/My Shared Files"

[ -x "$VMTEST" ] || { echo "test infra not mounted ($VMTEST missing)"; exit 1; }
[ -d "$APP" ]    || { echo "signed app missing: $APP — run the signed build first"; exit 1; }

# Mount the repo rw. The app travels as a zip through the share — virtiofs
# cannot resolve framework symlinks (Versions/Current) when copying a bundle
# directly, so cp/ditto on the mount point corrupts it.
mkdir -p Tests/.build
ditto -c -k --keepParent "$APP" Tests/.build/OpenInTerminal.app.zip

"$VMTEST" start "$VM" --dir "repo:$(pwd)"

echo "== installing app inside guest"
"$VMTEST" ssh "$VM" -- bash -lc "
    rm -rf /Applications/OpenInTerminal.app /tmp/oit.zip
    cp '$SHARE/repo/Tests/.build/OpenInTerminal.app.zip' /tmp/oit.zip
    ditto -x -k /tmp/oit.zip /Applications/
    xattr -dr com.apple.quarantine /Applications/OpenInTerminal.app 2>/dev/null || true
    codesign --verify --deep /Applications/OpenInTerminal.app && echo 'signature OK'
    open -g -a /Applications/OpenInTerminal.app || true
"

echo "== running e2e inside guest (all GUI effects stay in the VM)"
"$VMTEST" ssh "$VM" -- bash -lc "cd '$SHARE/repo' && ./Tests/e2e-finder.sh ${1:-}"
