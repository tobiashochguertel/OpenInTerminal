//
//  Catalog.swift
//  OpenInTerminalCore
//
//  Declarative application catalog: replaces the hardcoded per-app knowledge
//  that used to live in SupportedApps/Constants.Commands. The bundled
//  AppCatalog.json is data, so adding or fixing an app no longer requires a
//  code change. User-defined entries from config.json merge over the bundled
//  catalog.
//
//  See Schemas/appcatalog.schema.json for the authoritative format.

import Foundation

// MARK: - JSON helper

/// Minimal free-form JSON value for option payloads (bool/string/number).
public enum JSONValue: Codable, Equatable {
    case bool(Bool)
    case string(String)
    case number(Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(JSONValue.self, .init(
            codingPath: decoder.codingPath,
            debugDescription: "expected bool, number, or string"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }

    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
}

// MARK: - Open recipe

/// How paths are delivered to `open`.
public enum PathMode: String, Codable {
    /// All selected paths appended (editors).
    case append
    /// Directory of the first selected item appended (terminals).
    case appendFirst
    /// `{paths}` tokens inside argv are replaced by the selected paths.
    case placeholder
    /// No paths passed.
    case none
}

/// One way to open paths: an argv template for `/usr/bin/open`, or a named
/// AppleScript in Application Scripts (e.g. Terminal's new-tab script).
public struct OpenRecipe: Codable, Equatable {
    /// Arguments appended after `/usr/bin/open`. The literal token `{paths}`
    /// is replaced by selected paths when pathMode == .placeholder.
    public var argv: [String]
    public var pathMode: PathMode
    /// Name of a .scpt in Application Scripts; when set, it is executed
    /// instead of the general openApp script.
    public var script: String?

    public init(argv: [String], pathMode: PathMode = .append, script: String? = nil) {
        self.argv = argv
        self.pathMode = pathMode
        self.script = script
    }

    enum CodingKeys: String, CodingKey { case argv, pathMode, script }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        argv = try c.decodeIfPresent([String].self, forKey: .argv) ?? []
        pathMode = try c.decodeIfPresent(PathMode.self, forKey: .pathMode) ?? .append
        script = try c.decodeIfPresent(String.self, forKey: .script)
    }
}

// MARK: - Option definitions

/// A side effect executed when an option value is selected (e.g. writing the
/// target application's own defaults, like iTerm's OpenFileInNewWindows).
public struct ApplyAction: Codable, Equatable {
    public struct DefaultsWrite: Codable, Equatable {
        public var domain: String
        public var key: String
        public var value: JSONValue
    }
    public var defaultsWrite: DefaultsWrite?

    /// Executes all declared side effects. Best-effort: failures are logged,
    /// never thrown — a broken apply must not break the menu.
    public func execute() {
        if let dw = defaultsWrite {
            let plistVal: Any
            switch dw.value {
            case .bool(let b): plistVal = b
            case .string(let s): plistVal = s
            case .number(let n):
                plistVal = n.truncatingRemainder(dividingBy: 1) == 0 ? Int(n) : n
            }
            let cfDomain = dw.domain as CFString
            CFPreferencesSetAppValue(dw.key as CFString, plistVal as CFPropertyList, cfDomain)
            let ok = CFPreferencesAppSynchronize(cfDomain)
            if !ok {
                OITLog.defaults.error("applyOption: CFPreferences write failed for \(dw.domain, privacy: .public).\(dw.key, privacy: .public)")
            }
        }
    }
}

public enum OptionDefType: String, Codable { case choice, bool }

public struct OptionChoice: Codable, Equatable {
    public var value: String
    public var label: String
    /// Side effect executed when this value is selected.
    public var apply: ApplyAction?
    /// Open-recipe override active while this value is selected.
    public var open: OpenRecipe?
}

/// Declarative description of a configurable per-item option.
/// `options` on a catalog entry are definitions; `options` on a menu item
/// are the selected values.
public struct OptionDef: Codable, Equatable {
    public var type: OptionDefType
    public var label: String
    public var `default`: JSONValue?
    public var choices: [OptionChoice]?
    public var apply: ApplyAction?

    /// Validates a configured value against this definition.
    public func isValidValue(_ v: JSONValue) -> Bool {
        switch type {
        case .bool: return v.boolValue != nil
        case .choice:
            guard let s = v.stringValue else { return false }
            return (choices ?? []).contains { $0.value == s }
        }
    }

    /// The choice matching a configured (or default) string value.
    public func choice(for value: String) -> OptionChoice? {
        (choices ?? []).first { $0.value == value }
    }
}

// MARK: - Catalog app entry

/// One application definition — same shape in the bundled catalog and in
/// user `apps[]` inside config.json.
public struct CatalogApp: Codable, Equatable {
    public var id: String
    public var name: String
    public var type: AppType
    public var bundleId: String?
    public var icon: String?
    public var open: OpenRecipe
    public var options: [String: OptionDef]?

    /// Converts to the legacy `App` value used across the codebase.
    public var app: App {
        var a = App(name: name, type: type)
        a.bundleId = bundleId
        return a
    }
}

// MARK: - Catalog

/// Loads and resolves the bundled catalog plus user-defined app entries.
public final class AppCatalog {

    /// Shared instance: bundled catalog only. Call `merge(userApps:)` after
    /// loading config.json to overlay user entries.
    public static let shared = AppCatalog()

    public private(set) var apps: [CatalogApp] = []
    /// Bundled entries before user overlays; merge(userApps:) rebuilds from
    /// this so a reload fully replaces previous user entries.
    private var bundledApps: [CatalogApp] = []
    private var byId: [String: CatalogApp] = [:]
    private var byName: [String: CatalogApp] = [:]

    /// Environment override for tests: path to a catalog JSON file.
    static let envCatalogPath = "OIT_CATALOG_PATH"

    public init() {
        loadBundled()
    }

    /// Testable initializer: load from an explicit file URL.
    public init(fileURL: URL) {
        load(from: fileURL)
    }

    private func loadBundled() {
        if let envPath = ProcessInfo.processInfo.environment[AppCatalog.envCatalogPath],
           FileManager.default.fileExists(atPath: envPath) {
            load(from: URL(fileURLWithPath: envPath))
            return
        }
        // The catalog ships inside the OpenInTerminalCore framework bundle so
        // both the app and the (sandboxed) appex can read it.
        let bundle = Bundle(for: AppCatalog.self)
        if let url = bundle.url(forResource: "AppCatalog", withExtension: "json") {
            load(from: url)
        } else {
            OITLog.defaults.error("AppCatalog.json not found in framework bundle")
        }
    }

    private func load(from url: URL) {
        struct Root: Codable { var schemaVersion: Int; var apps: [CatalogApp] }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(Root.self, from: data) else {
            OITLog.defaults.error("AppCatalog: failed to parse \(url.path, privacy: .public)")
            return
        }
        bundledApps = root.apps
        merge(root.apps)
    }

    /// Overlays additional entries (e.g. user apps from config.json).
    /// Rebuilds from the bundled set first, so reloading config.json fully
    /// replaces — rather than accumulates — user entries. Entries with an
    /// existing id replace the bundled entry.
    public func merge(userApps: [CatalogApp]) {
        apps = bundledApps
        reindex()
        merge(userApps)
    }

    private func merge(_ newApps: [CatalogApp]) {
        for app in newApps {
            if byId[app.id] != nil {
                apps.removeAll { $0.id == app.id }
            }
            apps.append(app)
        }
        reindex()
    }

    private func reindex() {
        byId = [:]; byName = [:]
        for app in apps {
            byId[app.id] = app
            byName[app.name.lowercased()] = app
        }
    }

    // MARK: - Resolution

    public func app(id: String) -> CatalogApp? {
        byId[id]
    }

    /// Resolves a config `ref` or legacy display name to a catalog entry.
    /// Order: exact id → case-insensitive name.
    public func resolve(_ refOrName: String) -> CatalogApp? {
        if let a = byId[refOrName] { return a }
        return byName[refOrName.lowercased()]
    }

    /// Resolves a legacy `App` (name-based, from old CustomMenuOptions) to a
    /// catalog entry.
    public func resolve(app: App) -> CatalogApp? {
        resolve(app.name)
    }

    public var terminals: [CatalogApp] { apps.filter { $0.type == .terminal } }
    public var editors: [CatalogApp] { apps.filter { $0.type == .editor } }

    // MARK: - Open recipe resolution

    /// Effective open recipe for an app given its configured option values.
    /// Option choices may carry an `open` override (e.g. Terminal's tab mode
    /// uses a dedicated AppleScript).
    public func openRecipe(for app: CatalogApp, options: [String: JSONValue]) -> OpenRecipe {
        guard let defs = app.options else { return app.open }
        for (key, def) in defs where def.type == .choice {
            let selected: String
            if let v = options[key]?.stringValue {
                selected = v
            } else if let d = def.default?.stringValue {
                selected = d
            } else {
                continue
            }
            if let override = def.choice(for: selected)?.open {
                return override
            }
        }
        return app.open
    }

    /// Executes the apply side effects of the currently-selected option
    /// values (e.g. iTerm's OpenFileInNewWindows).
    public func applyOptionSideEffects(for app: CatalogApp, options: [String: JSONValue]) {
        guard let defs = app.options else { return }
        for (key, def) in defs {
            switch def.type {
            case .choice:
                guard let s = options[key]?.stringValue,
                      let choice = def.choice(for: s) else { continue }
                choice.apply?.execute()
            case .bool:
                if options[key]?.boolValue == true {
                    def.apply?.execute()
                }
            }
        }
    }

    /// Executes the apply side effect for one option value (called when the
    /// user changes an option in the GUI or via config).
    public func applyOption(app: CatalogApp, optionId: String, value: JSONValue) {
        guard let def = app.options?[optionId] else { return }
        switch def.type {
        case .choice:
            if let s = value.stringValue {
                def.choice(for: s)?.apply?.execute()
            }
        case .bool:
            if value.boolValue == true {
                def.apply?.execute()
            }
        }
    }
}
