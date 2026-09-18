# Fork Strategy — OpenInTerminal

This fork carries custom changes on top of
[Ji4n1ng/OpenInTerminal](https://github.com/Ji4n1ng/OpenInTerminal) using the
**revert-then-repatch** strategy, so `upstream/master` stays mergeable at all
times.

## Branch model

| Branch      | Tracks                        | Purpose                                     |
| ----------- | ----------------------------- | ------------------------------------------- |
| `main`      | Latest upstream release tag   | Stable — well-tested patches only           |
| `dev.patch` | `upstream/master`             | Unstable — experimental patches welcome     |
| `feature/*` | Branched from `dev.patch`     | Feature development (merged back to dev.patch) |

**Always branch from `dev.patch`**, never from `main` or `master`.
`master` mirrors upstream and carries no custom changes.

## Revert-then-repatch

The daily workflow `.github/workflows/sync-upstream-and-fix.yml` (07:00 UTC):

1. Reverts all `PATCHED_FILES` to upstream's version
   (`.github/scripts/revert_patched_files.sh`)
2. Merges upstream — fails loudly on non-patched file conflicts
3. Re-applies all `.github/patches/*.patch` in alphabetical order
   (`.github/scripts/apply_patches.sh`)
4. Commits and pushes

## Patch files

- One logical change per `.github/patches/NNN-description.patch`
- Zero-padded numbers — applied in alphabetical order
- Must be idempotent: `git apply --check` **or**
  `git apply --reverse --check` has to pass

| #   | Patch                                    | Files                                                                                     |
| --- | ---------------------------------------- | ----------------------------------------------------------------------------------------- |
| 001 | context-menu-pin-default-terminal        | `OpenInTerminalCore/Defaults.swift`, `DefaultsManager.swift`, `FinderSync.swift`          |
| 002 | macos12-deployment-target                | `build-unsigned.sh`                                                                        |

`PATCHED_FILES` lives in `.github/workflows/sync-upstream-and-fix.yml`
(env var) — keep it in sync with the patch contents.

## Adding a new patch

```bash
git checkout dev.patch
git checkout -b feature/my-change
# ... develop ...

# generate the patch from modified upstream files only
MERGE_BASE=$(git merge-base feature/my-change dev.patch)
git diff "$MERGE_BASE"..feature/my-change -- <modified-upstream-files> \
    > .github/patches/NNN-description.patch

# validate
git apply --check .github/patches/NNN-description.patch
git apply --reverse --check .github/patches/NNN-description.patch

# apply to dev.patch and commit
git checkout dev.patch
git apply .github/patches/NNN-description.patch
git add .github/patches/NNN-description.patch <files>
git commit -m "feat: integrate <description> via .patch"
```

New files (not in upstream) are committed directly — no patch needed.
Modified upstream files must be added to `PATCHED_FILES` in the workflow.

## Building

Unsigned local build (no Apple Developer account needed):

```bash
./build-unsigned.sh          # outputs ./export/*.app, ad-hoc signed
xattr -dr com.apple.quarantine export/OpenInTerminal.app
cp -R export/OpenInTerminal.app /Applications/
open /Applications/OpenInTerminal.app
```

Enable the Finder extension on macOS 15+:

```bash
pluginkit -mAD -p com.apple.FinderSync -vvv   # find the extension UUID
pluginkit -e "use" -u "<UUID>"
```

## Custom defaults (group container)

Settings live in the app-group suite:

```
~/Library/Group Containers/group.wang.jianing.app.OpenInTerminal/Library/Preferences/group.wang.jianing.app.OpenInTerminal.plist
```

Notable keys: `DefaultTerminal`, `DefaultEditor`, `ContextMenuUseSubmenu`,
`ContextMenuPinDefaultTerminal` (patch 001), `CustomMenuApplyToContext`,
`CustomMenuApplyToToolbar`, `CustomMenuOptions` (JSON-encoded `[App]`).
