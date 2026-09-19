//
//  FinderSync.swift
//  OpenInTerminalFinderExtension
//
//  Created by Cameron Ingham on 4/17/19.
//  Copyright © 2019 Cameron Ingham. All rights reserved.
//

import Cocoa
import FinderSync
import OpenInTerminalCore
import Carbon

class FinderSync: FIFinderSync {
    
    override init() {
        super.init()
        let finderSync = FIFinderSyncController.default()
        if let mountedVolumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            finderSync.directoryURLs = Set<URL>(mountedVolumes)
        }
        // Monitor volumes
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { notification in
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                finderSync.directoryURLs.insert(volumeURL)
            }
        }
    }

    override var toolbarItemName: String {
        return NSLocalizedString("toolbar.item_name",
                                 comment: "Open in Terminal")
    }
    
    override var toolbarItemToolTip: String {
        return NSLocalizedString("toolbar.item_tooltip",
                                 comment: "Open current directory in Terminal.")
    }
    
    override var toolbarItemImage: NSImage {
        return NSImage(named: "Icon")!
    }
    
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        var menu = NSMenu(title: "")

        let dm = DefaultsManager.shared
        OITLog.menu.info("menu kind=\(menuKind.rawValue) bundle=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public) suiteKeys=\(Defaults.dictionaryRepresentation().count) hideCtx=\(dm.isHideContextMenuItems) submenu=\(dm.isContextMenuUseSubmenu) pin=\(dm.isContextMenuPinDefaultTerminal) customCtx=\(dm.isCustomMenuApplyToContext) customTb=\(dm.isCustomMenuApplyToToolbar)")
        OITLog.menu.info("defTerm=\(dm.defaultTerminal?.name ?? "nil", privacy: .public) defEditor=\(dm.defaultEditor?.name ?? "nil", privacy: .public) customApps=\(dm.customMenuOptions?.count ?? -1) items=\(ConfigStore.shared.resolvedItems().count) configIssues=\(ConfigStore.shared.issues.count)")

        switch menuKind {

        case .contextualMenuForContainer,
             .contextualMenuForItems:
            // need to hide or not
            let isHideContextMenuItems = DefaultsManager.shared.isHideContextMenuItems
            guard !isHideContextMenuItems else { return NSMenu() }

            // the submenu grouping only applies to the Finder context menu
            let useSubmenu = DefaultsManager.shared.isContextMenuUseSubmenu

            // show custom menu or default
            let isCustomMenuApplyToContext = DefaultsManager.shared.isCustomMenuApplyToContext
            if isCustomMenuApplyToContext {
                menu = createCustomMenu(useSubmenu: useSubmenu)
            } else {
                menu = createDefaultMenu(useSubmenu: useSubmenu)
            }

        case .toolbarItemMenu:
            // the toolbar menu never groups items into a submenu
            let isCustomMenuApplyToToolbar = DefaultsManager.shared.isCustomMenuApplyToToolbar
            if isCustomMenuApplyToToolbar {
                menu = createCustomMenu(useSubmenu: false)
            } else {
                menu = createDefaultMenu(useSubmenu: false)
            }
            
        default:
            break
        }

        let titles = menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: " | ")
        if menu.items.isEmpty {
            OITLog.menu.error("menu kind=\(menuKind.rawValue) -> 0 items")
        } else {
            OITLog.menu.notice("menu kind=\(menuKind.rawValue) -> \(menu.items.count) items: \(titles, privacy: .public)")
        }
        return menu
    }
    
    var scriptPath: URL? {
        return try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    func fileScriptPath(fileName: String) -> URL? {
        return scriptPath?
            .appendingPathComponent(fileName)
            .appendingPathExtension("scpt")
    }
    
    var copyPathItem: NSMenuItem {
        get {
            let copyPathItem = NSMenuItem(title: NSLocalizedString("menu.copy_path_to_clipboard",
                                                                   comment: "Copy path to Clipboard"),
                                                action: #selector(copyPathToClipboard),
                                                keyEquivalent: "")
            if DefaultsManager.shared.customMenuIconOption == .simple {
                let copyPathIcon = NSImage(named: "context_menu_icon_path")
                copyPathItem.image = copyPathIcon
            } else if DefaultsManager.shared.customMenuIconOption == .original {
                let copyPathIcon = NSImage(named: "context_menu_icon_color_path")
                copyPathItem.image = copyPathIcon
            }
            return copyPathItem
        }
    }
    
    /// Wraps the given items into a single "Open in..." submenu.
    func makeSubmenuItem(with itemsMenu: NSMenu) -> NSMenuItem {
        let submenuItem = NSMenuItem(title: NSLocalizedString("menu.submenu_title",
                                                              comment: "Open in..."),
                                     action: nil,
                                     keyEquivalent: "")
        submenuItem.submenu = itemsMenu
        return submenuItem
    }

    /// Builds the menu item that opens the default terminal. Used by the
    /// default menu and by the custom menu when pinning is enabled.
    func makeDefaultTerminalItem() -> NSMenuItem? {
        guard let terminal = DefaultsManager.shared.defaultTerminal else { return nil }
        let openInTerminalItem = NSMenuItem(title: terminal.name,
                                            action: #selector(openDefaultTerminal),
                                            keyEquivalent: "")
        openInTerminalItem.image = DefaultsManager.shared.getAppIcon(terminal)
        return openInTerminalItem
    }

    func createDefaultMenu(useSubmenu: Bool) -> NSMenu {
        let menu = NSMenu(title: "")

        // when submenu grouping is enabled, add the items into a separate
        // menu that will be attached under a single top level item
        let itemsMenu = useSubmenu ? NSMenu(title: "") : menu

        // when pinning is enabled, the default terminal stays at the top
        // level instead of being grouped into the submenu
        let pinDefault = DefaultsManager.shared.isContextMenuPinDefaultTerminal

        guard let openInTerminalItem = makeDefaultTerminalItem() else { return menu }
        (pinDefault ? menu : itemsMenu).addItem(openInTerminalItem)

        guard let editor = DefaultsManager.shared.defaultEditor else { return menu }
        let editorTitle = editor.name
        let openInEditorItem = NSMenuItem(title: editorTitle,
                                            action: #selector(openDefaultEditor),
                                            keyEquivalent: "")
        let editorIcon = DefaultsManager.shared.getAppIcon(editor)
        openInEditorItem.image = editorIcon
        itemsMenu.addItem(openInEditorItem)

        // add "Copy Path"
        itemsMenu.addItem(self.copyPathItem)

        // attach the items menu under a single top level item when needed
        if useSubmenu {
            if pinDefault {
                menu.addItem(.separator())
            }
            menu.addItem(makeSubmenuItem(with: itemsMenu))
        }

        return menu
    }

    func createCustomMenu(useSubmenu: Bool) -> NSMenu {
        let menu = NSMenu(title: "")

        // resolved menu items from config.json (catalog refs, inline custom
        // apps, and built-in action items, in configured order); when the
        // config has no items, fall back to legacy CustomMenuOptions so an
        // unmigrated or deleted config.json never produces an empty menu
        var resolved = ConfigStore.shared.resolvedItems().filter { !$0.hidden }
        if resolved.isEmpty, let legacy = DefaultsManager.shared.customMenuOptions {
            resolved = legacy.map { app in
                let cat = AppCatalog.shared.resolve(app: app)
                return ResolvedMenuItem(
                    content: cat.map { .catalogApp($0) } ?? .customApp(app, nil),
                    title: app.name,
                    options: [:],
                    hidden: false,
                    source: MenuItemConfig(ref: cat?.id,
                                           app: cat == nil ? InlineAppDef(name: app.name, type: app.type, bundleId: app.bundleId, open: nil) : nil))
            }
        }
        guard !resolved.isEmpty,
              resolved.contains(where: { $0.app != nil }) else {
            return menu
        }

        // when submenu grouping is enabled, add the items into a separate
        // menu that will be attached under a single top level item
        let itemsMenu = useSubmenu ? NSMenu(title: "") : menu

        // when pinning is enabled, the default terminal is shown as the
        // first top-level item, above the custom apps or their submenu
        if DefaultsManager.shared.isContextMenuPinDefaultTerminal,
           let terminalItem = makeDefaultTerminalItem() {
            menu.addItem(terminalItem)
            menu.addItem(.separator())
        }

        var hasCopyPath = false
        for (index, item) in resolved.enumerated() {
            switch item.content {
            case .action(.copyPath):
                hasCopyPath = true
                itemsMenu.addItem(self.copyPathItem)
            case .catalogApp, .customApp:
                guard let app = item.app else { continue }
                let menuItem = NSMenuItem(title: item.title,
                                          action: #selector(customMenuItemClicked),
                                          keyEquivalent: "")
                menuItem.image = DefaultsManager.shared.getAppIcon(app)
                menuItem.representedObject = index
                itemsMenu.addItem(menuItem)
            }
        }

        // keep "Copy Path" appended unless the config placed it explicitly
        if !hasCopyPath {
            itemsMenu.addItem(self.copyPathItem)
        }

        // attach the items menu under a single top level item when needed
        if useSubmenu {
            menu.addItem(makeSubmenuItem(with: itemsMenu))
        }

        return menu
    }

    // MARK: - Actions
    
    func getSelectedPathsFromFinder() -> [URL] {
        var urls = [URL]()
        if let items = FIFinderSyncController.default().selectedItemURLs(), items.count > 0 {
            items.forEach {
                urls.append($0)
            }
        } else if let url = FIFinderSyncController.default().targetedURL() {
            urls.append(url)
        }
        return urls
    }
    
    func open(_ app: App) {
        let urls = getSelectedPathsFromFinder()
        do {
            try app.openInSandbox(urls)
        } catch {
            logw("Failed to open \(app.name) with \(urls)")
        }
    }

    /// Opens a resolved menu item: uses the item's effective open recipe
    /// (per-item options may select a variant, e.g. Terminal's tab script).
    func open(_ item: ResolvedMenuItem) {
        guard let app = item.app else { return }
        let urls = getSelectedPathsFromFinder()
        do {
            try app.openInSandbox(urls, recipe: item.openRecipe)
            OITLog.action.info("open '\(item.title, privacy: .public)' recipe argv=\(item.openRecipe.argv.joined(separator: " "), privacy: .public) script=\(item.openRecipe.script ?? "general", privacy: .public)")
        } catch {
            OITLog.action.error("open '\(item.title, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
//    func openTerminal(_ terminal: TerminalType) {
//        var scriptPath: URL
//        if terminal == .terminal,
//            let newOption = DefaultsManager.shared.getNewOption(.terminal),
//            newOption == .tab {
//            guard let fileScriptPath = fileScriptPath(fileName: terminal.rawValue + "-tab") else { return }
//            scriptPath = fileScriptPath
//        } else {
//            guard let fileScriptPath = fileScriptPath(fileName: terminal.rawValue) else { return }
//            scriptPath = fileScriptPath
//        }
//        guard FileManager.default.fileExists(atPath: scriptPath.path) else { return }
//        guard let script = try? NSUserAppleScriptTask(url: scriptPath) else { return }
//        script.execute(completionHandler: nil)
//    }
//
//    func openEditor(_ editor: EditorType) {
//        if (editor == .vscode) {
//            var path = "open -a Visual\\ Studio\\ Code"
//            if let items = FIFinderSyncController.default().selectedItemURLs(), items.count > 0 {
//                items.forEach { (url) in
//                    path += " \(url.path.specialCharEscaped2)"
//                }
//            } else if let url = FIFinderSyncController.default().targetedURL() {
//                path = url.path.specialCharEscaped2
//            } else {
//                return
//            }
//            let appleScript = try! NSUserAppleScriptTask(url: fileScriptPath(fileName: editor.rawValue)!)
//            appleScript.execute(withAppleEvent: getScriptEvent(functionName: "openVSCode", path)) { (appleEvent, error) in
//                if let error = error {
//                    print(error)
//                }
//            }
//        } else {
//            guard let scriptPath = fileScriptPath(fileName: editor.rawValue) else { return }
//            guard FileManager.default.fileExists(atPath: scriptPath.path) else { return }
//            guard let script = try? NSUserAppleScriptTask(url: scriptPath) else { return }
//            script.execute(completionHandler: nil)
//        }
//    }
    
    // MARK: - Menu Actions
    
    @objc func openDefaultTerminal() {
        guard let terminal = DefaultsManager.shared.defaultTerminal else { return }
        open(terminal)
    }
    
    @objc func openDefaultEditor() {
        guard let editor = DefaultsManager.shared.defaultEditor else { return }
        open(editor)
    }
    
    @objc func customMenuItemClicked(_ sender: NSMenuItem) {
        let resolved = ConfigStore.shared.resolvedItems().filter { !$0.hidden }
        guard let index = sender.representedObject as? Int,
              resolved.indices.contains(index) else { return }
        open(resolved[index])
    }
    
    @objc func copyPathToClipboard() {
        let urls = getSelectedPathsFromFinder()
        var paths = urls.map { $0.path }
        if DefaultsManager.shared.isPathEscaped {
            paths = paths.map { $0.specialCharEscaped() }
        }
        let pathString = paths.joined(separator: "\n")
        // Set string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pathString, forType: .string)
    }
    
}

fileprivate extension String {
    
    subscript(_ range: CountableRange<Int>) -> String {
        let start = index(startIndex, offsetBy: max(0, range.lowerBound))
        let end = index(start, offsetBy: min(self.count - range.lowerBound,
                                             range.upperBound - range.lowerBound))
        return String(self[start..<end])
    }

    subscript(_ range: CountablePartialRangeFrom<Int>) -> String {
        let start = index(startIndex, offsetBy: max(0, range.lowerBound))
         return String(self[start...])
    }
    
}
