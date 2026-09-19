# Agent Instructions — OpenInTerminal fork

## Read docs early and often — not only when stuck

Before implementing with any tool/API/CLI for the first time (tart,
FIFinderSync, CFPrefs, TCC, AppleScript AX, Virtualization.framework…),
read its documentation and check real API surfaces (`--help`, headers,
man pages). Proactively — to understand how something is *meant* to be
done — not only when blocked. Empirical trial-and-error is the fallback,
not the default. When reality contradicts the docs, record both.

## Fork model — read `.github/FORK-STRATEGY.md` first

- `dev.patch` = `upstream/master` + `.github/patches/*.patch` (applied in
  order). `main` tracks the latest upstream release tag.
- Modified **upstream** files must (a) be listed in `PATCHED_FILES` in
  `.github/workflows/sync-upstream-and-fix.yml` and (b) be captured by an
  incremental patch (`git diff <base> -- <file> > .github/patches/NNN-….patch`;
  validate with `git apply --reverse --check`).
- New files (everything under `Tests/`, `OpenInTerminalCore/Catalog.swift`,
  `ConfigStore.swift`, `Schemas/`, `Resources/AppCatalog.json`…) are
  committed directly — no patch.

## Configuration architecture

`config.json` in the app-group container is **canonical**
(`OpenInTerminalCore/ConfigStore.swift`); UserDefaults is legacy/migration
fallback only. `Resources/AppCatalog.json` is the declarative app recipe
catalog — prefer catalog changes over Swift changes for app support.
Schemas live in `Schemas/`. The appex reloads config on every `menu(for:)`.

## Build & test

```bash
SKIP_NOTARIZE=1 ./build-signed.sh   # signed build (notary profile absent)
./Tests/run-unit-tests.sh           # XCTest bundle — model/catalog/store
./Tests/run-menu-tests.sh           # integration: real FinderSync.swift
./Tests/e2e-finder.sh               # real Finder clicks, ~5s focus steal
./Tests/e2e-vm.sh                   # same suite inside the Tart guest (0 disturbance)
```

E2E prerequisites: signed app installed at `/Applications/OpenInTerminal.app`;
for the VM run, external drive mounted at `/Volumes/ExternalData` and
`e2e-base` provisioned (see `/Volumes/ExternalData/tart-test-infra/`).

## macOS automation gotchas learned here

- `CGEventPostToPid` mouse events are dropped by Finder (no window-server
  hit-testing) — real HID taps are required; keep focus-steal windows tiny.
- FinderSync toolbar button AX `name` is lazy (`missing value`); match by
  `description`. Finder window AX depth varies with sidebar/view — locate
  rows recursively, don't hardcode `splitter group 1 of splitter group 1`.
- App-group container root = `…/Group Containers/<group-id>/`, prefs at
  `Library/Preferences/` inside it — `config.json` sits at the root.
