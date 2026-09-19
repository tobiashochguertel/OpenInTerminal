//
//  ConfigStore.swift
//  OpenInTerminalCore
//
//  Canonical user configuration: config.json inside the app-group container.
//  The sandboxed Finder extension can read the group container, so this is
//  the only location both processes can share. See Schemas/config.schema.json.
//
//  Load order per key: config.json → legacy UserDefaults (migrated on first
//  launch) → built-in defaults. Writes go to config.json and are mirrored
//  into UserDefaults so legacy readers stay consistent.

import Foundation

// MARK: - config.json model

/// Inline custom app inside a menu item (or user `apps[]` uses CatalogApp).
public struct InlineAppDef: Codable, Equatable {
    public var name: String
    public var type: AppType
    public var bundleId: String?
    public var open: OpenRecipe?

    public init(name: String, type: AppType, bundleId: String? = nil,
                open: OpenRecipe? = nil) {
        self.name = name; self.type = type
        self.bundleId = bundleId; self.open = open
    }

    public var app: App {
        var a = App(name: name, type: type)
        a.bundleId = bundleId
        return a
    }
}

/// Built-in non-app menu entries.
public enum MenuAction: String, Codable {
    case copyPath
}

/// One entry of menu.items[] — exactly one of `ref`, `app`, `kind` set.
public struct MenuItemConfig: Codable, Equatable {
    public var ref: String?
    public var app: InlineAppDef?
    public var kind: String?
    public var action: MenuAction?
    public var label: String?
    public var options: [String: JSONValue]?
    public var hidden: Bool?

    public init(ref: String? = nil, app: InlineAppDef? = nil,
                kind: String? = nil, action: MenuAction? = nil,
                label: String? = nil, options: [String: JSONValue]? = nil,
                hidden: Bool? = nil) {
        self.ref = ref; self.app = app; self.kind = kind
        self.action = action; self.label = label
        self.options = options; self.hidden = hidden
    }
}

public struct MenuConfig: Codable, Equatable {
    public var hideContextMenuItems: Bool?
    public var useSubmenu: Bool?
    public var pinDefaultTerminal: Bool?
    public var applyToContext: Bool?
    public var applyToToolbar: Bool?
    public var iconOption: String?
    public var pathEscaped: Bool?
    public var items: [MenuItemConfig]?

    public init(hideContextMenuItems: Bool? = nil, useSubmenu: Bool? = nil,
                pinDefaultTerminal: Bool? = nil, applyToContext: Bool? = nil,
                applyToToolbar: Bool? = nil, iconOption: String? = nil,
                pathEscaped: Bool? = nil, items: [MenuItemConfig]? = nil) {
        self.hideContextMenuItems = hideContextMenuItems
        self.useSubmenu = useSubmenu
        self.pinDefaultTerminal = pinDefaultTerminal
        self.applyToContext = applyToContext
        self.applyToToolbar = applyToToolbar
        self.iconOption = iconOption
        self.pathEscaped = pathEscaped
        self.items = items
    }
}

public struct GeneralConfig: Codable, Equatable {
    public var launchAtLogin: Bool?
    public var quickToggle: Bool?
    public var quickToggleType: String?
    public var hideStatusItem: Bool?
    public var onlyActivateShortcutsInFinder: Bool?

    public init(launchAtLogin: Bool? = nil, quickToggle: Bool? = nil,
                quickToggleType: String? = nil, hideStatusItem: Bool? = nil,
                onlyActivateShortcutsInFinder: Bool? = nil) {
        self.launchAtLogin = launchAtLogin
        self.quickToggle = quickToggle
        self.quickToggleType = quickToggleType
        self.hideStatusItem = hideStatusItem
        self.onlyActivateShortcutsInFinder = onlyActivateShortcutsInFinder
    }
}

public struct OITConfig: Codable, Equatable {
    public var version: Int
    public var defaultTerminal: String?
    public var defaultEditor: String?
    public var general: GeneralConfig?
    public var menu: MenuConfig?
    /// User-defined catalog entries; merged over the bundled catalog.
    public var apps: [CatalogApp]?

    public init(version: Int = 1) {
        self.version = version
    }
}

// MARK: - Resolved menu item (what the engine actually consumes)

public struct ResolvedMenuItem {
    public enum Content {
        /// App resolved through the catalog (bundled or user-defined).
        case catalogApp(CatalogApp)
        /// Inline custom app with an optional open recipe.
        case customApp(App, OpenRecipe?)
        /// Built-in action (Copy Path).
        case action(MenuAction)
    }
    public var content: Content
    /// Display title (label override or app name / action title).
    public var title: String
    public var options: [String: JSONValue]
    public var hidden: Bool
    /// The original config entry, for writes back.
    public var source: MenuItemConfig

    public init(content: Content, title: String, options: [String: JSONValue],
                hidden: Bool, source: MenuItemConfig) {
        self.content = content; self.title = title
        self.options = options; self.hidden = hidden; self.source = source
    }

    public var app: App? {
        switch content {
        case .catalogApp(let c): return c.app
        case .customApp(let a, _): return a
        case .action: return nil
        }
    }

    /// Effective open recipe for this item.
    public var openRecipe: OpenRecipe {
        switch content {
        case .catalogApp(let c):
            return AppCatalog.shared.openRecipe(for: c, options: options)
        case .customApp(let a, let recipe):
            if let r = recipe { return r }
            // sensible default per type, matching legacy behaviour
            return OpenRecipe(argv: ["-a", a.name],
                              pathMode: a.type == .terminal ? .appendFirst : .append)
        case .action:
            return OpenRecipe(argv: [], pathMode: .none)
        }
    }
}

// MARK: - Store

public final class ConfigStore {

    public static let shared = ConfigStore()

    /// Validation issues are non-fatal: each bad field falls back to
    /// UserDefaults / built-in defaults and is logged.
    public struct Issue {
        public let path: String
        public let message: String
        public var description: String { "\(path): \(message)" }
    }

    public private(set) var config: OITConfig
    public private(set) var issues: [Issue] = []

    /// File URL of config.json inside the app-group container.
    public var configURL: URL {
        if let env = ProcessInfo.processInfo.environment["OIT_CONFIG_PATH"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.Id.Group) {
            return container.appendingPathComponent("config.json")
        }
        let fallback = NSHomeDirectory()
            + "/Library/Group Containers/\(Constants.Id.Group)/config.json"
        return URL(fileURLWithPath: fallback)
    }

    public init() {
        config = OITConfig()
        load()
        migrateIfNeeded()
        AppCatalog.shared.merge(userApps: config.apps ?? [])
        for issue in issues {
            OITLog.defaults.error("config.json \(issue.description, privacy: .public)")
        }
    }

    // MARK: - Load

    @discardableResult
    public func load() -> Bool {
        issues = []
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            config = OITConfig()
            AppCatalog.shared.merge(userApps: [])
            return false
        }
        do {
            let data = try Data(contentsOf: configURL)
            config = try JSONDecoder().decode(OITConfig.self, from: data)
            AppCatalog.shared.merge(userApps: config.apps ?? [])
            issues = validate(config)
            return true
        } catch {
            OITLog.defaults.error("config.json unreadable: \(error.localizedDescription, privacy: .public)")
            issues = [Issue(path: "/", message: "unreadable: \(error.localizedDescription)")]
            config = OITConfig()
            return false
        }
    }

    // MARK: - Validation (in-code mirror of config.schema.json)

    public func validate(_ cfg: OITConfig) -> [Issue] {
        var out: [Issue] = []
        if cfg.version != 1 {
            out.append(Issue(path: "version", message: "unsupported version \(cfg.version)"))
        }
        let items = cfg.menu?.items ?? []
        for (i, item) in items.enumerated() {
            let p = "menu.items[\(i)]"
            let setCount = [item.ref != nil, item.app != nil, item.kind != nil].filter { $0 }.count
            if setCount != 1 {
                out.append(Issue(path: p, message: "exactly one of ref/app/kind required"))
            }
            if let ref = item.ref, AppCatalog.shared.resolve(ref) == nil {
                out.append(Issue(path: "\(p).ref", message: "unknown ref '\(ref)'"))
            }
            if item.kind != nil && item.kind != "action" {
                out.append(Issue(path: "\(p).kind", message: "unknown kind '\(item.kind!)'"))
            }
            // option values must match the target app's option definitions
            if let ref = item.ref,
               let catApp = AppCatalog.shared.resolve(ref),
               let itemOpts = item.options {
                for (key, value) in itemOpts {
                    guard let def = catApp.options?[key] else {
                        out.append(Issue(path: "\(p).options.\(key)",
                                         message: "app '\(ref)' declares no option '\(key)'"))
                        continue
                    }
                    if !def.isValidValue(value) {
                        out.append(Issue(path: "\(p).options.\(key)",
                                         message: "invalid value for option '\(key)'"))
                    }
                }
            }
        }
        // user app entries must not collide with each other
        var seen = Set<String>()
        for (i, a) in (cfg.apps ?? []).enumerated() {
            if !seen.insert(a.id).inserted {
                out.append(Issue(path: "apps[\(i)].id", message: "duplicate id '\(a.id)'"))
            }
        }
        return out
    }

    // MARK: - Resolved items

    /// Menu items joined with the catalog. Invalid entries are skipped and
    /// logged rather than failing the whole menu.
    public func resolvedItems() -> [ResolvedMenuItem] {
        (config.menu?.items ?? []).compactMap { resolvedItem($0) }
    }

    /// Resolves a single configured item against the catalog.
    public func resolvedItem(_ item: MenuItemConfig) -> ResolvedMenuItem? {
        let title: String
        let content: ResolvedMenuItem.Content
        if let ref = item.ref {
            guard let c = AppCatalog.shared.resolve(ref) else {
                OITLog.menu.error("menu item ref '\(ref, privacy: .public)' unresolved — skipped")
                return nil
            }
            content = .catalogApp(c)
            title = item.label ?? c.name
        } else if let inline = item.app {
            content = .customApp(inline.app, inline.open)
            title = item.label ?? inline.name
        } else if item.kind == "action", let action = item.action {
            content = .action(action)
            title = item.label ?? NSLocalizedString("menu.copy_path_to_clipboard", comment: "Copy path")
        } else {
            return nil
        }
        return ResolvedMenuItem(content: content,
                                title: title,
                                options: item.options ?? [:],
                                hidden: item.hidden ?? false,
                                source: item)
    }

    /// Display title for a configured item, including unresolved refs —
    /// for the preferences table, which must show broken entries so the
    /// user can fix or remove them.
    public func displayTitle(for item: MenuItemConfig) -> String {
        if let resolved = resolvedItem(item) { return resolved.title }
        return item.label ?? item.ref ?? item.app?.name ?? "?"
    }

    // MARK: - Mutation

    /// Applies a mutation to the config and persists it.
    public func update(_ mutate: (inout OITConfig) -> Void) {
        mutate(&config)
        save()
    }

    /// Convenience for mutating the menu section.
    public func updateMenu(_ mutate: (inout MenuConfig) -> Void) {
        var m = config.menu ?? MenuConfig()
        mutate(&m)
        update { $0.menu = m }
    }

    /// Sets a per-item option value, executes the option's declared apply
    /// side effects, and persists. `index` is the position in menu.items.
    public func setItemOption(at index: Int, optionId: String, value: JSONValue) {
        updateMenu { menu in
            guard let items = menu.items, items.indices.contains(index) else { return }
            var item = items[index]
            var opts = item.options ?? [:]
            opts[optionId] = value
            item.options = opts
            menu.items?[index] = item
        }
        if let ref = config.menu?.items?[index].ref,
           let catApp = AppCatalog.shared.resolve(ref) {
            AppCatalog.shared.applyOption(app: catApp, optionId: optionId, value: value)
        }
    }

    /// Option values for the menu item at `index`, merged over the catalog
    /// defaults.
    public func itemOptions(at index: Int) -> [String: JSONValue] {
        guard let item = config.menu?.items?[safe: index] else { return [:] }
        var merged: [String: JSONValue] = [:]
        if let ref = item.ref, let catApp = AppCatalog.shared.resolve(ref),
           let defs = catApp.options {
            for (key, def) in defs {
                if let d = def.default { merged[key] = d }
            }
        }
        for (k, v) in item.options ?? [:] { merged[k] = v }
        return merged
    }

    // MARK: - Save

    /// Persists config.json atomically and mirrors the covered values into
    /// UserDefaults so legacy readers stay consistent.
    public func save() {
        do {
            let dir = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(config)
            try data.write(to: configURL, options: .atomic)
            mirrorToDefaults()
        } catch {
            OITLog.defaults.error("config.json save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mirrors covered keys into UserDefaults (legacy compat + debugging).
    private func mirrorToDefaults() {
        if let t = config.defaultTerminal { Defaults[.defaultTerminal] = resolvedName(t) }
        if let e = config.defaultEditor { Defaults[.defaultEditor] = resolvedName(e) }
        guard let m = config.menu else { return }
        if let v = m.hideContextMenuItems { Defaults[.hideContextMenuItems] = v }
        if let v = m.useSubmenu { Defaults[.contextMenuUseSubmenu] = v }
        if let v = m.pinDefaultTerminal { Defaults[.contextMenuPinDefaultTerminal] = v }
        if let v = m.applyToContext { Defaults[.customMenuApplyToContext] = v }
        if let v = m.applyToToolbar { Defaults[.customMenuApplyToToolbar] = v }
        if let v = m.iconOption { Defaults[.customMenuIconOption] = v }
        if let v = m.pathEscaped { Defaults[.pathEscapeOption] = v }
        // legacy CustomMenuOptions: JSON [App] of the app items only
        let legacyApps: [App] = resolvedItems().compactMap { $0.app }
        if let data = try? JSONEncoder().encode(legacyApps) {
            Defaults[.customMenuOptions] = data
        }
    }

    private func resolvedName(_ refOrName: String) -> String {
        AppCatalog.shared.resolve(refOrName)?.name ?? refOrName
    }

    // MARK: - Migration from UserDefaults (first launch)

    /// If config.json does not exist, synthesizes it from the current
    /// UserDefaults so nothing is lost. Runs once; a marker default prevents
    /// re-migration after the user deletes the file on purpose.
    ///
    /// IMPORTANT: reads `Defaults` keys directly — never `DefaultsManager`
    /// getters — because those route through `ConfigStore.shared`, and this
    /// function runs inside `ConfigStore.init` (reentrant singleton init
    /// would deadlock).
    public func migrateIfNeeded() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        guard !Defaults[.configMigrated] else { return }

        var cfg = OITConfig()
        let catalog = AppCatalog.shared

        if let name = Defaults[.defaultTerminal] {
            cfg.defaultTerminal = catalog.resolve(name)?.id ?? name
        }
        if let name = Defaults[.defaultEditor] {
            cfg.defaultEditor = catalog.resolve(name)?.id ?? name
        }

        cfg.general = GeneralConfig(
            launchAtLogin: Defaults[.launchAtLogin],
            quickToggle: Defaults[.quickToggle],
            quickToggleType: Defaults[.quickToggleType],
            hideStatusItem: Defaults[.hideStatusItem],
            onlyActivateShortcutsInFinder: Defaults[.onlyActivateShortcutsInFinder])

        var items: [MenuItemConfig] = []
        let legacyApps: [App] = (Defaults[.customMenuOptions]).flatMap {
            try? JSONDecoder().decode([App].self, from: $0)
        } ?? []
        for app in legacyApps {
            var item = MenuItemConfig()
            if let cat = catalog.resolve(app: app) {
                item.ref = cat.id
                // carry forward the app's configured options (iTerm window/tab)
                if cat.id == "iterm2", let opt = Defaults[.iTermNewOption] {
                    item.options = ["newInstance": .string(opt)]
                }
            } else {
                item.app = InlineAppDef(name: app.name, type: app.type,
                                        bundleId: app.bundleId, open: nil)
            }
            items.append(item)
        }

        cfg.menu = MenuConfig(
            hideContextMenuItems: Defaults[.hideContextMenuItems],
            useSubmenu: Defaults[.contextMenuUseSubmenu],
            pinDefaultTerminal: Defaults[.contextMenuPinDefaultTerminal],
            applyToContext: Defaults[.customMenuApplyToContext],
            applyToToolbar: Defaults[.customMenuApplyToToolbar],
            iconOption: Defaults[.customMenuIconOption],
            pathEscaped: Defaults[.pathEscapeOption],
            items: items)

        // user-defined command overrides become user catalog entries
        var userApps: [CatalogApp] = []
        if let cmd = Defaults[.kittyCommand], let base = catalog.app(id: "kitty") {
            var custom = base
            custom.open = OpenRecipe(argv: cmd.dropFirstToken(), pathMode: base.open.pathMode)
            userApps.append(custom)
        }
        if let cmd = Defaults[.neovimCommand], let base = catalog.app(id: "neovim") {
            var custom = base
            custom.open = OpenRecipe(argv: cmd.dropFirstToken(), pathMode: base.open.pathMode)
            userApps.append(custom)
        }
        if let cmd = Defaults[.gitkrakenCommand], let base = catalog.app(id: "gitkraken") {
            var custom = base
            custom.open = OpenRecipe(argv: cmd.dropFirstToken(), pathMode: base.open.pathMode)
            userApps.append(custom)
        }
        if !userApps.isEmpty { cfg.apps = userApps }

        config = cfg
        save()
        Defaults[.configMigrated] = true
        OITLog.defaults.notice("migrated UserDefaults → config.json at \(self.configURL.path, privacy: .public)")
    }
}

fileprivate extension String {
    /// Splits a legacy `open ...` command template into argv tokens,
    /// dropping the leading `open` program name.
    func dropFirstToken() -> [String] {
        var tokens = split(separator: " ").map(String.init)
        if !tokens.isEmpty { tokens.removeFirst() }
        return tokens
    }
}

extension Collection {
    /// Bounds-checked subscript; returns nil instead of trapping.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
