import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let client: MOTUClient
    private var configuration: AppConfiguration

    private let contentStack = NSStackView()
    private let hostField = NSTextField()
    private let meterUpdateRateField = NSTextField()
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Enable auto-start", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var mixerScanWindowController: MixerScanWindowController?
    private var menuSectionRows: [MenuSectionRowControls] = []
    private weak var menuLayoutStack: NSStackView?
    private weak var menuSummaryLabel: NSTextField?
    private weak var menuEmptyLabel: NSTextField?

    init(client: MOTUClient) {
        self.client = client
        self.configuration = PreferencesStore.shared.load()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MOTU 828ES Control Settings"
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        configuration = PreferencesStore.shared.load()
        rebuildEditableSections()
        super.showWindow(sender)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])

        rebuildEditableSections()
    }

    private func rebuildEditableSections() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        menuSectionRows.removeAll()
        menuLayoutStack = nil
        menuSummaryLabel = nil
        menuEmptyLabel = nil

        contentStack.addArrangedSubview(makeGeneralSection())
        contentStack.addArrangedSubview(makeMenuLayoutSection())
        contentStack.addArrangedSubview(makeActionRow())
    }

    private func makeGeneralSection() -> NSView {
        let stack = sectionStack(title: "Mixer")

        let hostRow = rowStack()
        hostRow.addArrangedSubview(label("Mixer IP or host", width: 130))
        hostField.stringValue = configuration.mixerHost
        hostField.placeholderString = "192.168.1.100"
        hostField.translatesAutoresizingMaskIntoConstraints = false
        hostRow.addArrangedSubview(hostField)
        hostField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let scanButton = NSButton(title: "Scan Mixer I/O", target: self, action: #selector(scanMixerIO))
        scanButton.bezelStyle = .rounded
        hostRow.addArrangedSubview(scanButton)

        let scanSourcesButton = NSButton(title: "Scan Control Sources", target: self, action: #selector(scanControlSources))
        scanSourcesButton.bezelStyle = .rounded
        hostRow.addArrangedSubview(scanSourcesButton)

        let meterRow = rowStack()
        meterRow.addArrangedSubview(label("Meter updates/sec", width: 130))
        meterUpdateRateField.stringValue = Self.formatMeterUpdateRate(configuration.pollingInterval)
        meterUpdateRateField.placeholderString = "20"
        meterUpdateRateField.translatesAutoresizingMaskIntoConstraints = false
        meterUpdateRateField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        meterRow.addArrangedSubview(meterUpdateRateField)
        let meterHint = NSTextField(labelWithString: "Default 20. Minimum 20. Meters update only while the menu is open.")
        meterHint.font = .systemFont(ofSize: 12)
        meterHint.textColor = .secondaryLabelColor
        meterRow.addArrangedSubview(meterHint)

        launchAtLoginButton.state = configuration.launchAtLogin ? .on : .off
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged(_:))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.stringValue = "Endpoint fields accept relative paths, absolute URLs, or URL templates containing {value}."

        stack.addArrangedSubview(hostRow)
        stack.addArrangedSubview(meterRow)
        stack.addArrangedSubview(launchAtLoginButton)
        stack.addArrangedSubview(statusLabel)
        return stack
    }

    private func makeMenuLayoutSection() -> NSView {
        let stack = sectionStack(title: "Menu Layout")
        menuLayoutStack = stack
        let sourceControlCount = configuration.controlSources.reduce(0) { $0 + $1.controls.count }
        let configuredControlCount = configuration.controlSections.reduce(0) { $0 + $1.controls.count }
        let summary = NSTextField(labelWithString: configuration.controlSources.isEmpty
            ? "No control sources scanned. Scan sources, then add the sections and controls you want in the menu."
            : "\(configuration.controlSources.count) sources and \(sourceControlCount) controls available. \(configuredControlCount) controls are currently placed in the menu.")
        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: 12)
        menuSummaryLabel = summary
        stack.addArrangedSubview(summary)

        let addSectionButton = NSButton(title: "Add Section", target: self, action: #selector(addMenuSection))
        addSectionButton.bezelStyle = .rounded
        let buttonRow = rowStack()
        buttonRow.addArrangedSubview(addSectionButton)
        stack.addArrangedSubview(buttonRow)

        if configuration.controlSections.isEmpty {
            let emptyLabel = makeMenuLayoutEmptyLabel()
            menuEmptyLabel = emptyLabel
            stack.addArrangedSubview(emptyLabel)
        }

        for section in configuration.controlSections {
            let row = MenuSectionRowControls(section: section, sources: configuration.controlSources)
            addMenuSectionRow(row)
        }
        updateMenuLayoutSummary()

        return stack
    }

    private func makeActionRow() -> NSView {
        let row = rowStack()
        row.alignment = .centerY
        row.spacing = 10

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let resetButton = NSButton(title: "Reset Defaults", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded

        row.addArrangedSubview(saveButton)
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
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func label(_ text: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func field(_ value: String, width: CGFloat, placeholder: String = "") -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    @objc private func saveSettings() {
        syncGeneralFields()
        configuration.channels = []
        configuration.specials = []
        configuration.controlSections = currentMenuSections()

        do {
            try LoginItemManager.setEnabled(configuration.launchAtLogin)
        } catch {
            showAlert(title: "Auto-start could not be changed", message: error.localizedDescription)
            configuration.launchAtLogin = LoginItemManager.isEnabled
            launchAtLoginButton.state = configuration.launchAtLogin ? .on : .off
        }

        PreferencesStore.shared.save(configuration)
        statusLabel.stringValue = "Saved."
    }

    @objc private func resetDefaults() {
        configuration = .defaults
        PreferencesStore.shared.save(configuration)
        rebuildEditableSections()
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        statusLabel.stringValue = sender.state == .on
            ? "Auto-start will be enabled when you save."
            : "Auto-start will be disabled when you save."
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
            PreferencesStore.shared.save(self.configuration)
            self.rebuildEditableSections()

            let count = sources.reduce(0) { $0 + $1.controls.count }
            self.statusLabel.stringValue = sources.isEmpty
                ? "No control sources found. Manual endpoint rows are still available."
                : "Scanned \(sources.count) sources with \(count) available controls. Add the ones you want."
        }
    }

    @objc private func addMenuSection() {
        let row = MenuSectionRowControls(
            section: MixerControlSectionConfig(title: "New Section", controls: []),
            sources: configuration.controlSources
        )
        addMenuSectionRow(row)
    }

    @objc private func deleteMenuSection(_ sender: NSButton) {
        guard let index = menuSectionRows.firstIndex(where: { $0.deleteButton === sender }) else {
            return
        }
        let row = menuSectionRows.remove(at: index)
        menuLayoutStack?.removeArrangedSubview(row.view)
        row.view.removeFromSuperview()
        ensureMenuEmptyState()
        updateMenuLayoutSummary()
    }

    @objc private func addMenuElement(_ sender: NSButton) {
        guard let row = menuSectionRows.first(where: { $0.addButton === sender }) else {
            return
        }
        let elementRow = MenuElementRowControls(control: defaultMenuControl(), sources: configuration.controlSources)
        wireMenuElementRow(elementRow)
        row.elementRows.append(elementRow)
        row.view.addArrangedSubview(elementRow.view)
        updateMenuLayoutSummary()
    }

    @objc private func deleteMenuElement(_ sender: NSButton) {
        for sectionRow in menuSectionRows {
            guard let index = sectionRow.elementRows.firstIndex(where: { $0.deleteButton === sender }) else {
                continue
            }
            let element = sectionRow.elementRows.remove(at: index)
            sectionRow.view.removeArrangedSubview(element.view)
            element.view.removeFromSuperview()
            updateMenuLayoutSummary()
            return
        }
    }

    @objc private func menuElementSourceChanged(_ sender: NSPopUpButton) {
        guard let element = menuElementRow(containing: sender) else {
            return
        }
        element.reloadControls(sources: configuration.controlSources)
        element.applySelectedControl(sources: configuration.controlSources)
    }

    @objc private func menuElementControlChanged(_ sender: NSPopUpButton) {
        guard let element = menuElementRow(containing: sender) else {
            return
        }
        element.applySelectedControl(sources: configuration.controlSources)
    }

    private func wireMenuElementRow(_ row: MenuElementRowControls) {
        row.sourcePopUp.target = self
        row.sourcePopUp.action = #selector(menuElementSourceChanged(_:))
        row.controlPopUp.target = self
        row.controlPopUp.action = #selector(menuElementControlChanged(_:))
        row.deleteButton.target = self
        row.deleteButton.action = #selector(deleteMenuElement(_:))
    }

    private func addMenuSectionRow(_ row: MenuSectionRowControls) {
        row.addButton.target = self
        row.addButton.action = #selector(addMenuElement(_:))
        row.deleteButton.target = self
        row.deleteButton.action = #selector(deleteMenuSection(_:))
        for elementRow in row.elementRows {
            wireMenuElementRow(elementRow)
        }
        menuSectionRows.append(row)
        removeMenuEmptyLabel()
        menuLayoutStack?.addArrangedSubview(row.view)
        updateMenuLayoutSummary()
    }

    private func updateMenuLayoutSummary() {
        let sourceControlCount = configuration.controlSources.reduce(0) { $0 + $1.controls.count }
        let configuredControlCount = menuSectionRows.reduce(0) { $0 + $1.elementRows.count }
        if configuration.controlSources.isEmpty {
            menuSummaryLabel?.stringValue = configuredControlCount == 0
                ? "No control sources scanned. Scan sources, then add the sections and controls you want in the menu."
                : "No control sources scanned. \(configuredControlCount) manual controls are currently placed in \(menuSectionRows.count) sections."
        } else {
            menuSummaryLabel?.stringValue = "\(configuration.controlSources.count) sources and \(sourceControlCount) controls available. \(configuredControlCount) controls are currently placed in \(menuSectionRows.count) sections."
        }
    }

    private func ensureMenuEmptyState() {
        if menuSectionRows.isEmpty {
            guard menuEmptyLabel == nil else { return }
            let emptyLabel = makeMenuLayoutEmptyLabel()
            menuEmptyLabel = emptyLabel
            menuLayoutStack?.addArrangedSubview(emptyLabel)
        } else {
            removeMenuEmptyLabel()
        }
    }

    private func removeMenuEmptyLabel() {
        guard let menuEmptyLabel else {
            return
        }
        menuLayoutStack?.removeArrangedSubview(menuEmptyLabel)
        menuEmptyLabel.removeFromSuperview()
        self.menuEmptyLabel = nil
    }

    private func makeMenuLayoutEmptyLabel() -> NSTextField {
        let emptyLabel = NSTextField(labelWithString: "No menu sections yet.")
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 11)
        return emptyLabel
    }

    private func menuElementRow(containing popUp: NSPopUpButton) -> MenuElementRowControls? {
        for sectionRow in menuSectionRows {
            if let elementRow = sectionRow.elementRows.first(where: { $0.sourcePopUp === popUp || $0.controlPopUp === popUp }) {
                return elementRow
            }
        }
        return nil
    }

    private func currentMenuSections() -> [MixerControlSectionConfig] {
        menuSectionRows.map { $0.sectionConfig(sources: configuration.controlSources) }
    }

    private func syncGeneralFields() {
        configuration.mixerHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.launchAtLogin = launchAtLoginButton.state == .on
        configuration.pollingInterval = Self.pollingInterval(fromMeterUpdateRate: meterUpdateRateField.stringValue)
        meterUpdateRateField.stringValue = Self.formatMeterUpdateRate(configuration.pollingInterval)
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
            return MixerControlConfig(
                title: control.title,
                kind: control.kind,
                displayStyle: control.displayStyle,
                sourceID: source.id,
                controlID: control.controlID,
                endpoint: control.endpoint,
                linkedEndpoints: control.linkedEndpoints,
                meterEndpoint: control.meterEndpoint,
                linkedMeterEndpoints: control.linkedMeterEndpoints,
                muteEndpoint: control.muteEndpoint,
                linkedMuteEndpoints: control.linkedMuteEndpoints,
                padEndpoint: control.padEndpoint,
                linkedPadEndpoints: control.linkedPadEndpoints,
                phantomEndpoint: control.phantomEndpoint,
                linkedPhantomEndpoints: control.linkedPhantomEndpoints,
                minValue: control.minValue,
                maxValue: control.maxValue
            )
        }

        return MixerControlConfig(
            title: "Manual Control",
            kind: .slider,
            displayStyle: .simpleFader,
            sourceID: MenuElementRowControls.manualSourceID,
            controlID: MenuElementRowControls.manualSliderControlID,
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

    @MainActor
    private final class MenuSectionRowControls {
        let id: UUID
        let view: NSStackView
        let enabledButton: NSButton
        let titleField: NSTextField
        let addButton: NSButton
        let deleteButton: NSButton
        var elementRows: [MenuElementRowControls] = []

        init(section: MixerControlSectionConfig, sources: [MixerControlSourceConfig]) {
            id = section.id
            view = NSStackView()
            view.orientation = .vertical
            view.alignment = .leading
            view.spacing = 6
            view.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

            let header = Self.horizontalStack()
            enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            enabledButton.state = section.isEnabled ? .on : .off
            enabledButton.translatesAutoresizingMaskIntoConstraints = false
            enabledButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

            titleField = SettingsWindowController.makeTextField(section.title, width: 260)
            addButton = NSButton(title: "Add Element", target: nil, action: nil)
            addButton.bezelStyle = .rounded
            deleteButton = NSButton(title: "Delete Section", target: nil, action: nil)
            deleteButton.bezelStyle = .rounded

            header.addArrangedSubview(enabledButton)
            header.addArrangedSubview(titleField)
            header.addArrangedSubview(addButton)
            header.addArrangedSubview(deleteButton)
            view.addArrangedSubview(header)

            let labels = Self.horizontalStack()
            labels.addArrangedSubview(Self.label("Source", width: 200))
            labels.addArrangedSubview(Self.label("Control", width: 150))
            labels.addArrangedSubview(Self.label("Menu Label", width: 150))
            labels.addArrangedSubview(Self.label("Endpoint", width: 300))
            labels.addArrangedSubview(Self.label("Min", width: 70))
            labels.addArrangedSubview(Self.label("Max", width: 70))
            labels.addArrangedSubview(Self.label("", width: 70))
            view.addArrangedSubview(labels)

            for control in section.controls {
                let row = MenuElementRowControls(control: control, sources: sources)
                elementRows.append(row)
                view.addArrangedSubview(row.view)
            }
        }

        func sectionConfig(sources: [MixerControlSourceConfig]) -> MixerControlSectionConfig {
            MixerControlSectionConfig(
                id: id,
                title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Menu Section",
                isEnabled: enabledButton.state == .on,
                controls: elementRows.map { $0.controlConfig(sources: sources) }
            )
        }

        private static func horizontalStack() -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            return stack
        }

        private static func label(_ text: String, width: CGFloat) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .tertiaryLabelColor
            field.alignment = .left
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            return field
        }
    }

    @MainActor
    private final class MenuElementRowControls {
        static let manualSourceID = "__manual__"
        static let manualSliderControlID = "__manual_slider__"
        static let manualToggleControlID = "__manual_toggle__"

        let id: UUID
        let view: NSStackView
        let sourcePopUp: NSPopUpButton
        let controlPopUp: NSPopUpButton
        let titleField: NSTextField
        let endpointField: NSTextField
        let minValueField: NSTextField
        let maxValueField: NSTextField
        let deleteButton: NSButton

        init(control: MixerControlConfig, sources: [MixerControlSourceConfig]) {
            id = control.id
            view = NSStackView()
            view.orientation = .horizontal
            view.alignment = .centerY
            view.spacing = 8

            sourcePopUp = NSPopUpButton()
            sourcePopUp.translatesAutoresizingMaskIntoConstraints = false
            sourcePopUp.widthAnchor.constraint(equalToConstant: 200).isActive = true

            controlPopUp = NSPopUpButton()
            controlPopUp.translatesAutoresizingMaskIntoConstraints = false
            controlPopUp.widthAnchor.constraint(equalToConstant: 150).isActive = true

            titleField = SettingsWindowController.makeTextField(control.title, width: 150)
            endpointField = SettingsWindowController.makeTextField(control.endpoint, width: 300, placeholder: "/datastore/...")
            minValueField = SettingsWindowController.makeTextField(Self.formatValue(control.minValue), width: 70, placeholder: "0")
            maxValueField = SettingsWindowController.makeTextField(Self.formatValue(control.maxValue), width: 70, placeholder: "1")

            deleteButton = NSButton(title: "Delete", target: nil, action: nil)
            deleteButton.bezelStyle = .rounded
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            deleteButton.widthAnchor.constraint(equalToConstant: 70).isActive = true

            for controlView in [sourcePopUp, controlPopUp, titleField, endpointField, minValueField, maxValueField, deleteButton] {
                view.addArrangedSubview(controlView)
            }

            reloadSources(sources: sources, selectedSourceID: control.sourceID)
            reloadControls(sources: sources, selectedControlID: control.controlID, fallbackKind: control.kind)
        }

        func reloadControls(sources: [MixerControlSourceConfig]) {
            reloadControls(sources: sources, selectedControlID: selectedControlID, fallbackKind: .slider)
        }

        func applySelectedControl(sources: [MixerControlSourceConfig]) {
            guard let control = selectedCatalogControl(sources: sources) else {
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

        func controlConfig(sources: [MixerControlSourceConfig]) -> MixerControlConfig {
            if let source = selectedCatalogSource(sources: sources),
               let control = selectedCatalogControl(sources: sources) {
                let range = configuredRange(fallbackMin: control.minValue, fallbackMax: control.maxValue)
                return MixerControlConfig(
                    id: id,
                    title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? control.title,
                    kind: control.kind,
                    displayStyle: control.displayStyle,
                    sourceID: source.id,
                    controlID: control.controlID,
                    endpoint: endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? control.endpoint,
                    linkedEndpoints: control.linkedEndpoints,
                    meterEndpoint: control.meterEndpoint,
                    linkedMeterEndpoints: control.linkedMeterEndpoints,
                    muteEndpoint: control.muteEndpoint,
                    linkedMuteEndpoints: control.linkedMuteEndpoints,
                    padEndpoint: control.padEndpoint,
                    linkedPadEndpoints: control.linkedPadEndpoints,
                    phantomEndpoint: control.phantomEndpoint,
                    linkedPhantomEndpoints: control.linkedPhantomEndpoints,
                    minValue: range.min,
                    maxValue: range.max
                )
            }

            let isToggle = selectedControlID == Self.manualToggleControlID
            let range = configuredRange(fallbackMin: 0, fallbackMax: 1)
            return MixerControlConfig(
                id: id,
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

        private func reloadSources(sources: [MixerControlSourceConfig], selectedSourceID: String) {
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

        private func reloadControls(
            sources: [MixerControlSourceConfig],
            selectedControlID: String,
            fallbackKind: MixerControlKind
        ) {
            controlPopUp.removeAllItems()

            if let source = selectedCatalogSource(sources: sources) {
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

        private func selectedCatalogSource(sources: [MixerControlSourceConfig]) -> MixerControlSourceConfig? {
            sources.first { $0.id == selectedSourceID }
        }

        private func selectedCatalogControl(sources: [MixerControlSourceConfig]) -> MixerControlConfig? {
            selectedCatalogSource(sources: sources)?.controls.first { $0.controlID == selectedControlID }
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
    private final class ChannelRowControls {
        let id: UUID
        let view: NSStackView
        let enabledButton: NSButton
        let rolePopUp: NSPopUpButton
        let nameField: NSTextField
        let volumeEndpointField: NSTextField
        let levelEndpointField: NSTextField
        let muteEndpointField: NSTextField
        let nameEndpointField: NSTextField
        let scalePopUp: NSPopUpButton

        init(channel: ChannelConfig) {
            id = channel.id
            view = NSStackView()
            view.orientation = .horizontal
            view.alignment = .centerY
            view.spacing = 8

            enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            enabledButton.state = channel.isEnabled ? .on : .off
            enabledButton.translatesAutoresizingMaskIntoConstraints = false
            enabledButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

            rolePopUp = NSPopUpButton()
            rolePopUp.addItems(withTitles: ChannelRole.allCases.map(\.rawValue))
            rolePopUp.selectItem(withTitle: channel.role.rawValue)
            rolePopUp.translatesAutoresizingMaskIntoConstraints = false
            rolePopUp.widthAnchor.constraint(equalToConstant: 105).isActive = true

            nameField = SettingsWindowController.makeTextField(channel.displayName, width: 130)
            volumeEndpointField = SettingsWindowController.makeTextField(channel.volumeEndpoint, width: 170, placeholder: "/datastore/...")
            levelEndpointField = SettingsWindowController.makeTextField(channel.levelEndpoint, width: 170, placeholder: "/datastore/...")
            muteEndpointField = SettingsWindowController.makeTextField(channel.muteEndpoint, width: 150, placeholder: "/path?value={value}")
            nameEndpointField = SettingsWindowController.makeTextField(channel.nameEndpoint, width: 150, placeholder: "/datastore/.../name")

            scalePopUp = NSPopUpButton()
            scalePopUp.addItems(withTitles: SliderScale.allCases.map(\.rawValue))
            scalePopUp.selectItem(withTitle: channel.sliderScale.rawValue)
            scalePopUp.translatesAutoresizingMaskIntoConstraints = false
            scalePopUp.widthAnchor.constraint(equalToConstant: 95).isActive = true

            for control in [
                enabledButton,
                rolePopUp,
                nameField,
                volumeEndpointField,
                levelEndpointField,
                muteEndpointField,
                nameEndpointField,
                scalePopUp
            ] {
                view.addArrangedSubview(control)
            }
        }

        func channelConfig() -> ChannelConfig {
            ChannelConfig(
                id: id,
                role: ChannelRole(rawValue: rolePopUp.titleOfSelectedItem ?? "") ?? .input,
                displayName: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                isEnabled: enabledButton.state == .on,
                volumeEndpoint: volumeEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                levelEndpoint: levelEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                muteEndpoint: muteEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                supportsMute: (ChannelRole(rawValue: rolePopUp.titleOfSelectedItem ?? "") ?? .input) != .headphones,
                nameEndpoint: nameEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                sliderScale: SliderScale(rawValue: scalePopUp.titleOfSelectedItem ?? "") ?? .logarithmic
            )
        }
    }

    @MainActor
    private final class SpecialRowControls {
        let id: UUID
        let view: NSStackView
        let enabledButton: NSButton
        let nameField: NSTextField
        let setEndpointField: NSTextField
        let stateEndpointField: NSTextField
        let onValueField: NSTextField
        let offValueField: NSTextField
        let autoMediaButton: NSButton
        let mediaAppsField: NSTextField
        let mediaActionPopUp: NSPopUpButton
        let deleteButton: NSButton

        init(special: SpecialConfig) {
            id = special.id
            view = NSStackView()
            view.orientation = .horizontal
            view.alignment = .centerY
            view.spacing = 8

            enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            enabledButton.state = special.isEnabled ? .on : .off
            enabledButton.translatesAutoresizingMaskIntoConstraints = false
            enabledButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

            nameField = SettingsWindowController.makeTextField(special.name, width: 130)
            setEndpointField = SettingsWindowController.makeTextField(special.setEndpoint, width: 190, placeholder: "/path?value={value}")
            stateEndpointField = SettingsWindowController.makeTextField(special.stateEndpoint, width: 170, placeholder: "/datastore/...")
            onValueField = SettingsWindowController.makeTextField(special.onValue, width: 70)
            offValueField = SettingsWindowController.makeTextField(special.offValue, width: 70)

            autoMediaButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            autoMediaButton.state = special.autoToggleWithMedia ? .on : .off
            autoMediaButton.translatesAutoresizingMaskIntoConstraints = false
            autoMediaButton.widthAnchor.constraint(equalToConstant: 46).isActive = true

            mediaAppsField = SettingsWindowController.makeTextField(
                special.mediaAppIdentifiers.joined(separator: ", "),
                width: 210,
                placeholder: "Music, com.apple.TV"
            )

            mediaActionPopUp = NSPopUpButton()
            mediaActionPopUp.addItems(withTitles: ["On", "Off"])
            mediaActionPopUp.selectItem(withTitle: special.mediaTurnsSpecialOn ? "On" : "Off")
            mediaActionPopUp.translatesAutoresizingMaskIntoConstraints = false
            mediaActionPopUp.widthAnchor.constraint(equalToConstant: 92).isActive = true

            deleteButton = NSButton(title: "Delete", target: nil, action: nil)
            deleteButton.bezelStyle = .rounded
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            deleteButton.widthAnchor.constraint(equalToConstant: 70).isActive = true

            for control in [
                enabledButton,
                nameField,
                setEndpointField,
                stateEndpointField,
                onValueField,
                offValueField,
                autoMediaButton,
                mediaAppsField,
                mediaActionPopUp,
                deleteButton
            ] {
                view.addArrangedSubview(control)
            }
        }

        func specialConfig() -> SpecialConfig {
            SpecialConfig(
                id: id,
                name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                isEnabled: enabledButton.state == .on,
                setEndpoint: setEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                stateEndpoint: stateEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                onValue: onValueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                offValue: offValueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                autoToggleWithMedia: autoMediaButton.state == .on,
                mediaAppIdentifiers: mediaAppsField.stringValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                mediaTurnsSpecialOn: mediaActionPopUp.titleOfSelectedItem != "Off"
            )
        }
    }

    private static func makeTextField(_ value: String, width: CGFloat, placeholder: String = "") -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
