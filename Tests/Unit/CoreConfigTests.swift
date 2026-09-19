//
//  CoreConfigTests.swift
//  XCTest unit tests for the declarative configuration layer:
//  config.json model, JSON validation, catalog resolution, UserDefaults
//  migration, per-item option merging, and open recipes.
//
//  Run via Tests/run-unit-tests.sh (compiles this file as an .xctest bundle
//  against libOpenInTerminalCore and executes it with Xcode's xctest runner).
//
//  The runner sets OIT_CONFIG_PATH to a temp file and OIT_CATALOG_PATH to
//  the repo's AppCatalog.json.
//

import XCTest
import OpenInTerminalCore

final class ConfigModelTests: XCTestCase {

    private var configURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OIT_CONFIG_PATH"]!)
    }

    private func writeConfig(_ json: String) {
        try! json.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: decode / encode

    func testConfigDecodesAllSections() throws {
        let json = #"""
        {
          "version": 1,
          "defaultTerminal": "ghostty",
          "defaultEditor": "vscode",
          "general": {"launchAtLogin": true},
          "menu": {
            "pinDefaultTerminal": true,
            "items": [
              {"ref": "iterm2", "options": {"newInstance": "tab"}},
              {"app": {"name": "Foo", "type": "terminal"}},
              {"kind": "action", "action": "copyPath", "hidden": true}
            ]
          },
          "apps": [{"id": "x", "name": "X", "type": "editor",
                    "open": {"argv": ["-a", "X"]}}]
        }
        """#
        let cfg = try JSONDecoder().decode(OITConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.defaultTerminal, "ghostty")
        XCTAssertEqual(cfg.general?.launchAtLogin, true)
        XCTAssertEqual(cfg.menu?.items?.count, 3)
        XCTAssertEqual(cfg.menu?.items?[0].options?["newInstance"], .string("tab"))
        XCTAssertEqual(cfg.menu?.items?[1].app?.name, "Foo")
        XCTAssertEqual(cfg.menu?.items?[2].action, .copyPath)
        XCTAssertEqual(cfg.menu?.items?[2].hidden, true)
        XCTAssertEqual(cfg.apps?.first?.open.argv, ["-a", "X"])
    }

    func testConfigRoundTrip() throws {
        var cfg = OITConfig()
        cfg.defaultTerminal = "iterm2"
        cfg.menu = MenuConfig(items: [
            MenuItemConfig(ref: "iterm2", options: ["newInstance": .string("tab")]),
            MenuItemConfig(app: InlineAppDef(name: "A", type: .editor)),
        ])
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(OITConfig.self, from: data)
        XCTAssertEqual(cfg, back)
    }

    func testJSONValueCodable() throws {
        for v in [JSONValue.bool(true), .string("x"), .number(2.5)] {
            let data = try JSONEncoder().encode(v)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), v)
        }
    }

    // MARK: load + validate

    func testLoadMissingFileYieldsEmptyConfig() {
        try? FileManager.default.removeItem(at: configURL)
        let store = ConfigStore()
        XCTAssertTrue(store.config.menu?.items == nil || store.config.menu!.items!.isEmpty)
    }

    func testLoadParsesFile() {
        writeConfig(#"{"version":1,"menu":{"items":[{"ref":"iterm2"}]}}"#)
        let store = ConfigStore()
        store.load()
        XCTAssertEqual(store.config.menu?.items?.first?.ref, "iterm2")
    }

    func testLoadUnreadableFileRecordsIssue() {
        writeConfig("not json at all {{{")
        let store = ConfigStore()
        XCTAssertFalse(store.load())
        XCTAssertFalse(store.issues.isEmpty)
        XCTAssertEqual(store.config.version, 1)  // empty fallback, not a crash
    }

    func testValidateUnknownRef() {
        writeConfig(#"{"version":1,"menu":{"items":[{"ref":"nope-xyz"}]}}"#)
        let store = ConfigStore()
        store.load()
        XCTAssertTrue(store.issues.contains { $0.path.contains("ref") })
    }

    func testValidateUnknownOptionKey() {
        writeConfig(#"""
        {"version":1,"menu":{"items":[
            {"ref":"iterm2","options":{"bogus":true}}]}}
        """#)
        let store = ConfigStore()
        store.load()
        XCTAssertTrue(store.issues.contains { $0.message.contains("no option 'bogus'") })
    }

    func testValidateBadOptionValue() {
        writeConfig(#"""
        {"version":1,"menu":{"items":[
            {"ref":"iterm2","options":{"newInstance":"banana"}}]}}
        """#)
        let store = ConfigStore()
        store.load()
        XCTAssertTrue(store.issues.contains { $0.message.contains("invalid value") })
    }

    func testValidateItemNeedsExactlyOneSelector() {
        writeConfig(#"{"version":1,"menu":{"items":[{}]}}"#)
        let store = ConfigStore()
        store.load()
        XCTAssertTrue(store.issues.contains {
            $0.message.contains("exactly one of ref/app/kind") })
    }

    // MARK: resolved items

    func testResolvedItemsSkipUnresolvable() {
        writeConfig(#"""
        {"version":1,"menu":{"items":[
            {"ref":"nope"},{"ref":"iterm2"}]}}
        """#)
        let store = ConfigStore()
        store.load()
        let items = store.resolvedItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "iTerm")
    }

    func testResolvedItemKinds() {
        writeConfig(#"""
        {"version":1,"menu":{"items":[
            {"ref":"iterm2"},
            {"app":{"name":"Foo","type":"editor"}},
            {"kind":"action","action":"copyPath","label":"CP"}]}}
        """#)
        let store = ConfigStore()
        store.load()
        let items = store.resolvedItems()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[2].title, "CP")
        XCTAssertNil(items[2].app)
    }

    // MARK: item options merging

    func testItemOptionsMergeDefaultsAndOverrides() {
        writeConfig(#"""
        {"version":1,"menu":{"items":[
            {"ref":"iterm2"},
            {"ref":"iterm2","options":{"newInstance":"tab"}}]}}
        """#)
        let store = ConfigStore()
        store.load()
        XCTAssertEqual(store.itemOptions(at: 0)["newInstance"], .string("window"))
        XCTAssertEqual(store.itemOptions(at: 1)["newInstance"], .string("tab"))
    }

    func testSetItemOptionPersists() {
        writeConfig(#"{"version":1,"menu":{"items":[{"ref":"iterm2"}]}}"#)
        let store = ConfigStore()
        store.load()
        store.setItemOption(at: 0, optionId: "newInstance", value: .string("tab"))
        XCTAssertEqual(store.config.menu?.items?[0].options?["newInstance"],
                       .string("tab"))
        // written back to disk
        let onDisk = try! JSONDecoder().decode(
            OITConfig.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(onDisk.menu?.items?[0].options?["newInstance"],
                       .string("tab"))
    }
}

final class CatalogTests: XCTestCase {

    func testBundledCatalogLoads() {
        XCTAssertGreaterThan(AppCatalog.shared.apps.count, 30)
    }

    func testResolveByIdAndName() {
        XCTAssertEqual(AppCatalog.shared.resolve("iterm2")?.name, "iTerm")
        XCTAssertEqual(AppCatalog.shared.app(id: "iterm2")?.name, "iTerm")
        // by App value (name/bundleId)
        XCTAssertEqual(AppCatalog.shared.resolve(
            app: App(name: "iTerm", type: .terminal))?.id, "iterm2")
        XCTAssertNil(AppCatalog.shared.resolve("no-such-app-xyz"))
    }

    func testEveryBundledAppHasValidRecipe() {
        for app in AppCatalog.shared.apps {
            XCTAssertFalse(app.id.isEmpty, "app missing id")
            XCTAssertFalse(app.name.isEmpty, "app \(app.id) missing name")
            XCTAssertFalse(app.open.argv.isEmpty,
                           "app \(app.id) has empty argv")
        }
    }

    func testOptionDefinitionValidation() {
        let iterm = AppCatalog.shared.app(id: "iterm2")!
        let def = iterm.options?["newInstance"]
        XCTAssertNotNil(def)
        XCTAssertTrue(def!.isValidValue(.string("tab")))
        XCTAssertFalse(def!.isValidValue(.string("banana")))
        XCTAssertFalse(def!.isValidValue(.bool(true)))
        XCTAssertEqual(def?.default, .string("window"))
    }

    func testOpenRecipeOptionOverride() {
        // Terminal's "tab" choice overrides the recipe with a named script
        let terminal = AppCatalog.shared.app(id: "terminal")!
        let recipe = AppCatalog.shared.openRecipe(
            for: terminal, options: ["newInstance": .string("tab")])
        XCTAssertEqual(recipe.script, "terminalNewTabScript")
        let windowRecipe = AppCatalog.shared.openRecipe(
            for: terminal, options: ["newInstance": .string("window")])
        XCTAssertNil(windowRecipe.script)
    }

    func testUserAppsMergeAndReplace() {
        let catalog = AppCatalog(fileURL: URL(
            fileURLWithPath: ProcessInfo.processInfo
                .environment["OIT_CATALOG_PATH"]!))
        var custom = catalog.app(id: "kitty")!
        custom.open = OpenRecipe(argv: ["-a", "KittyCustom"])
        catalog.merge(userApps: [custom])
        XCTAssertEqual(catalog.app(id: "kitty")?.open.argv, ["-a", "KittyCustom"])
        // second merge restores bundled entries (no accumulation)
        catalog.merge(userApps: [])
        XCTAssertNotEqual(catalog.app(id: "kitty")?.open.argv, ["-a", "KittyCustom"])
    }

    func testLegacySupportedAppsAreInCatalog() {
        // spot-check the apps that had hardcoded open commands
        for name in ["Alacritty", "kitty", "WezTerm", "Tabby",
                     "Neovim", "GitKraken", "iTerm", "Terminal"] {
            XCTAssertNotNil(AppCatalog.shared.resolve(
                app: App(name: name, type: .terminal)),
                "\(name) missing from catalog")
        }
    }
}

final class DefaultsManagerRecipeTests: XCTestCase {

    private var suite: UserDefaults {
        UserDefaults(suiteName: "4ANN77GFL4.wang.jianing.app.OpenInTerminal")!
    }
    private let suiteName = "4ANN77GFL4.wang.jianing.app.OpenInTerminal"

    override func setUp() {
        super.setUp()
        suite.removePersistentDomain(forName: suiteName)
        if let p = ProcessInfo.processInfo.environment["OIT_CONFIG_PATH"] {
            try? FileManager.default.removeItem(atPath: p)
            ConfigStore.shared.load()
        }
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testGenericFallbackRecipe() {
        let recipe = DefaultsManager.shared.openRecipe(
            for: App(name: "NoCatalogMatchXYZ", type: .editor))
        XCTAssertEqual(recipe.argv, ["-a", "NoCatalogMatchXYZ"])
        XCTAssertEqual(recipe.pathMode, .append)
    }

    func testCatalogRecipeUsed() {
        let recipe = DefaultsManager.shared.openRecipe(
            for: App(name: "Alacritty", type: .terminal))
        XCTAssertEqual(recipe.argv,
                       ["-na", "Alacritty", "--args", "--working-directory"])
    }

    func testPlaceholderModeRecipe() {
        let recipe = DefaultsManager.shared.openRecipe(
            for: App(name: "Neovim", type: .editor))
        XCTAssertEqual(recipe.pathMode, .placeholder)
        XCTAssertTrue(recipe.argv.contains("{paths}"))
    }

    func testLegacyKittyCommandOverride() {
        suite.set("open -na kitty --args --override", forKey: "KittyCommand")
        let recipe = DefaultsManager.shared.openRecipe(
            for: App(name: "kitty", type: .terminal))
        XCTAssertEqual(recipe.argv,
                       ["-na", "kitty", "--args", "--override"])
    }

    func testDefaultTerminalResolution() {
        suite.set("Ghostty", forKey: "DefaultTerminal")
        XCTAssertEqual(DefaultsManager.shared.defaultTerminal?.name, "Ghostty")
    }
}

final class MigrationTests: XCTestCase {

    private var suite: UserDefaults {
        UserDefaults(suiteName: "4ANN77GFL4.wang.jianing.app.OpenInTerminal")!
    }
    private var configURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OIT_CONFIG_PATH"]!)
    }
    private let suiteName = "4ANN77GFL4.wang.jianing.app.OpenInTerminal"

    private func writeConfig(_ json: String) {
        try! json.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func testMigrationConvertsLegacyDefaults() throws {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: configURL)
        defer {
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: configURL)
        }

        suite.set("Ghostty", forKey: "DefaultTerminal")
        suite.set(true, forKey: "CustomMenuApplyToContext")
        suite.set(true, forKey: "ContextMenuPinDefaultTerminal")
        suite.set("tab", forKey: "iTermNewOption")
        suite.set(try JSONSerialization.data(withJSONObject: [
            ["name": "iTerm", "type": "terminal"],
            ["name": "FooCustom", "type": "editor"],
        ]), forKey: "CustomMenuOptions")

        let store = ConfigStore()   // init migrates when file is absent
        let cfg = store.config

        XCTAssertEqual(cfg.defaultTerminal, "ghostty")
        XCTAssertEqual(cfg.menu?.applyToContext, true)
        XCTAssertEqual(cfg.menu?.pinDefaultTerminal, true)
        let items = cfg.menu?.items ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].ref, "iterm2")
        // iTerm's legacy window/tab option carried onto the item
        XCTAssertEqual(items[0].options?["newInstance"], .string("tab"))
        // unknown app becomes an inline definition
        XCTAssertEqual(items[1].app?.name, "FooCustom")
        XCTAssertNil(items[1].ref)
        // marker prevents re-migration
        XCTAssertTrue(suite.bool(forKey: "ConfigMigrated"))
        // file exists on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testMigrationDoesNotOverwriteExistingFile() {
        writeConfig(#"{"version":1,"menu":{"items":[{"ref":"wezterm"}]}}"#)
        suite.removePersistentDomain(forName: suiteName)
        suite.set("iTerm", forKey: "DefaultTerminal")
        defer {
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: configURL)
        }

        let store = ConfigStore()
        XCTAssertEqual(store.config.menu?.items?.first?.ref, "wezterm")
    }
}
