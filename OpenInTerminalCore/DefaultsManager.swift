//
//  DefaultsManager.swift
//  OpenInTerminalCore
//
//  Created by Jianing Wang on 2019/10/14.
//  Copyright © 2019 Jianing Wang. All rights reserved.
//

import Foundation

public class DefaultsManager {
    
    public static var shared = DefaultsManager()
    
    // MARK: - Preferences - General
    
    public var isFirstSetup: Bool {
        get {
            return Defaults[.firstSetup]
        }
        
        set {
            Defaults[.firstSetup] = newValue
        }
    }
    
    public var isLaunchAtLogin: Bool {
        get {
            return Defaults[.launchAtLogin]
        }
        
        set {
            Defaults[.launchAtLogin] = newValue
        }
    }
    
    public var isQuickToggle: Bool {
        get {
            return Defaults[.quickToggle]
        }
        
        set {
            Defaults[.quickToggle] = newValue
        }
    }
    
    public var quickToggleType: QuickToggleType? {
        get {
            return Defaults[.quickToggleType].map(QuickToggleType.init(rawValue: )) ?? nil
        }
        
        set {
            Defaults[.quickToggleType] = newValue?.rawValue
        }
    }
    
    public var isHideStatusItem: Bool {
        get {
            return Defaults[.hideStatusItem]
        }
        
        set {
            Defaults[.hideStatusItem] = newValue
        }
    }
    
    /// config.json is canonical; UserDefaults is the fallback for unmigrated
    /// or unset values. See ConfigStore.
    private var store: ConfigStore { ConfigStore.shared }

    public var isHideContextMenuItems: Bool {
        get {
            return store.config.menu?.hideContextMenuItems
                ?? Defaults[.hideContextMenuItems]
        }

        set {
            store.updateMenu { $0.hideContextMenuItems = newValue }
        }
    }

    /// Whether the Finder context menu items are grouped into a submenu.
    /// This option only applies to the Finder context menu, not the toolbar menu.
    public var isContextMenuUseSubmenu: Bool {
        get {
            return store.config.menu?.useSubmenu
                ?? Defaults[.contextMenuUseSubmenu]
        }

        set {
            store.updateMenu { $0.useSubmenu = newValue }
        }
    }

    /// Whether the default terminal item stays at the top level of the Finder
    /// context menu instead of being grouped into the submenu or mixed into
    /// the custom app list.
    public var isContextMenuPinDefaultTerminal: Bool {
        get {
            return store.config.menu?.pinDefaultTerminal
                ?? Defaults[.contextMenuPinDefaultTerminal]
        }

        set {
            store.updateMenu { $0.pinDefaultTerminal = newValue }
        }
    }

    public var shouldOnlyActivateShortcutsInFinder: Bool {
        get {
            return Defaults[.onlyActivateShortcutsInFinder]
        }
        
        set {
            Defaults[.onlyActivateShortcutsInFinder] = newValue
        }
    }
    
    public var defaultTerminal: App? {
        get {
            // config.json is canonical: ref (catalog id) or display name
            if let ref = store.config.defaultTerminal,
               let resolved = AppCatalog.shared.resolve(ref) {
                return resolved.app
            }
            guard let terminalName = store.config.defaultTerminal
                ?? Defaults[.defaultTerminal] else { return nil }
            // resolve supported apps case-insensitively so the canonical name and bundleId are used
            if let supported = SupportedApps.from(name: terminalName) {
                return supported.app
            }
            let app = App(name: terminalName, type: .terminal)
            return app
        }

        set {
            guard let newValue = newValue else { return }
            let id = AppCatalog.shared.resolve(app: newValue)?.id ?? newValue.name
            store.update { $0.defaultTerminal = id }
        }
    }

    public var defaultEditor: App? {
        get {
            if let ref = store.config.defaultEditor,
               let resolved = AppCatalog.shared.resolve(ref) {
                return resolved.app
            }
            guard let editorName = store.config.defaultEditor
                ?? Defaults[.defaultEditor] else { return nil }
            // resolve supported apps case-insensitively so the canonical name and bundleId are used
            if let supported = SupportedApps.from(name: editorName) {
                return supported.app
            }
            let app = App(name: editorName, type: .editor)
            return app
        }

        set {
            guard let newValue = newValue else { return }
            let id = AppCatalog.shared.resolve(app: newValue)?.id ?? newValue.name
            store.update { $0.defaultEditor = id }
        }
    }
    
    public var liteDefaultTerminal: String? {
        get {
            return Defaults[.liteDefaultTerminal]
        }
        
        set {
            Defaults[.liteDefaultTerminal] = newValue
        }
    }
    
    public var liteDefaultEditor: String? {
        get {
            return Defaults[.liteDefaultEditor]
        }
        
        set {
            Defaults[.liteDefaultEditor] = newValue
        }
    }
    
    // MARK: - Preferences - Custom
    
    /// Legacy compat API: reads the `newInstance` option of the first menu
    /// item resolving to the given app. New code should use per-item options
    /// via ConfigStore.
    public func getNewOption(_ app: SupportedApps) -> NewOptionType? {
        let items = store.config.menu?.items ?? []
        for (i, item) in items.enumerated() {
            guard let ref = item.ref,
                  let cat = AppCatalog.shared.resolve(ref),
                  cat.name.caseInsensitiveCompare(app.name) == .orderedSame else { continue }
            let merged = store.itemOptions(at: i)
            if let v = merged["newInstance"]?.stringValue {
                return NewOptionType(rawValue: v)
            }
        }
        // legacy fallback
        switch app {
        case .iTerm:
            return Defaults[.iTermNewOption].map(NewOptionType.init(rawValue:)) ?? nil
        default:
            return nil
        }
    }

    /// Sets the `newInstance` option on every menu item resolving to the
    /// given app, executing the declared apply side effects (e.g. iTerm's
    /// OpenFileInNewWindows).
    public func setNewOption(_ app: SupportedApps, _ newOption: NewOptionType) {
        var applied = false
        let items = store.config.menu?.items ?? []
        for (i, item) in items.enumerated() {
            guard let ref = item.ref,
                  let cat = AppCatalog.shared.resolve(ref),
                  cat.name.caseInsensitiveCompare(app.name) == .orderedSame,
                  cat.options?["newInstance"] != nil else { continue }
            store.setItemOption(at: i, optionId: "newInstance",
                                value: .string(newOption.rawValue))
            applied = true
        }
        if !applied, case .iTerm = app {
            // no item present yet — keep the legacy default in sync so the
            // value is picked up when an iTerm item is later added
            Defaults[.iTermNewOption] = newOption.rawValue
            AppCatalog.shared.app(id: "iterm2").flatMap {
                AppCatalog.shared.applyOption(app: $0, optionId: "newInstance",
                                              value: .string(newOption.rawValue))
            }
        }
    }

    /// Menu items as legacy `App` list — derived from config.json items.
    /// Falls back to the plist when config.json has no items (pre-migration).
    public var customMenuOptions: [App]? {
        get {
            let resolved = store.resolvedItems().compactMap { $0.app }
            if !resolved.isEmpty { return resolved }
            guard let appsData = Defaults[.customMenuOptions] else { return nil }
            do {
                let apps = try decoder.decode([App].self, from: appsData)
                return apps
            } catch {
                return nil
            }
        }

        set {
            guard let newValue = newValue else { return }
            // preserve existing per-item options where the app still matches
            let existing = store.config.menu?.items ?? []
            let items: [MenuItemConfig] = newValue.map { app in
                if let idx = existing.firstIndex(where: {
                    ($0.ref.flatMap { AppCatalog.shared.resolve($0)?.name } ?? $0.app?.name)
                        == app.name
                }) {
                    return existing[idx]
                }
                if let cat = AppCatalog.shared.resolve(app: app) {
                    return MenuItemConfig(ref: cat.id)
                }
                return MenuItemConfig(app: InlineAppDef(name: app.name, type: app.type,
                                                      bundleId: app.bundleId, open: nil))
            }
            store.updateMenu { $0.items = items }
        }
    }
    
    public var isCustomMenuApplyToToolbar: Bool {
        get {
            return store.config.menu?.applyToToolbar
                ?? Defaults[.customMenuApplyToToolbar]
        }

        set {
            store.updateMenu { $0.applyToToolbar = newValue }
        }
    }

    public var isCustomMenuApplyToContext: Bool {
        get {
            return store.config.menu?.applyToContext
                ?? Defaults[.customMenuApplyToContext]
        }

        set {
            store.updateMenu { $0.applyToContext = newValue }
        }
    }

    public var customMenuIconOption: CustomMenuIconOption {
        get {
            let optionValue = store.config.menu?.iconOption
                ?? Defaults[.customMenuIconOption] ?? "no"
            let option = CustomMenuIconOption(rawValue: optionValue)
            return option ?? .no
        }

        set {
            store.updateMenu { $0.iconOption = newValue.rawValue }
        }
    }

    public var isPathEscaped: Bool {
        get {
            return store.config.menu?.pathEscaped
                ?? Defaults[.pathEscapeOption]
        }

        set {
            store.updateMenu { $0.pathEscaped = newValue }
        }
    }

    public func getAppIcon(_ app: App) -> NSImage? {
        switch customMenuIconOption {
        case .no:
            return nil
        case .simple:
            if app.type == .terminal {
                return NSImage(named: "context_menu_icon_terminal")
            } else {
                return NSImage(named: "context_menu_icon_editor")
            }
        case .original:
            if SupportedApps.isSupported(app),
               let icon = NSImage(named: app.name) {
                return icon
            }
            if app.type == .terminal {
                return NSImage(named: "context_menu_icon_color_terminal")
            } else {
                return NSImage(named: "context_menu_icon_color_editor")
            }
        }
    }
    
    // MARK: - Open Commands
    
    public var kittyCommand: String {
        get {
            return Defaults[.kittyCommand] ?? Constants.Commands.kitty
        }
        
        set {
            Defaults[.kittyCommand] = newValue
        }
    }

    public var neovimCommand: String {
        get {
            return Defaults[.neovimCommand] ?? Constants.Commands.neovim
        }
        
        set {
            Defaults[.neovimCommand] = newValue
        }
    }

    public var gitKrakenCommand: String {
        get {
            return Defaults[.gitkrakenCommand] ?? Constants.Commands.gitkraken
        }
        
        set {
            Defaults[.gitkrakenCommand] = newValue
        }
    }
    

    /// The open recipe for an app: user command overrides first (legacy
    /// KittyCommand/NeovimCommand/GitkrakenCommand prefs), then the catalog
    /// (bundled + user `apps[]`), then `open -a <name>`.
    public func openRecipe(for app: App) -> OpenRecipe {
        if let cmd = legacyCommandOverride(for: app) {
            var argv = cmd.split(separator: " ").map(String.init)
            if !argv.isEmpty { argv.removeFirst() }  // drop leading "open"
            // unify the old PATH placeholder token with the recipe model
            let hasPlaceholder = argv.contains("PATH")
            argv = argv.map { $0 == "PATH" ? "{paths}" : $0 }
            return OpenRecipe(argv: argv,
                              pathMode: hasPlaceholder ? .placeholder : defaultPathMode(for: app.type))
        }
        if let cat = AppCatalog.shared.resolve(app: app) {
            return cat.open
        }
        return OpenRecipe(argv: ["-a", app.name],
                          pathMode: defaultPathMode(for: app.type))
    }

    private func defaultPathMode(for type: AppType) -> PathMode {
        type == .terminal ? .appendFirst : .append
    }

    /// User-set command defaults that predate the catalog; honored so
    /// existing overrides keep working (also mirrored into config.json
    /// `apps[]` by migration).
    private func legacyCommandOverride(for app: App) -> String? {
        if SupportedApps.is(app, is: .kitty), Defaults[.kittyCommand] != nil {
            return kittyCommand
        }
        if SupportedApps.is(app, is: .neovim), Defaults[.neovimCommand] != nil {
            return neovimCommand
        }
        if SupportedApps.is(app, is: .gitKraken), Defaults[.gitkrakenCommand] != nil {
            return gitKrakenCommand
        }
        return nil
    }

    public func getOpenCommand(_ app: App, escapeCount: Int = 1) -> String {
        // legacy string form — joins recipe tokens; kept for the
        // deprecated script-generation paths
        let argv = openRecipe(for: app).argv
        if escapeCount > 0 {
            return "open " + argv.map { $0.nameSpaceEscaped(escapeCount) }.joined(separator: " ")
        }
        return "open " + argv.joined(separator: " ")
    }

    /// Returns the `open` invocation split into argument tokens, excluding the
    /// leading "open" program name and excluding any target path.
    ///
    /// Paths must be appended by the caller as discrete `Process` arguments so
    /// that they are never interpreted by a shell or by AppleScript. This is the
    /// injection-safe counterpart to `getOpenCommand`.
    public func getOpenArguments(_ app: App) -> [String] {
        return openRecipe(for: app).argv
    }

    // MARK: - Advanced Settings
    
    public func firstSetup() {
        guard isFirstSetup == false else { return }
        logw("First Setup")
        isFirstSetup = true
        isLaunchAtLogin = false
        isQuickToggle = false
        quickToggleType = .openWithDefaultTerminal
        isHideStatusItem = false
        isHideContextMenuItems = false
        isContextMenuUseSubmenu = false
        isContextMenuPinDefaultTerminal = false
        defaultTerminal = SupportedApps.terminal.app
        defaultEditor = SupportedApps.textEdit.app
        setNewOption(.terminal, .window)
        setNewOption(.iTerm, .window)
        isCustomMenuApplyToToolbar = false
        isCustomMenuApplyToContext = false
        customMenuIconOption = .no
        isPathEscaped = true
        Defaults.synchronize()
    }
    
    public func removeAllUserDefaults() {
        logw("Remove all UserDefaults")
        Defaults.removePersistentDomain(forName: Constants.Id.Group)
        Defaults.synchronize()
    }
    
}
