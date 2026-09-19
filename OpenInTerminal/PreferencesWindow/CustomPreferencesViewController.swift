//
//  CustomPreferencesViewController.swift
//  OpenInTerminal
//
//  Created by Jianing Wang on 2019/4/21.
//  Copyright © 2019 Jianing Wang. All rights reserved.
//
//  Custom-menu preferences backed by config.json (ConfigStore). The table
//  lists configured menu items; the options section below it is generated
//  dynamically from each item's declared option definitions (AppCatalog),
//  so any app — not only iTerm — can expose per-item options such as
//  Window/Tab. Installed/not-installed lists and the "add" menus are
//  data-driven from the catalog as well.
//

import Cocoa
import OpenInTerminalCore
import UniformTypeIdentifiers

/// Carries the option id + value a generated control writes back.
private final class OptionButton: NSButton {
    var optionId = ""
    var optionValue: JSONValue = .bool(true)
}

private final class OptionPopUpButton: NSPopUpButton {
    var optionId = ""
    var values: [String] = []
}

class CustomPreferencesViewController: PreferencesViewController {

    // MARK: Properties

    @IBOutlet weak var installedApplicationsTextField: NSTextField!
    @IBOutlet weak var notInstalledApplicationsTextField: NSTextField!

    @IBOutlet weak var iTermTextField: NSTextField!
    @IBOutlet weak var iTermWindowButton: NSButton!
    @IBOutlet weak var iTermTabButton: NSButton!

    @IBOutlet weak var customMenuTableView: NSTableView!
    @IBOutlet weak var addMenuOptionButton: NSButton!
    var addOptionMenu: NSMenu = NSMenu()
    @IBOutlet weak var applyToToolbarButton: NSButton!
    @IBOutlet weak var applyToContextButton: NSButton!

    @IBOutlet weak var noIconButton: NSButton!
    @IBOutlet weak var simpleIconButton: NSButton!
    @IBOutlet weak var originalIconButton: NSButton!

    @IBOutlet weak var pathNoButton: NSButton!
    @IBOutlet weak var pathYesButton: NSButton!

    private var dragDropType = NSPasteboard.PasteboardType(rawValue: "private.table-row")

    /// Dynamically generated per-item options section, inserted into the
    /// storyboard stack where the hardcoded iTerm row used to live.
    private let itemOptionsStack = NSStackView()

    var allInstalledAppNames: Set<String> = Set() {
        didSet {
            DispatchQueue.main.async {
                self.refreshSupportedApps()
            }
        }
    }
    var installedSupportedAppNames: [String] = []

    /// The configured menu items (config.json `menu.items`). Mutations are
    /// written back through `persistItems()`.
    var menuItems: [MenuItemConfig] = [] {
        didSet {
            customMenuTableView?.reloadData()
        }
    }
    var runningApps = [App]()

    private var store: ConfigStore { ConfigStore.shared }
    private var catalog: AppCatalog { AppCatalog.shared }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        customMenuTableView.dataSource = self
        customMenuTableView.delegate = self
        customMenuTableView.registerForDraggedTypes([dragDropType])
        installItemOptionsSection()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // fetch installed apps
        DispatchQueue.global(qos: .background).async {
            self.allInstalledAppNames = FinderManager.shared.getAllInstalledApps()
        }
        // get saved custom menu items
        menuItems = store.config.menu?.items ?? []
        refreshSupportedApps()
        refreshCustomButtons()
        refreshIconTypeOptionState()
        rebuildItemOptions()
    }

    // MARK: - Per-item options section

    /// Replaces the storyboard's hardcoded iTerm Window/Tab group with a
    /// dynamically generated section driven by the selected item's option
    /// definitions. The iTerm controls are hidden (the stack detaches them).
    private func installItemOptionsSection() {
        itemOptionsStack.orientation = .vertical
        itemOptionsStack.alignment = .leading
        itemOptionsStack.spacing = 4
        itemOptionsStack.detachesHiddenViews = true
        itemOptionsStack.translatesAutoresizingMaskIntoConstraints = false

        // `iTermTextField` sits inside the hardcoded iTerm group stack;
        // hide that group and occupy its slot in the parent stack.
        guard let itermGroup = iTermTextField?.superview as? NSStackView,
              let parent = itermGroup.superview as? NSStackView else {
            iTermTextField?.superview?.isHidden = true
            return
        }
        let index = parent.arrangedSubviews.firstIndex(of: itermGroup)
            ?? parent.arrangedSubviews.count
        itermGroup.isHidden = true
        parent.insertArrangedSubview(itemOptionsStack, at: index)
    }

    /// Rebuilds the options controls for the currently selected table row.
    func rebuildItemOptions() {
        itemOptionsStack.arrangedSubviews.forEach {
            itemOptionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let row = customMenuTableView.selectedRow
        guard row >= 0, row < menuItems.count else {
            itemOptionsStack.isHidden = true
            return
        }
        itemOptionsStack.isHidden = false
        let item = menuItems[row]
        let title = store.displayTitle(for: item)

        itemOptionsStack.addArrangedSubview(headerField(title))

        // Label override (all item kinds)
        itemOptionsStack.addArrangedSubview(
            textFieldRow(label: NSLocalizedString("pref.custom.item.label", comment: "Label"),
                         value: item.label ?? "",
                         tag: .label))
        // Hidden toggle (all item kinds)
        itemOptionsStack.addArrangedSubview(
            checkbox(title: NSLocalizedString("pref.custom.item.hidden", comment: "Hide this menu item"),
                     state: item.hidden ?? false))

        switch store.resolvedItem(item)?.content {
        case .catalogApp(let catApp):
            addCatalogOptionControls(catApp: catApp, row: row)
        case .customApp(let app, let recipe):
            addInlineAppControls(app: app, recipe: recipe, row: row)
        case .action, .none:
            let hint = descriptionField(
                NSLocalizedString("pref.custom.item.no_options",
                                  comment: "This item has no configurable options."))
            itemOptionsStack.addArrangedSubview(hint)
        }
    }

    /// Generates one control row per declared option definition of the
    /// catalog app (sorted by id for a stable layout).
    private func addCatalogOptionControls(catApp: CatalogApp, row: Int) {
        guard let defs = catApp.options, !defs.isEmpty else {
            itemOptionsStack.addArrangedSubview(descriptionField(
                NSLocalizedString("pref.custom.item.no_options",
                                  comment: "This item has no configurable options.")))
            return
        }
        let values = store.itemOptions(at: row)
        for key in defs.keys.sorted() {
            guard let def = defs[key] else { continue }
            switch def.type {
            case .choice:
                itemOptionsStack.addArrangedSubview(plainLabel(def.label))
                let radios = NSStackView()
                radios.orientation = .horizontal
                radios.spacing = 16
                let current = values[key]?.stringValue ?? def.default?.stringValue
                for choice in def.choices ?? [] {
                    let b = OptionButton(radioButtonWithTitle: choice.label,
                                         target: self,
                                         action: #selector(optionChoiceClicked(_:)))
                    b.optionId = key
                    b.optionValue = .string(choice.value)
                    b.state = (choice.value == current) ? .on : .off
                    radios.addArrangedSubview(b)
                }
                itemOptionsStack.addArrangedSubview(radios)
            case .bool:
                let b = OptionButton(checkboxWithTitle: def.label,
                                     target: self,
                                     action: #selector(optionBoolClicked(_:)))
                b.optionId = key
                b.state = (values[key]?.boolValue ?? def.default?.boolValue ?? false) ? .on : .off
                itemOptionsStack.addArrangedSubview(b)
            }
        }
    }

    /// Inline custom apps expose their open recipe for editing: argv
    /// (space-separated `/usr/bin/open` arguments) and the path mode.
    private func addInlineAppControls(app: App, recipe: OpenRecipe?, row: Int) {
        itemOptionsStack.addArrangedSubview(
            textFieldRow(label: NSLocalizedString("pref.custom.item.open_command", comment: "Open command (open args)"),
                         value: (recipe?.argv ?? ["-a", app.name]).joined(separator: " "),
                         tag: .argv))
        let popup = OptionPopUpButton()
        popup.optionId = "pathMode"
        popup.values = [PathMode.appendFirst, .append, .placeholder, .none].map(\.rawValue)
        popup.addItems(withTitles: popup.values)
        popup.selectItem(withTitle: (recipe?.pathMode
            ?? (app.type == .terminal ? .appendFirst : .append)).rawValue)
        popup.target = self
        popup.action = #selector(pathModeChanged(_:))
        itemOptionsStack.addArrangedSubview(
            labeled(NSLocalizedString("pref.custom.item.path_mode", comment: "Path mode"), control: popup))
    }

    // MARK: Option control actions

    private enum FieldTag: Int { case label = 1, argv = 2 }

    @objc private func optionChoiceClicked(_ sender: OptionButton) {
        guard let row = selectedRow else { return }
        store.setItemOption(at: row, optionId: sender.optionId, value: sender.optionValue)
        syncItemsFromStore()
        rebuildItemOptions()
    }

    @objc private func optionBoolClicked(_ sender: OptionButton) {
        guard let row = selectedRow else { return }
        store.setItemOption(at: row, optionId: sender.optionId,
                            value: .bool(sender.state == .on))
        syncItemsFromStore()
    }

    @objc private func pathModeChanged(_ sender: OptionPopUpButton) {
        guard let row = selectedRow,
              let raw = sender.selectedItem?.title,
              let mode = PathMode(rawValue: raw) else { return }
        mutateItem(at: row) { item in
            guard var app = item.app else { return }
            var recipe = app.open ?? OpenRecipe(argv: ["-a", app.name])
            recipe.pathMode = mode
            app.open = recipe
            item.app = app
        }
    }

    @objc private func hiddenToggled(_ sender: NSButton) {
        guard let row = selectedRow else { return }
        mutateItem(at: row) { $0.hidden = sender.state == .on }
    }

    private var selectedRow: Int? {
        let row = customMenuTableView.selectedRow
        return (row >= 0 && row < menuItems.count) ? row : nil
    }

    /// Applies an in-place mutation to menu.items[row], persists via
    /// ConfigStore, and refreshes the display model + table.
    private func mutateItem(at row: Int, _ mutate: (inout MenuItemConfig) -> Void) {
        store.updateMenu { menu in
            guard var items = menu.items, items.indices.contains(row) else { return }
            mutate(&items[row])
            menu.items = items
        }
        syncItemsFromStore()
    }

    private func syncItemsFromStore() {
        menuItems = store.config.menu?.items ?? []
    }

    private func persistItems() {
        let items = menuItems
        store.updateMenu { $0.items = items }
    }

    // MARK: - Control builders

    private func headerField(_ text: String) -> NSTextField {
        let f = descriptionField(text)
        f.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        f.textColor = .labelColor
        return f
    }

    private func plainLabel(_ text: String) -> NSTextField {
        descriptionField(text)
    }

    private func descriptionField(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        return f
    }

    private func labeled(_ label: String, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(plainLabel(label))
        row.addArrangedSubview(control)
        return row
    }

    private func checkbox(title: String, state: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self,
                         action: #selector(hiddenToggled(_:)))
        b.state = state ? .on : .off
        return b
    }

    private func textFieldRow(label: String, value: String, tag: FieldTag) -> NSStackView {
        let field = NSTextField(string: value)
        field.tag = tag.rawValue
        field.target = self
        field.action = #selector(itemFieldCommitted(_:))
        field.delegate = self
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        return labeled(label, control: field)
    }

    /// NSTextField action (Enter) + delegate end-editing both funnel here.
    @objc private func itemFieldCommitted(_ sender: NSTextField) {
        guard let row = selectedRow else { return }
        switch FieldTag(rawValue: sender.tag) {
        case .label:
            let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
            mutateItem(at: row) { $0.label = text.isEmpty ? nil : text }
        case .argv:
            let tokens = sender.stringValue
                .split(separator: " ").map(String.init)
            mutateItem(at: row) { item in
                guard var app = item.app else { return }
                var recipe = app.open ?? OpenRecipe(argv: [])
                recipe.argv = tokens
                app.open = recipe
                item.app = app
            }
        case .none:
            break
        }
    }

    // MARK: Refresh UI

    func refreshSupportedApps() {
        // catalog-driven lists (replaces the SupportedApps enum)
        let catalogNames = catalog.apps.map(\.name)
        installedSupportedAppNames = catalogNames
            .filter(allInstalledAppNames.contains)
            .sortedIgnoreCase()
        installedApplicationsTextField.stringValue = installedSupportedAppNames.joined(separator: ", ")

        let notInstalledSupportedApps = catalogNames
            .filter { !installedSupportedAppNames.contains($0) }
            .sortedIgnoreCase()
        notInstalledApplicationsTextField.stringValue = notInstalledSupportedApps.joined(separator: ", ")
    }

    func refreshCustomButtons() {
        let isApplyToToolbar = DefaultsManager.shared.isCustomMenuApplyToToolbar
        applyToToolbarButton.state = isApplyToToolbar ? .on : .off

        let isApplyToContext = DefaultsManager.shared.isCustomMenuApplyToContext
        applyToContextButton.state = isApplyToContext ? .on : .off

        let isPathEscaped = DefaultsManager.shared.isPathEscaped
        if isPathEscaped {
            pathYesButton.state = .on
            pathNoButton.state = .off
        } else {
            pathYesButton.state = .off
            pathNoButton.state = .on
        }
    }

    func offIconTypeButtons() {
        noIconButton.state = .off
        simpleIconButton.state = .off
        originalIconButton.state = .off
    }

    func refreshIconTypeOptionState() {
        offIconTypeButtons()
        let option = DefaultsManager.shared.customMenuIconOption
        switch option {
        case .no:
            noIconButton.state = .on
        case .simple:
            simpleIconButton.state = .on
        case .original:
            originalIconButton.state = .on
        }
    }

    func refreshAddOptionMenu() {
        addOptionMenu.removeAllItems()

        // 1. Installed Catalog Apps
        let installedSupportedMenu = NSMenu()
        for name in installedSupportedAppNames {
            let menuItem = NSMenuItem(title: name,
              action: #selector(selectSupportedApp),
              keyEquivalent: "")
            menuItem.target = self
            menuItem.image = catalogIcon(for: name)
            installedSupportedMenu.addItem(menuItem)
        }
        let installedSupportedMenuItem = NSMenuItem()
        installedSupportedMenuItem.title = NSLocalizedString("pref.custom.menu.installed_supported", comment: "Installed Supported Apps")
        addOptionMenu.addItem(installedSupportedMenuItem)
        addOptionMenu.setSubmenu(installedSupportedMenu, for: installedSupportedMenuItem)

        // 2. All Catalog Apps
        let supportedMenu = NSMenu()
        for app in catalog.apps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let menuItem = NSMenuItem(title: app.name,
                                      action: #selector(selectSupportedApp),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.image = catalogIcon(for: app.name)
            supportedMenu.addItem(menuItem)
        }
        let supportedMenuItem = NSMenuItem()
        supportedMenuItem.title = NSLocalizedString("pref.custom.menu.all_supported", comment: "All Supported Apps")
        addOptionMenu.addItem(supportedMenuItem)
        addOptionMenu.setSubmenu(supportedMenu, for: supportedMenuItem)

        // 3. Running Applications
        let runningMenu = NSMenu()
        let runningApplications = NSWorkspace.shared.runningApplications
        runningApps.removeAll()
        for runningApp in runningApplications {
            guard runningApp.activationPolicy == .regular else { continue }
            guard let bundleURL = runningApp.bundleURL else { continue }
            let icon = AppManager.getApplicationIcon(from: bundleURL)
            let name = AppManager.getApplicationFileName(from: bundleURL.path)
            let menuItem = NSMenuItem(title: name,
                                      action: #selector(selectRunningApp),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.image = icon
            menuItem.image?.size = NSSize(width: 14, height: 14)
            runningMenu.addItem(menuItem)
            let app = App(name: name, type: .terminal)
            runningApps.append(app)
        }
        let runningMenuItem = NSMenuItem()
        runningMenuItem.title = NSLocalizedString("pref.custom.menu.running_apps", comment: "Running Apps")
        addOptionMenu.addItem(runningMenuItem)
        addOptionMenu.setSubmenu(runningMenu, for: runningMenuItem)

        // 4. Built-in action: Copy Path
        let copyPathTitle = NSLocalizedString("menu.copy_path_to_clipboard", comment: "Copy path")
        let copyPathItem = NSMenuItem(title: "\(copyPathTitle) (action)",
                                      action: #selector(selectCopyPathAction),
                                      keyEquivalent: "")
        copyPathItem.target = self
        addOptionMenu.addItem(copyPathItem)

        // 5. Manually Select From Finder
        let manuallySelectTitle = NSLocalizedString("pref.custom.menu.manually_select", comment: "Manually Select From Finder")
        let manuallySelectMenuItem = NSMenuItem(title: manuallySelectTitle,
                                                action: #selector(selectManuallySelect),
                                                keyEquivalent: "")
        manuallySelectMenuItem.target = self
        addOptionMenu.addItem(manuallySelectMenuItem)

        // 6. Manually Input
        let manuallyInputTitle = NSLocalizedString("pref.custom.menu.manually_input", comment: "Manually Input")
        let manuallyInputMenuItem = NSMenuItem(title: manuallyInputTitle,
                                                action: #selector(selectManuallyInput),
                                                keyEquivalent: "")
        manuallyInputMenuItem.target = self
        addOptionMenu.addItem(manuallyInputMenuItem)
    }

    private func catalogIcon(for name: String) -> NSImage? {
        let image = NSImage(named: name)
        image?.size = NSSize(width: 14, height: 14)
        return image
    }

    // MARK: Button Actions

    @IBAction func iTermWindowButtonClicked(_ sender: NSButton) {
        iTermTabButton.state = .off
        DefaultsManager.shared.setNewOption(.iTerm, .window)
    }

    @IBAction func iTermTabButtonClicked(_ sender: NSButton) {
        iTermWindowButton.state = .off
        DefaultsManager.shared.setNewOption(.iTerm, .tab)
    }

    @IBAction func pathNoButtonClicked(_ sender: NSButton) {
        pathYesButton.state = .off
        DefaultsManager.shared.isPathEscaped = false
    }

    @IBAction func pathYesButtonClicked(_ sender: NSButton) {
        pathNoButton.state = .off
        DefaultsManager.shared.isPathEscaped = true
    }

    @IBAction func addMenuOptionButtonClicked(_ sender: NSButton) {
        refreshAddOptionMenu()
        let point = NSPoint(x: sender.frame.origin.x, y: sender.frame.origin.y - (sender.frame.height / 2))
        addOptionMenu.popUp(positioning: nil, at: point, in: sender.superview)
    }

    @objc func selectSupportedApp(_ sender: NSMenuItem) {
        let selectedAppName = sender.title
        if let catApp = catalog.apps.first(where: { $0.name == selectedAppName }) {
            menuItems.append(MenuItemConfig(ref: catApp.id))
            persistItems()
        }
    }

    @objc func selectRunningApp(_ sender: NSMenuItem) {
        let selectedAppName = sender.title
        runningApps.forEach {
            if $0.name == selectedAppName {
                showCustomInputViewController($0.name)
            }
        }
    }

    @objc func selectCopyPathAction(_ sender: NSMenuItem) {
        menuItems.append(MenuItemConfig(kind: "action", action: .copyPath))
        persistItems()
    }

    @objc func selectManuallySelect(_ sender: NSMenuItem) {
        openFileSelectPanel()
    }

    @objc func selectManuallyInput(_ sender: NSMenuItem) {
        showCustomInputViewController()
    }

    func addCustomApp(_ app: App) {
        // catalog app → reference; unknown app → inline definition
        if let catApp = catalog.resolve(app: app) {
            menuItems.append(MenuItemConfig(ref: catApp.id))
        } else {
            menuItems.append(MenuItemConfig(
                app: InlineAppDef(name: app.name, type: app.type,
                                  bundleId: app.bundleId)))
        }
        persistItems()
    }

    @IBAction func removeMenuOptionButtonClicked(_ sender: NSButton) {
        let row = customMenuTableView.selectedRow
        guard row >= 0, row < menuItems.count else { return }
        menuItems.remove(at: row)
        persistItems()
        rebuildItemOptions()
    }

    @IBAction func applyToToolbarButtonClicked(_ sender: NSButton) {
        let isApplyTo = applyToToolbarButton.state == .on
        DefaultsManager.shared.isCustomMenuApplyToToolbar = isApplyTo
    }

    @IBAction func applyToContextButtonClicked(_ sender: NSButton) {
        let isApplyTo = applyToContextButton.state == .on
        DefaultsManager.shared.isCustomMenuApplyToContext = isApplyTo
    }

    func showCustomInputViewController(_ appName: String = "") {
        guard let customInputViewController = Constants.PreferencesStoryboard.instantiateController(withIdentifier: Constants.Id.CustomInputViewController) as? CustomInputViewController else {
            return
        }
        if appName != "" {
            customInputViewController.appName = appName
        }
        self.presentAsSheet(customInputViewController)
    }

    @IBAction func noIconButtonClicked(_ sender: NSButton) {
        offIconTypeButtons()
        noIconButton.state = .on
        DefaultsManager.shared.customMenuIconOption = .no
    }

    @IBAction func simpleIconButtonClicked(_ sender: NSButton) {
        offIconTypeButtons()
        simpleIconButton.state = .on
        DefaultsManager.shared.customMenuIconOption = .simple
    }

    @IBAction func originalIconButtonClicked(_ sender: NSButton) {
        offIconTypeButtons()
        originalIconButton.state = .on
        DefaultsManager.shared.customMenuIconOption = .original
    }
}

extension CustomPreferencesViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == customMenuTableView {
            return menuItems.count
        } else {
            return 0
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: self.dragDropType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above {
            return .move
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        var oldIndexes = [Int]()
        info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { dragItem, _, _ in
            if let str = (dragItem.item as! NSPasteboardItem).string(forType: self.dragDropType), let index = Int(str) {
                oldIndexes.append(index)
            }
        }
        var oldIndexOffset = 0
        var newIndexOffset = 0

        menuItems.move(with: IndexSet(oldIndexes), to: row)
        persistItems()

        // For simplicity, the code below uses `tableView.moveRowAtIndex` to move rows around directly.
        // You may want to move rows in your content array and then call `tableView.reloadData()` instead.
        tableView.beginUpdates()
        for oldIndex in oldIndexes {
            if oldIndex < row {
                // ⬇️
                tableView.moveRow(at: oldIndex + oldIndexOffset, to: row - 1)
                oldIndexOffset -= 1
            } else {
                // ⬆️
                tableView.moveRow(at: oldIndex, to: row + newIndexOffset)
                newIndexOffset += 1
            }
        }
        tableView.endUpdates()

        return true
    }

}

extension CustomPreferencesViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let cell = tableView.makeView(withIdentifier: Constants.Id.CustomMenuCell, owner: nil) as? NSTableCellView {
            var title = store.displayTitle(for: menuItems[row])
            if store.resolvedItem(menuItems[row]) == nil {
                let missing = NSLocalizedString("pref.custom.item.unresolved", comment: "unresolved")
                title += " (\(missing))"
            }
            cell.textField?.stringValue = title
            return cell
        }
        return nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        rebuildItemOptions()
    }

}

extension CustomPreferencesViewController: NSTextFieldDelegate {

    func controlTextDidEndEditing(_ obj: Notification) {
        // text fields commit on focus loss too, not only on Enter
        if let field = obj.object as? NSTextField {
            itemFieldCommitted(field)
        }
    }

}

extension CustomPreferencesViewController: NSMenuDelegate {

    func openFileSelectPanel() {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first!
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.applicationBundle]
        openPanel.beginSheetModal(for: view.window!, completionHandler: {
            result in
            if result == NSApplication.ModalResponse.OK {
                if let appPath = openPanel.url?.path,
                   let _ = Bundle(url: openPanel.url!)?.bundleIdentifier {
                    let name = AppManager.getApplicationFileName(from: appPath)
                    self.showCustomInputViewController(name)
                } else {
                    // 对于没有 bundleId 的应用可能是快捷方式, 给予提示
                }
            }
        })
    }

}
