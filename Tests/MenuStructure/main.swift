//
//  MenuStructureTests
//  Automated verification of the Finder context-menu structure.
//
//  Compiles the real OpenInTerminalFinderExtension/FinderSync.swift against
//  OpenInTerminalCore and asserts the menu hierarchy produced for each
//  combination of the relevant defaults. Run via Tests/run-menu-tests.sh.
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

// MARK: - Defaults injection
//
// In this non-sandboxed test process UserDefaults(suiteName:) resolves to
// ~/Library/Preferences/<suite>.plist. The extension resolves the same suite
// to the app-group container — the code path under test is identical.
// We remove the domain afterwards so the file is not left behind.

// Constants.Id.Group is internal to OpenInTerminalCore; use the literal.
let suiteName = "4ANN77GFL4.wang.jianing.app.OpenInTerminal"
let suite = UserDefaults(suiteName: suiteName)!

func injectDefaults(
    customApps: [[String: String]]?,
    defaultTerminal: String? = "Ghostty",
    defaultEditor: String? = "Visual Studio Code",
    pinDefault: Bool = true,
    useSubmenu: Bool = true,
    customApplyToContext: Bool = true,
    customApplyToToolbar: Bool = true,
    hideContextItems: Bool = false
) {
    suite.removePersistentDomain(forName: suiteName)
    suite.set(false, forKey: "FirstSetup")  // keep firstSetup() from resetting
    suite.set(defaultTerminal, forKey: "DefaultTerminal")
    suite.set(defaultEditor, forKey: "DefaultEditor")
    suite.set(pinDefault, forKey: "ContextMenuPinDefaultTerminal")
    suite.set(useSubmenu, forKey: "ContextMenuUseSubmenu")
    suite.set(customApplyToContext, forKey: "CustomMenuApplyToContext")
    suite.set(customApplyToToolbar, forKey: "CustomMenuApplyToToolbar")
    suite.set(hideContextItems, forKey: "HideContextMenuItems")
    suite.set("original", forKey: "CustomMenuIconOption")
    if let customApps {
        let data = try! JSONSerialization.data(withJSONObject: customApps)
        suite.set(data, forKey: "CustomMenuOptions")
    }
}

let customTerminals = [
    ["name": "iTerm", "bundleId": "com.googlecode.iterm2", "type": "terminal"],
    ["name": "WezTerm", "bundleId": "com.github.wez.wezterm", "type": "terminal"],
    ["name": "Alacritty", "bundleId": "io.alacritty", "type": "terminal"],
]

let finderSync = FinderSync()

// MARK: - Scenario 1: pinned default + submenu (the target layout)

injectDefaults(customApps: customTerminals)
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

injectDefaults(customApps: customTerminals, pinDefault: false)
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.count == 1 && menu.items[0].submenu != nil,
      "unpinned + submenu: single 'Open in...' top-level item")
if let submenu = menu.items[0].submenu {
    check(submenu.items.count == 4, "unpinned submenu: customs + Copy Path")
}

// MARK: - Scenario 4: custom menu flat (no submenu, no pin)

injectDefaults(customApps: customTerminals, pinDefault: false, useSubmenu: false)
menu = finderSync.menu(for: .contextualMenuForItems)
check(titles(menu) == ["iTerm", "WezTerm", "Alacritty", titles(menu).last!],
      "flat custom menu: terminals + Copy Path at top level \(titles(menu))")
check(menu.items.count == 4, "flat custom menu: 4 items")

// MARK: - Scenario 5: no custom menu -> default menu path

injectDefaults(customApps: nil, customApplyToContext: false)
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.first?.title == "Ghostty",
      "default menu: first item is the default terminal")
check(menu.items.contains { $0.submenu != nil },
      "default menu: remaining items grouped under submenu")

// MARK: - Scenario 6: decode failure -> empty menu (the bug we debugged)

suite.removePersistentDomain(forName: suiteName)
suite.set(Data("not json".utf8), forKey: "CustomMenuOptions")
suite.set(true, forKey: "CustomMenuApplyToContext")
suite.set(true, forKey: "ContextMenuUseSubmenu")
suite.set(true, forKey: "ContextMenuPinDefaultTerminal")
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.isEmpty,
      "corrupt CustomMenuOptions -> empty menu (guard bail)")

// MARK: - Scenario 7: hide flag -> empty menu

injectDefaults(customApps: customTerminals, hideContextItems: true)
menu = finderSync.menu(for: .contextualMenuForItems)
check(menu.items.isEmpty, "HideContextMenuItems -> empty menu")

// cleanup
suite.removePersistentDomain(forName: suiteName)

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
