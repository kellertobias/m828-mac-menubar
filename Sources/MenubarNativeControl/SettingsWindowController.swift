import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let client: MOTUClient
    private var configuration: AppConfiguration
    private var sessionBaselineConfiguration: AppConfiguration

    private let rootStack = NSStackView()
    private let hostField = NSTextField()
    private let meterUpdateRateField = NSTextField()
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Enable auto-start", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let menuSummaryLabel = NSTextField(labelWithString: "")
    private let menuTableView = NSTableView()
    private var menuItems: [MenuLayoutItem] = []
    private var mixerScanWindowController: MixerScanWindowController?
    private var activePopover: NSPopover?
    private var autosaveWorkItem: DispatchWorkItem?
    private var isPopulatingFields = false

    private let menuPasteboardType = NSPasteboard.PasteboardType("com.keller.menubar-native-control.menu-item")

    init(client: MOTUClient) {
        self.client = client
        self.configuration = PreferencesStore.shared.load()
        self.sessionBaselineConfiguration = configuration

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MOTU 828ES Control Settings"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true {
            beginSettingsSession()
        }
        super.showWindow(sender)
    }

    private func beginSettingsSession() {
        configuration = PreferencesStore.shared.load()
        sessionBaselineConfiguration = configuration
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        reloadMenuItemsFromConfiguration()
        populateGeneralFields()
        statusLabel.stringValue = "Changes apply immediately and persist when this settings window closes."
    }

    func windowWillClose(_ notification: Notification) {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil

        stageCurrentSettings(status: "Saved.", normalizeMeterField: true)
        persistCurrentSettings()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else {
            return
        }

        rootStack.orientation = .horizontal
        rootStack.alignment = .top
        rootStack.distribution = .fill
        rootStack.spacing = 24
        rootStack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        let leftPane = makeLeftPane()
        let rightPane = makeMenuLayoutPane()
        rootStack.addArrangedSubview(leftPane)
        rootStack.addArrangedSubview(rightPane)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            leftPane.widthAnchor.constraint(equalToConstant: 380)
        ])

        reloadMenuItemsFromConfiguration()
        populateGeneralFields()
    }

    private func makeLeftPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeGeneralSection())
        stack.addArrangedSubview(makeActionRow())
        return stack
    }

    private func makeGeneralSection() -> NSView {
        let stack = sectionStack(title: "Mixer")

        let hostLabel = label("Mixer IP or host")
        hostField.placeholderString = "192.168.1.100"
        hostField.delegate = self
        hostField.translatesAutoresizingMaskIntoConstraints = false
        hostField.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let scanButton = NSButton(title: "Scan Mixer I/O", target: self, action: #selector(scanMixerIO))
        scanButton.bezelStyle = .rounded

        let scanSourcesButton = NSButton(title: "Scan Control Sources", target: self, action: #selector(scanControlSources))
        scanSourcesButton.bezelStyle = .rounded

        let scanRow = rowStack()
        scanRow.addArrangedSubview(scanButton)
        scanRow.addArrangedSubview(scanSourcesButton)

        let meterLabel = label("Meter updates/sec")
        meterUpdateRateField.placeholderString = "20"
        meterUpdateRateField.delegate = self
        meterUpdateRateField.translatesAutoresizingMaskIntoConstraints = false
        meterUpdateRateField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let meterHint = NSTextField(labelWithString: "Default 20. Minimum 20. Meters update only while the menu is open.")
        meterHint.font = .systemFont(ofSize: 12)
        meterHint.textColor = .secondaryLabelColor
        meterHint.lineBreakMode = .byWordWrapping
        meterHint.maximumNumberOfLines = 0
        meterHint.translatesAutoresizingMaskIntoConstraints = false
        meterHint.widthAnchor.constraint(equalToConstant: 285).isActive = true

        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged(_:))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(equalToConstant: 330).isActive = true
        statusLabel.stringValue = "Endpoint fields accept relative paths, absolute URLs, or URL templates containing {value}."

        stack.addArrangedSubview(hostLabel)
        stack.addArrangedSubview(hostField)
        stack.addArrangedSubview(scanRow)
        stack.addArrangedSubview(meterLabel)
        stack.addArrangedSubview(meterUpdateRateField)
        stack.addArrangedSubview(meterHint)
        stack.addArrangedSubview(launchAtLoginButton)
        stack.addArrangedSubview(statusLabel)
        return stack
    }

    private func makeMenuLayoutPane() -> NSView {
        let stack = sectionStack(title: "Menu Layout")
        stack.alignment = .leading
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        menuSummaryLabel.textColor = .secondaryLabelColor
        menuSummaryLabel.font = .systemFont(ofSize: 12)
        menuSummaryLabel.lineBreakMode = .byWordWrapping
        menuSummaryLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(menuSummaryLabel)

        let buttonRow = rowStack()
        let addSectionButton = NSButton(title: "Add Section", target: self, action: #selector(addMenuSection))
        addSectionButton.bezelStyle = .rounded
        let addControlButton = NSButton(title: "Add Control", target: self, action: #selector(addMenuControl))
        addControlButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(addSectionButton)
        buttonRow.addArrangedSubview(addControlButton)
        stack.addArrangedSubview(buttonRow)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .menuItemColumn)
        column.resizingMask = .autoresizingMask
        column.minWidth = 560
        column.width = 680
        menuTableView.addTableColumn(column)
        menuTableView.headerView = nil
        menuTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        menuTableView.rowHeight = 52
        menuTableView.intercellSpacing = NSSize(width: 0, height: 1)
        menuTableView.dataSource = self
        menuTableView.delegate = self
        menuTableView.registerForDraggedTypes([menuPasteboardType])
        menuTableView.setDraggingSourceOperationMask(.move, forLocal: true)
        menuTableView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = menuTableView

        stack.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        scrollView.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
        menuTableView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        return stack
    }

    private func makeActionRow() -> NSView {
        let row = rowStack()
        row.alignment = .centerY
        row.spacing = 10

        let revertButton = NSButton(title: "Revert", target: self, action: #selector(revertSettingsSession))
        revertButton.bezelStyle = .rounded

        let resetButton = NSButton(title: "Reset Defaults", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded

        row.addArrangedSubview(revertButton)
        row.addArrangedSubview(resetButton)
        return row
    }

    private func sectionStack(title: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(titleLabel)
        return stack
    }

    private func rowStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }

    @objc private func saveSettings() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        stageCurrentSettings(status: "Saved.", normalizeMeterField: true)
        persistCurrentSettings()
    }

    private func stageCurrentSettings(status: String, normalizeMeterField: Bool = false) {
        syncGeneralFields(normalizeMeterField: normalizeMeterField)
        configuration.channels = []
        configuration.specials = []
        configuration.controlSections = currentMenuSections()
        postStagedConfigurationChange()
        statusLabel.stringValue = status
    }

    private func persistCurrentSettings() {
        do {
            try LoginItemManager.setEnabled(configuration.launchAtLogin)
        } catch {
            showAlert(title: "Auto-start could not be changed", message: error.localizedDescription)
            configuration.launchAtLogin = LoginItemManager.isEnabled
            launchAtLoginButton.state = configuration.launchAtLogin ? .on : .off
        }

        PreferencesStore.shared.save(configuration)
    }

    private func postStagedConfigurationChange() {
        NotificationCenter.default.post(name: .appConfigurationDidChange, object: configuration)
    }

    private func scheduleAutosave(delay: TimeInterval = 0.45, normalizeMeterField: Bool = false) {
        guard !isPopulatingFields else {
            return
        }

        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.autosaveWorkItem = nil
                self?.stageCurrentSettings(
                    status: "Autosaved for this settings session.",
                    normalizeMeterField: normalizeMeterField
                )
            }
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @objc private func resetDefaults() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        configuration = .defaults
        reloadMenuItemsFromConfiguration()
        populateGeneralFields()
        stageCurrentSettings(status: "Defaults staged for this settings session.", normalizeMeterField: true)
    }

    @objc private func revertSettingsSession() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        configuration = sessionBaselineConfiguration
        reloadMenuItemsFromConfiguration()
        populateGeneralFields()
        postStagedConfigurationChange()
        statusLabel.stringValue = "Reverted to the settings from when this window opened."
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        statusLabel.stringValue = sender.state == .on
            ? "Auto-start will be enabled."
            : "Auto-start will be disabled."
        scheduleAutosave(delay: 0)
    }

    @objc private func scanMixerIO() {
        syncGeneralFields()
        let host = configuration.mixerHost
        guard !host.isEmpty else {
            statusLabel.stringValue = "Enter the mixer IP before scanning."
            return
        }

        statusLabel.stringValue = "Scanning mixer inputs and outputs..."
        client.scanMixerIO(host: host) { [weak self] endpoints in
            guard let self else { return }
            if self.mixerScanWindowController == nil {
                self.mixerScanWindowController = MixerScanWindowController()
            }
            self.mixerScanWindowController?.show(endpoints: endpoints, host: host)
            self.statusLabel.stringValue = endpoints.isEmpty
                ? "Scan finished. No named inputs or outputs found."
                : "Scan finished. Found \(endpoints.count) named mixer endpoints."
        }
    }

    @objc private func scanControlSources() {
        syncGeneralFields()
        let host = configuration.mixerHost
        guard !host.isEmpty else {
            statusLabel.stringValue = "Enter the mixer IP before scanning control sources."
            return
        }

        configuration.controlSections = currentMenuSections()
        statusLabel.stringValue = "Scanning available control sources..."
        client.scanControlSources(host: host) { [weak self] sources in
            guard let self else { return }
            self.configuration.controlSources = sources
            self.postStagedConfigurationChange()
            self.reloadMenuItemsFromConfiguration()

            let count = sources.reduce(0) { $0 + $1.controls.count }
            self.statusLabel.stringValue = sources.isEmpty
                ? "No control sources found. Manual endpoint rows are still available."
                : "Scanned \(sources.count) sources with \(count) available controls. Add the ones you want."
        }
    }

    @objc private func addMenuSection() {
        menuItems.append(.section(MenuSectionListItem(title: "New Section", isEnabled: true)))
        reloadMenuTable(selecting: menuItems.count - 1)
        scheduleAutosave(delay: 0)
    }

    @objc private func addMenuControl() {
        if menuItems.first(where: { $0.isSection }) == nil {
            menuItems.append(.section(MenuSectionListItem(title: "Menu Section", isEnabled: true)))
        }
        menuItems.append(.control(defaultMenuControl()))
        reloadMenuTable(selecting: menuItems.count - 1)
        updateMenuLayoutSummary()
        scheduleAutosave(delay: 0)
    }

    @objc private func editMenuItem(_ sender: NSButton) {
        let row = menuTableView.row(for: sender)
        guard menuItems.indices.contains(row) else {
            return
        }
        showEditor(forRow: row, relativeTo: sender)
    }

    @objc private func deleteMenuItem(_ sender: NSButton) {
        let row = menuTableView.row(for: sender)
        guard menuItems.indices.contains(row) else {
            return
        }
        menuItems.remove(at: row)
        reloadMenuTable(selecting: min(row, menuItems.count - 1))
        scheduleAutosave(delay: 0)
    }

    private func showEditor(forRow row: Int, relativeTo view: NSView) {
        activePopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 480, height: 360)

        switch menuItems[row] {
        case .section(let section):
            let editor = MenuSectionEditorViewController(section: section) { [weak self, weak popover] updated in
                guard let self else { return }
                self.menuItems[row] = .section(updated)
                self.reloadMenuTable(selecting: row)
                self.scheduleAutosave(delay: 0)
                popover?.close()
            }
            popover.contentViewController = editor
        case .control(let control):
            let editor = MenuControlEditorViewController(
                control: control,
                sources: configuration.controlSources
            ) { [weak self, weak popover] updated in
                guard let self else { return }
                self.menuItems[row] = .control(updated)
                self.reloadMenuTable(selecting: row)
                self.scheduleAutosave(delay: 0)
                popover?.close()
            }
            popover.contentViewController = editor
        }

        activePopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
    }

    private func populateGeneralFields() {
        isPopulatingFields = true
        hostField.stringValue = configuration.mixerHost
        meterUpdateRateField.stringValue = Self.formatMeterUpdateRate(configuration.pollingInterval)
        launchAtLoginButton.state = configuration.launchAtLogin ? .on : .off
        updateMenuLayoutSummary()
        isPopulatingFields = false
    }

    private func reloadMenuItemsFromConfiguration() {
        menuItems = configuration.controlSections.flatMap { section -> [MenuLayoutItem] in
            [.section(MenuSectionListItem(id: section.id, title: section.title, isEnabled: section.isEnabled))]
                + section.controls.map(MenuLayoutItem.control)
        }
        reloadMenuTable()
    }

    private func reloadMenuTable(selecting selectedRow: Int? = nil) {
        menuTableView.reloadData()
        updateMenuLayoutSummary()
        guard let selectedRow, menuItems.indices.contains(selectedRow) else {
            return
        }
        menuTableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        menuTableView.scrollRowToVisible(selectedRow)
    }

    private func updateMenuLayoutSummary() {
        let sourceControlCount = configuration.controlSources.reduce(0) { $0 + $1.controls.count }
        let sectionCount = menuItems.filter(\.isSection).count
        let controlCount = menuItems.filter(\.isControl).count
        if configuration.controlSources.isEmpty {
            menuSummaryLabel.stringValue = controlCount == 0
                ? "No control sources scanned. Scan sources, then add the sections and controls you want in the menu."
                : "\(controlCount) manual controls are currently placed across \(sectionCount) sections."
        } else {
            menuSummaryLabel.stringValue = "\(configuration.controlSources.count) sources and \(sourceControlCount) controls available. \(controlCount) controls are currently placed across \(sectionCount) sections."
        }
    }

    private func currentMenuSections() -> [MixerControlSectionConfig] {
        var sections: [MixerControlSectionConfig] = []
        var currentSection: MixerControlSectionConfig?

        func appendCurrentSection() {
            if let currentSection {
                sections.append(currentSection)
            }
        }

        for item in menuItems {
            switch item {
            case .section(let section):
                appendCurrentSection()
                currentSection = MixerControlSectionConfig(
                    id: section.id,
                    title: section.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Menu Section",
                    isEnabled: section.isEnabled,
                    controls: []
                )
            case .control(let control):
                if currentSection == nil {
                    currentSection = MixerControlSectionConfig(title: "Menu Section", controls: [])
                }
                currentSection?.controls.append(control)
            }
        }

        appendCurrentSection()
        return sections
    }

    private func syncGeneralFields(normalizeMeterField: Bool = false) {
        configuration.mixerHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.launchAtLogin = launchAtLoginButton.state == .on
        configuration.pollingInterval = Self.pollingInterval(fromMeterUpdateRate: meterUpdateRateField.stringValue)
        if normalizeMeterField {
            meterUpdateRateField.stringValue = Self.formatMeterUpdateRate(configuration.pollingInterval)
        }
    }

    private static func pollingInterval(fromMeterUpdateRate value: String) -> TimeInterval {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let requestedRate = Double(normalized) ?? 20
        let clampedRate = min(max(requestedRate, 20), 30)
        return 1.0 / clampedRate
    }

    private static func formatMeterUpdateRate(_ interval: TimeInterval) -> String {
        guard interval > 0 else {
            return "20"
        }
        let rate = min(max(1.0 / interval, 20), 30)
        if abs(rate.rounded() - rate) < 0.05 {
            return "\(Int(rate.rounded()))"
        }
        return String(format: "%.1f", rate)
    }

    private func defaultMenuControl() -> MixerControlConfig {
        if let source = configuration.controlSources.first, let control = source.controls.first {
            return control.copyForMenu(sourceID: source.id)
        }

        return MixerControlConfig(
            title: "Manual Control",
            kind: .slider,
            displayStyle: .simpleFader,
            sourceID: MenuControlEditorViewController.manualSourceID,
            controlID: MenuControlEditorViewController.manualSliderControlID,
            endpoint: ""
        )
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        menuItems.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch menuItems[row] {
        case .section:
            return 46
        case .control:
            return 58
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard menuItems.indices.contains(row) else {
            return nil
        }

        switch menuItems[row] {
        case .section(let section):
            return makeSectionTableCell(section: section)
        case .control(let control):
            return makeControlTableCell(control: control)
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: menuPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row targetRow: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let sourceString = info.draggingPasteboard.string(forType: menuPasteboardType),
              let sourceRow = Int(sourceString),
              menuItems.indices.contains(sourceRow) else {
            return false
        }

        var adjustedTarget = targetRow
        let item = menuItems.remove(at: sourceRow)
        if sourceRow < adjustedTarget {
            adjustedTarget -= 1
        }
        adjustedTarget = min(max(adjustedTarget, 0), menuItems.count)
        menuItems.insert(item, at: adjustedTarget)
        reloadMenuTable(selecting: adjustedTarget)
        scheduleAutosave(delay: 0)
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleAutosave()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        scheduleAutosave(delay: 0, normalizeMeterField: true)
    }

    private func makeSectionTableCell(section: MenuSectionListItem) -> NSView {
        let cell = NSTableCellView()
        let row = rowStack()
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)

        let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        enabled.state = section.isEnabled ? .on : .off
        enabled.isEnabled = false
        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let editButton = NSButton(title: "Edit", target: self, action: #selector(editMenuItem(_:)))
        editButton.bezelStyle = .rounded
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteMenuItem(_:)))
        deleteButton.bezelStyle = .rounded
        let actions = rightAlignedMenuActions()
        actions.addArrangedSubview(editButton)
        actions.addArrangedSubview(deleteButton)

        row.addArrangedSubview(NSTextField(labelWithString: "|||"))
        row.addArrangedSubview(enabled)
        row.addArrangedSubview(title)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(actions)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            row.topAnchor.constraint(equalTo: cell.topAnchor),
            row.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
        ])
        return cell
    }

    private func makeControlTableCell(control: MixerControlConfig) -> NSView {
        let cell = NSTableCellView()
        let row = rowStack()
        row.edgeInsets = NSEdgeInsets(top: 5, left: 24, bottom: 5, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let title = NSTextField(labelWithString: control.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: control.endpoint.isEmpty ? "No endpoint configured" : control.endpoint)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(detail)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let style = NSTextField(labelWithString: control.displayStyle.rawValue)
        style.font = .systemFont(ofSize: 11)
        style.textColor = .secondaryLabelColor
        style.alignment = .right
        style.translatesAutoresizingMaskIntoConstraints = false
        style.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let editButton = NSButton(title: "Edit", target: self, action: #selector(editMenuItem(_:)))
        editButton.bezelStyle = .rounded
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteMenuItem(_:)))
        deleteButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailingControls = rightAlignedMenuActions()
        trailingControls.addArrangedSubview(style)
        trailingControls.addArrangedSubview(editButton)
        trailingControls.addArrangedSubview(deleteButton)

        row.addArrangedSubview(NSTextField(labelWithString: "|||"))
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(trailingControls)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            row.topAnchor.constraint(equalTo: cell.topAnchor),
            row.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
        ])
        return cell
    }

    private func rightAlignedMenuActions() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    fileprivate struct MenuSectionListItem {
        var id: UUID = UUID()
        var title: String
        var isEnabled: Bool
    }

    private enum MenuLayoutItem {
        case section(MenuSectionListItem)
        case control(MixerControlConfig)

        var isSection: Bool {
            if case .section = self { return true }
            return false
        }

        var isControl: Bool {
            if case .control = self { return true }
            return false
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let menuItemColumn = NSUserInterfaceItemIdentifier("menuItemColumn")
}

@MainActor
private final class MenuSectionEditorViewController: NSViewController {
    private let titleField: NSTextField
    private let enabledButton: NSButton
    private let onApply: (SettingsWindowController.MenuSectionListItem) -> Void
    private let sectionID: UUID

    init(
        section: SettingsWindowController.MenuSectionListItem,
        onApply: @escaping (SettingsWindowController.MenuSectionListItem) -> Void
    ) {
        self.sectionID = section.id
        self.titleField = NSTextField(string: section.title)
        self.enabledButton = NSButton(checkboxWithTitle: "Show section in menu", target: nil, action: nil)
        self.enabledButton.state = section.isEnabled ? .on : .off
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = editorStack(title: "Edit Section")
        stack.addArrangedSubview(label("Title"))
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalToConstant: 390).isActive = true
        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(enabledButton)
        let button = applyButton(action: #selector(apply))
        button.target = self
        stack.addArrangedSubview(button)
        view = paddedEditorView(containing: stack)
    }

    @objc private func apply() {
        onApply(SettingsWindowController.MenuSectionListItem(
            id: sectionID,
            title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Menu Section",
            isEnabled: enabledButton.state == .on
        ))
    }
}

@MainActor
private final class MenuControlEditorViewController: NSViewController {
    static let manualSourceID = "__manual__"
    static let manualSliderControlID = "__manual_slider__"
    static let manualToggleControlID = "__manual_toggle__"

    private let controlID: UUID
    private let sources: [MixerControlSourceConfig]
    private let sourcePopUp = NSPopUpButton()
    private let controlPopUp = NSPopUpButton()
    private let titleField: NSTextField
    private let endpointField: NSTextField
    private let minValueField: NSTextField
    private let maxValueField: NSTextField
    private let onApply: (MixerControlConfig) -> Void

    init(
        control: MixerControlConfig,
        sources: [MixerControlSourceConfig],
        onApply: @escaping (MixerControlConfig) -> Void
    ) {
        self.controlID = control.id
        self.sources = sources
        self.titleField = NSTextField(string: control.title)
        self.endpointField = NSTextField(string: control.endpoint)
        self.minValueField = NSTextField(string: Self.formatValue(control.minValue))
        self.maxValueField = NSTextField(string: Self.formatValue(control.maxValue))
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
        reloadSources(selectedSourceID: control.sourceID)
        reloadControls(selectedControlID: control.controlID, fallbackKind: control.kind)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = editorStack(title: "Edit Control")
        stack.addArrangedSubview(label("Source"))
        stack.addArrangedSubview(sourcePopUp)
        stack.addArrangedSubview(label("Control"))
        stack.addArrangedSubview(controlPopUp)
        stack.addArrangedSubview(label("Menu label"))
        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(label("Endpoint"))
        stack.addArrangedSubview(endpointField)

        let rangeRow = NSStackView()
        rangeRow.orientation = .horizontal
        rangeRow.alignment = .centerY
        rangeRow.spacing = 8
        minValueField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        maxValueField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        rangeRow.addArrangedSubview(label("Min"))
        rangeRow.addArrangedSubview(minValueField)
        rangeRow.addArrangedSubview(label("Max"))
        rangeRow.addArrangedSubview(maxValueField)
        stack.addArrangedSubview(rangeRow)

        let button = applyButton(action: #selector(apply))
        button.target = self
        stack.addArrangedSubview(button)
        for field in [sourcePopUp, controlPopUp, titleField, endpointField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 390).isActive = true
        }
        view = paddedEditorView(containing: stack)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)
        controlPopUp.target = self
        controlPopUp.action = #selector(controlChanged)
    }

    @objc private func sourceChanged() {
        reloadControls(selectedControlID: "", fallbackKind: .slider)
        applySelectedCatalogControl()
    }

    @objc private func controlChanged() {
        applySelectedCatalogControl()
    }

    @objc private func apply() {
        onApply(controlConfig())
    }

    private func reloadSources(selectedSourceID: String) {
        sourcePopUp.removeAllItems()
        sourcePopUp.addItems(withTitles: sources.map(\.title) + ["Manual Endpoint"])
        for (item, source) in zip(sourcePopUp.itemArray, sources) {
            item.representedObject = source.id
        }
        sourcePopUp.lastItem?.representedObject = Self.manualSourceID

        let targetSourceID = selectedSourceID.isEmpty ? Self.manualSourceID : selectedSourceID
        if let item = sourcePopUp.itemArray.first(where: { ($0.representedObject as? String) == targetSourceID }) {
            sourcePopUp.select(item)
        } else if sources.isEmpty {
            sourcePopUp.select(sourcePopUp.lastItem)
        } else {
            sourcePopUp.selectItem(at: 0)
        }
    }

    private func reloadControls(selectedControlID: String, fallbackKind: MixerControlKind) {
        controlPopUp.removeAllItems()

        if let source = selectedCatalogSource {
            controlPopUp.addItems(withTitles: source.controls.map(\.title))
            for (item, control) in zip(controlPopUp.itemArray, source.controls) {
                item.representedObject = control.controlID
            }
        } else {
            controlPopUp.addItems(withTitles: ["Manual Fader", "Manual Toggle"])
            controlPopUp.itemArray.first?.representedObject = Self.manualSliderControlID
            controlPopUp.itemArray.dropFirst().first?.representedObject = Self.manualToggleControlID
        }

        let fallbackID = fallbackKind == .toggle ? Self.manualToggleControlID : Self.manualSliderControlID
        let targetControlID = selectedControlID.isEmpty ? fallbackID : selectedControlID
        if let item = controlPopUp.itemArray.first(where: { ($0.representedObject as? String) == targetControlID }) {
            controlPopUp.select(item)
        } else {
            controlPopUp.selectItem(at: 0)
        }
    }

    private func applySelectedCatalogControl() {
        guard let control = selectedCatalogControl else {
            if titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                titleField.stringValue = selectedControlID == Self.manualToggleControlID ? "Manual Toggle" : "Manual Fader"
            }
            return
        }

        titleField.stringValue = control.title
        endpointField.stringValue = control.endpoint
        minValueField.stringValue = Self.formatValue(control.minValue)
        maxValueField.stringValue = Self.formatValue(control.maxValue)
    }

    private func controlConfig() -> MixerControlConfig {
        if let source = selectedCatalogSource, let control = selectedCatalogControl {
            let range = configuredRange(fallbackMin: control.minValue, fallbackMax: control.maxValue)
            var configured = control.copyForMenu(sourceID: source.id, id: controlID)
            configured.title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? control.title
            configured.endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? control.endpoint
            configured.minValue = range.min
            configured.maxValue = range.max
            return configured
        }

        let isToggle = selectedControlID == Self.manualToggleControlID
        let range = configuredRange(fallbackMin: 0, fallbackMax: 1)
        return MixerControlConfig(
            id: controlID,
            title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? (isToggle ? "Manual Toggle" : "Manual Fader"),
            kind: isToggle ? .toggle : .slider,
            displayStyle: isToggle ? .simpleToggle : .simpleFader,
            sourceID: Self.manualSourceID,
            controlID: isToggle ? Self.manualToggleControlID : Self.manualSliderControlID,
            endpoint: endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            minValue: range.min,
            maxValue: range.max
        )
    }

    private var selectedSourceID: String {
        sourcePopUp.selectedItem?.representedObject as? String ?? Self.manualSourceID
    }

    private var selectedControlID: String {
        controlPopUp.selectedItem?.representedObject as? String ?? Self.manualSliderControlID
    }

    private var selectedCatalogSource: MixerControlSourceConfig? {
        sources.first { $0.id == selectedSourceID }
    }

    private var selectedCatalogControl: MixerControlConfig? {
        selectedCatalogSource?.controls.first { $0.controlID == selectedControlID }
    }

    private func configuredRange(fallbackMin: Double, fallbackMax: Double) -> (min: Double, max: Double) {
        let parsedMin = Double(minValueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallbackMin
        let parsedMax = Double(maxValueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallbackMax
        guard parsedMin != parsedMax else {
            return (fallbackMin, fallbackMax)
        }
        return (min(parsedMin, parsedMax), max(parsedMin, parsedMax))
    }

    private static func formatValue(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.0001 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.4f", value)
    }
}

@MainActor
private func editorStack(title: String) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    stack.addArrangedSubview(titleLabel)
    return stack
}

@MainActor
private func paddedEditorView(containing stack: NSStackView) -> NSView {
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
        stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22)
    ])
    return container
}

@MainActor
private func label(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 12)
    field.textColor = .secondaryLabelColor
    return field
}

@MainActor
private func applyButton(action: Selector) -> NSButton {
    let button = NSButton(title: "Apply", target: nil, action: action)
    button.bezelStyle = .rounded
    button.keyEquivalent = "\r"
    return button
}

private extension MixerControlConfig {
    func copyForMenu(sourceID: String, id: UUID = UUID()) -> MixerControlConfig {
        MixerControlConfig(
            id: id,
            title: title,
            kind: kind,
            displayStyle: displayStyle,
            sourceID: sourceID,
            controlID: controlID,
            endpoint: endpoint,
            linkedEndpoints: linkedEndpoints,
            meterEndpoint: meterEndpoint,
            linkedMeterEndpoints: linkedMeterEndpoints,
            muteEndpoint: muteEndpoint,
            linkedMuteEndpoints: linkedMuteEndpoints,
            padEndpoint: padEndpoint,
            linkedPadEndpoints: linkedPadEndpoints,
            phantomEndpoint: phantomEndpoint,
            linkedPhantomEndpoints: linkedPhantomEndpoints,
            minValue: minValue,
            maxValue: maxValue
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
