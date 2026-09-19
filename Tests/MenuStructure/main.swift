//
//  MenuStructureTests
//  Automated verification of the Finder context-menu structure.
//
//  Compiles the real OpenInTerminalFinderExtension/FinderSync.swift against
//  OpenInTerminalCore and asserts the menu hierarchy produced for each
//  configuration scenario. Run via Tests/run-menu-tests.sh.
//
//  Scenarios are driven through config.json (canonical, OIT_CONFIG_PATH env)
//  plus legacy UserDefaults fallback cases (pre-migration behaviour).
//

import Cocoa
import OpenInTerminalCore

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

func titles(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
}

// MARK: - Injection helpers
//
// OIT_CONFIG_PATH (set by run-menu-tests.sh) points ConfigStore at a temp
// config.json; OIT_CATALOG_PATH points AppCatalog at the repo's catalog.
// UserDefaults(suiteName:) resolves to ~/Library/Preferences/<suite>.plist
// in this non-sandboxed process — the domain is removed afterwards.

let suiteName = "4ANN77GFL4.wang.jianing.app.OpenInTerminal"
let suite = UserDefaults(suiteName: suiteName)!
let configPath = ProcessInfo.processInfo.environment["OIT_CONFIG_PATH"]!
let configURL = URL(fileURLWithPath: configPath)

/// Resets all state and installs the given config.json content (or removes
/// the file entirely when json == nil, exercising the Defaults fallback).
func inject(configJSON json: String?, defaults: [String: Any] = [:]) {
    suite.removePersistentDomain(forName: suiteName)
    // prevent ConfigStore.init from migrating the (test) suite into the file
    suite.set(true, forKey: "ConfigMigrated")
    for (k, v) in defaults { suite.set(v, forKey: k) }
    if let json {
        try! json.write(to: configURL, atomically: true, encoding: .utf8)
    } else {
        try? FileManager.default.removeItem(at: configURL)
    }
    ConfigStore.shared.load()
}

/// A config.json document with the given menu flags + item refs.
func configDoc(
    items: String,
    pinDefault: Bool = true,
    useSubmenu: Bool = true,
    applyToContext: Bool = true,
    applyToToolbar: Bool = true,
    hideContextItems: Bool = false
) -> String {
    """
    {
      "version": 1,
      "defaultTerminal": "ghostty",
      "defaultEditor": "vscode",
      "menu": {
        "pinDefaultTerminal": \(pinDefault),
        "useSubmenu": \(useSubmenu),
        "applyToContext": \(applyToContext),
        "applyToToolbar": \(applyToToolbar),
        "hideContextMenuItems": \(hideContextItems),
        "items": [ \(items) ]
      }
    }
    """
}

let terminals = """
    {"ref": "iterm2"},
    {"ref": "wezterm"},
    {"ref": "alacritty"}
    """

let finderSync = FinderSync()

// MARK: - Scenario 1: pinned default + submenu (the target layout)

inject(configJSON: configDoc(items: terminals))
var menu = finderSync.menu(for: .contextualMenuForItems)

check(menu.items.count == 3, "context menu: 3 top-level items")
check(menu.items.first?.title == "Ghostty",
      "context menu: first item is the default terminal (Ghostty)")
check(menu.items.count > 1 && menu.items[1].isSeparatorItem,
      "context menu: separator below pinned terminal")
check(menu.items.last?.submenu != nil,
      "context menu: last item carries a submenu")
if let submenu = menu.items.last?.submenu {
    check(submenu.items.count == 4,
          "submenu: 3 terminals + Copy Path")
    check(submenu.items[0].title == "iTerm"
          && submenu.items[1].title == "WezTerm"
          && submenu.items[2].title == "Alacritty",
          "submenu: terminal order preserved \(titles(submenu))")
}
check(menu.items.first?.action == #selector(FinderSync.openDefaultTerminal),
      "context menu: pinned item triggers openDefaultTerminal")

// MARK: - Scenario 2: same config, toolbar menu (never grouped)

menu = finderSync.menu(for: .toolbarItemMenu)
check(menu.items.count == 6,
      "toolbar menu: pinned terminal + separator + 3 customs + Copy Path")
check(menu.items.first?.title == "Ghostty",
      "toolbar menu: first item is Ghostty")

// MARK: - Scenario 3: custom menu without pinning (upstream behavior)

inject(configJSON: configDoc(items: terminals, pinDefault: false))
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.count == 1 && menu.items[0].submenu != nil,
      "unpinned + submenu: single 'Open in...' top-level item")
if let submenu = menu.items[0].submenu {
    check(submenu.items.count == 4, "unpinned submenu: customs + Copy Path")
}

// MARK: - Scenario 4: custom menu flat (no submenu, no pin)

inject(configJSON: configDoc(items: terminals, pinDefault: false, useSubmenu: false))
menu = finderSync.menu(for: .contextualMenuForItems)
check(titles(menu) == ["iTerm", "WezTerm", "Alacritty", titles(menu).last!],
      "flat custom menu: terminals + Copy Path at top level \(titles(menu))")
check(menu.items.count == 4, "flat custom menu: 4 items")

// MARK: - Scenario 5: no custom menu -> default menu path

inject(configJSON: configDoc(items: "", applyToContext: false))
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.first?.title == "Ghostty",
      "default menu: first item is the default terminal")
check(menu.items.contains { $0.submenu != nil },
      "default menu: remaining items grouped under submenu")

// MARK: - Scenario 6: empty items -> empty custom menu

inject(configJSON: configDoc(items: ""))
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.isEmpty,
      "config with no items -> empty menu")

// MARK: - Scenario 7: hide flag -> empty menu

inject(configJSON: configDoc(items: terminals, hideContextItems: true))
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.isEmpty, "HideContextMenuItems -> empty menu")

// MARK: - Scenario 8: per-item options — iTerm window/tab via config item

inject(configJSON: configDoc(items: """
    {"ref": "iterm2", "options": {"newInstance": "tab"}},
    {"ref": "wezterm"}
    """))
do {
    let opt = DefaultsManager.shared.getNewOption(.iTerm)
    check(opt == .tab, "per-item option: iTerm newInstance=tab resolves")
}

// MARK: - Scenario 9: catalog open recipes

do {
    let recipe = DefaultsManager.shared.openRecipe(for: App(name: "Alacritty", type: .terminal))
    check(recipe.argv == ["-na", "Alacritty", "--args", "--working-directory"],
          "catalog recipe: Alacritty argv")
    check(recipe.pathMode == .appendFirst, "catalog recipe: terminal pathMode=appendFirst")
    let generic = DefaultsManager.shared.openRecipe(for: App(name: "Ghostty", type: .terminal))
    check(generic.argv == ["-a", "Ghostty"], "catalog recipe: generic open -a")
    let neo = DefaultsManager.shared.openRecipe(for: App(name: "Neovim", type: .editor))
    check(neo.pathMode == .placeholder && neo.argv.contains("{paths}"),
          "catalog recipe: Neovim placeholder mode")
}

// MARK: - Scenario 10: user-defined app entry + inline custom app

inject(configJSON: """
    {
      "version": 1,
      "defaultTerminal": "ghostty",
      "menu": {
        "applyToContext": true,
        "items": [
          {"ref": "myterm"},
          {"app": {"name": "FooTerm", "type": "terminal"}},
          {"kind": "action", "action": "copyPath"}
        ]
      },
      "apps": [
        {"id": "myterm", "name": "MyTerm", "type": "terminal",
         "bundleId": "com.example.myterm",
         "open": {"argv": ["-na", "MyTerm", "--args", "--cwd"]}}
      ]
    }
    """)
do {
    // force re-merge of user apps for this scenario
    let items = ConfigStore.shared.resolvedItems()
    check(items.count == 3, "user app + inline app + action item resolve")
    check(items[0].title == "MyTerm", "user-defined catalog app resolves")
    check(items[0].openRecipe.argv == ["-na", "MyTerm", "--args", "--cwd"],
          "user-defined open recipe applies")
    check(items[1].title == "FooTerm", "inline custom app resolves")
    check(items[1].openRecipe.argv == ["-a", "FooTerm"],
          "inline app default recipe")
    menu = finderSync.menu(for: .contextualMenuForItems)
    check(menu.items.count >= 3, "menu renders custom+inline+action items")
}

// MARK: - Scenario 11: invalid config -> validation issues, graceful fallback

inject(configJSON: """
    {
      "version": 1,
      "menu": {"applyToContext": true, "items": [
        {"ref": "nonexistent-app"},
        {"ref": "iterm2", "options": {"bogusOption": true}}
      ]}
    }
    """)
do {
    check(!ConfigStore.shared.issues.isEmpty,
          "invalid refs/options produce validation issues")
    let items = ConfigStore.shared.resolvedItems()
    check(items.count == 1 && items[0].title == "iTerm",
          "unresolvable item skipped, valid item kept")
}

// MARK: - Scenario 12: legacy plist fallback (no config.json)

inject(configJSON: nil, defaults: [
    "DefaultTerminal": "Ghostty",
    "CustomMenuApplyToContext": true,
    "ContextMenuPinDefaultTerminal": true,
    "ContextMenuUseSubmenu": true,
    "CustomMenuOptions": try! JSONSerialization.data(withJSONObject: [
        ["name": "iTerm", "type": "terminal"],
        ["name": "WezTerm", "type": "terminal"],
    ]),
])
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.first?.title == "Ghostty",
      "plist fallback: pinned terminal still works without config.json")
check(menu.items.count == 3,
      "plist fallback: custom items from legacy CustomMenuOptions")

// cleanup
suite.removePersistentDomain(forName: suiteName)
try? FileManager.default.removeItem(at: configURL)

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
