import AppKit

private struct EndpointWriteKey: Hashable {
    var host: String
    var endpoint: String
}

private enum MuteButtonStyle {
    static func configure(_ button: NSButton, width: CGFloat) {
        button.setButtonType(.toggle)
        button.isBordered = false
        button.wantsLayer = true
        button.alignment = .center
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        update(button)
    }

    static func update(_ button: NSButton) {
        let attributedTitle = button.attributedTitle.string
        let title = attributedTitle.isEmpty ? button.title : attributedTitle
        let isMuted = button.state == .on
        let red = NSColor.systemRed
        let foregroundColor = isMuted ? NSColor.white : NSColor.systemRed
        let attributes: [NSAttributedString.Key: Any] = [
            .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: foregroundColor
        ]

        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = isMuted ? red.cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = red.cgColor
        button.layer?.borderWidth = isMuted ? 0 : 1
        button.contentTintColor = foregroundColor
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        button.attributedAlternateTitle = NSAttributedString(string: title, attributes: attributes)
        button.needsDisplay = true
    }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let client = MOTUClient()
    private var configuration = PreferencesStore.shared.load()
    private var controlViews: [UUID: MixerControlRowView] = [:]
    private var menuIsOpen = false
    private var timer: Timer?
    private var settingsWindowController: SettingsWindowController?
    private let writeCoalesceInterval: TimeInterval = 0.05
    private let localEditGraceInterval: TimeInterval = 1.0
    private var pendingWrites: [EndpointWriteKey: String] = [:]
    private var activeWrites: Set<EndpointWriteKey> = []
    private var scheduledWrites: Set<EndpointWriteKey> = []
    private var locallyEditedControls: [UUID: Date] = [:]
    private var meterRefreshInFlight = false
    private var meterRefreshPending = false

    override init() {
        super.init()

        if let button = statusItem.button {
            button.title = ""
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "MOTU control")
            button.imagePosition = .imageOnly
        }

        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configurationDidChange(_:)),
            name: .appConfigurationDidChange,
            object: nil
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshState()
        startPolling()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        stopPolling()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        controlViews.removeAll()
        let enabledControlSections = configuration.controlSections.filter(\.isEnabled)

        if !enabledControlSections.isEmpty {
            addControlSections(enabledControlSections)
            menu.addItem(.separator())
        }

        let openWebUIItem = NSMenuItem(title: "Open Web UI", action: #selector(openWebUI), keyEquivalent: "")
        openWebUIItem.target = self
        menu.addItem(openWebUIItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addControlSections(_ sections: [MixerControlSectionConfig]) {
        for section in sections {
            menu.addItem(item(with: MenuSectionHeaderView(title: section.title)))
            for control in section.controls {
                let view = MixerControlRowView(control: control)
                view.onSliderChange = { [weak self] value in
                    self?.setControl(control, value: value)
                }
                view.onToggleChange = { [weak self] enabled in
                    self?.setControl(control, enabled: enabled)
                }
                view.onEndpointToggleChange = { [weak self] endpoints, enabled in
                    self?.setEndpoints(endpoints, enabled: enabled)
                }
                controlViews[control.id] = view
                menu.addItem(item(with: view))
            }
        }
    }

    private func item(with view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func startPolling() {
        stopPolling()
        guard menuIsOpen else {
            return
        }

        let timer = Timer(timeInterval: effectiveMeterPollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMeters()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        meterRefreshInFlight = false
        meterRefreshPending = false
    }

    private var effectiveMeterPollingInterval: TimeInterval {
        min(max(configuration.pollingInterval, 1.0 / 30.0), AppConfiguration.defaults.pollingInterval)
    }

    private func refreshState() {
        guard menuIsOpen else {
            return
        }

        let host = configuration.mixerHost
        refreshScannedControls(host: host)
    }

    private func refreshMeters() {
        guard menuIsOpen else {
            return
        }

        guard !meterRefreshInFlight else {
            meterRefreshPending = true
            return
        }

        let host = configuration.mixerHost
        var endpoints: [String] = []
        var controls: [(view: MixerControlRowView, endpoints: [String])] = []

        for section in configuration.controlSections where section.isEnabled {
            for control in section.controls where !control.meterEndpoint.isEmpty {
                guard let view = controlViews[control.id] else {
                    continue
                }

                let controlEndpoints = ([control.meterEndpoint] + control.linkedMeterEndpoints)
                    .filter { !$0.isEmpty }
                endpoints.append(contentsOf: controlEndpoints)
                controls.append((view: view, endpoints: controlEndpoints))
            }
        }

        guard !endpoints.isEmpty else {
            return
        }

        meterRefreshInFlight = true
        client.readMeterNumbers(host: host, endpoints: Array(Set(endpoints))) { [weak self] values in
            DispatchQueue.main.async {
                guard let self else { return }
                self.meterRefreshInFlight = false

                for control in controls {
                    let level = control.endpoints.compactMap { values[$0] }.max()
                    if let level {
                        control.view.setLevel(level)
                    }
                }

                if self.meterRefreshPending {
                    self.meterRefreshPending = false
                    self.refreshMeters()
                }
            }
        }
    }

    private func refreshScannedControls(host: String) {
        for section in configuration.controlSections where section.isEnabled {
            for control in section.controls {
                guard let view = controlViews[control.id] else {
                    continue
                }

                switch control.kind {
                case .slider:
                    client.readNumber(host: host, endpoint: control.endpoint) { [weak self] value in
                        DispatchQueue.main.async {
                            guard let self, let value, !self.isRecentlyEdited(control.id) else { return }
                            view.setRawValue(value)
                        }
                    }
                case .toggle:
                    client.readBool(host: host, endpoint: control.endpoint, onValue: "1") { value in
                        DispatchQueue.main.async {
                            guard let value else { return }
                            view.setOn(value)
                        }
                    }
                }

                if !control.muteEndpoint.isEmpty {
                    client.readBool(host: host, endpoint: control.muteEndpoint, onValue: "1") { value in
                        DispatchQueue.main.async {
                            guard let value else { return }
                            view.setMuted(value)
                        }
                    }
                }

                if !control.padEndpoint.isEmpty {
                    client.readBool(host: host, endpoint: control.padEndpoint, onValue: "1") { value in
                        DispatchQueue.main.async {
                            guard let value else { return }
                            view.setPadEnabled(value)
                        }
                    }
                }

                if !control.phantomEndpoint.isEmpty {
                    client.readBool(host: host, endpoint: control.phantomEndpoint, onValue: "1") { value in
                        DispatchQueue.main.async {
                            guard let value else { return }
                            view.setPhantomEnabled(value)
                        }
                    }
                }
            }
        }

        refreshMeters()
    }

    private func setControl(_ control: MixerControlConfig, value: Double) {
        guard !control.endpoint.isEmpty else {
            return
        }
        locallyEditedControls[control.id] = Date()
        sendValue(to: [control.endpoint] + control.linkedEndpoints, value: String(format: "%.4f", value))
    }

    private func setControl(_ control: MixerControlConfig, enabled: Bool) {
        guard !control.endpoint.isEmpty else {
            return
        }
        sendValue(to: [control.endpoint] + control.linkedEndpoints, value: enabled ? "1" : "0")
    }

    private func setEndpoints(_ endpoints: [String], enabled: Bool) {
        sendValue(to: endpoints, value: enabled ? "1" : "0")
    }

    private func sendValue(to endpoints: [String], value: String) {
        for endpoint in endpoints where !endpoint.isEmpty {
            enqueueWrite(endpoint: endpoint, value: value)
        }
    }

    private func enqueueWrite(endpoint: String, value: String) {
        let key = EndpointWriteKey(host: configuration.mixerHost, endpoint: endpoint)
        pendingWrites[key] = value

        guard !activeWrites.contains(key), !scheduledWrites.contains(key) else {
            return
        }
        scheduleWrite(for: key)
    }

    private func scheduleWrite(for key: EndpointWriteKey) {
        scheduledWrites.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + writeCoalesceInterval) { [weak self] in
            Task { @MainActor in
                self?.flushWrite(for: key)
            }
        }
    }

    private func flushWrite(for key: EndpointWriteKey) {
        scheduledWrites.remove(key)
        guard let value = pendingWrites.removeValue(forKey: key) else {
            return
        }

        activeWrites.insert(key)
        client.sendValue(host: key.host, endpoint: key.endpoint, value: value) { [weak self] _ in
            DispatchQueue.main.async {
                self?.writeDidComplete(for: key)
            }
        }
    }

    private func writeDidComplete(for key: EndpointWriteKey) {
        activeWrites.remove(key)
        if pendingWrites[key] != nil {
            scheduleWrite(for: key)
        }
    }

    private func isRecentlyEdited(_ controlID: UUID) -> Bool {
        guard let date = locallyEditedControls[controlID] else {
            return false
        }

        if Date().timeIntervalSince(date) < localEditGraceInterval {
            return true
        }

        locallyEditedControls.removeValue(forKey: controlID)
        return false
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(client: client)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openWebUI() {
        guard let url = webUIURL(for: configuration.mixerHost) else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func webUIURL(for host: String) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmedHost), url.scheme != nil {
            return url
        }

        return URL(string: "http://\(trimmedHost)")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func configurationDidChange(_ notification: Notification) {
        configuration = PreferencesStore.shared.load()
        pendingWrites.removeAll()
        scheduledWrites.removeAll()
        locallyEditedControls.removeAll()
        meterRefreshInFlight = false
        meterRefreshPending = false
        rebuildMenu()
        if menuIsOpen {
            startPolling()
        } else {
            stopPolling()
        }
        refreshState()
    }
}

final class MenuSectionHeaderView: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 28))

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 340),
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MixerControlRowView: NSView {
    var onSliderChange: ((Double) -> Void)?
    var onToggleChange: ((Bool) -> Void)?
    var onEndpointToggleChange: (([String], Bool) -> Void)?

    private let control: MixerControlConfig
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let toggle = NSSwitch()
    private let muteButton = NSButton(title: "M", target: nil, action: nil)
    private let padButton = NSButton(title: "Pad", target: nil, action: nil)
    private let phantomButton = NSButton(title: "+48V", target: nil, action: nil)
    private let buttonStack = NSStackView()
    private let levelView = SegmentedLevelView()
    private var isUpdating = false

    init(control: MixerControlConfig) {
        self.control = control
        let showsMeter = control.displayStyle == .meterFader || control.displayStyle == .trimFader
        let viewHeight: CGFloat = control.kind == .slider ? (showsMeter ? 74 : 46) : 42
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: viewHeight))

        titleLabel.stringValue = control.title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isHidden = control.kind != .slider

        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.isHidden = control.kind != .toggle || control.displayStyle == .muteButton

        MuteButtonStyle.configure(muteButton, width: 30)
        muteButton.target = self
        muteButton.action = #selector(muteButtonChanged(_:))
        muteButton.isHidden = !(control.displayStyle == .muteButton || (control.kind == .slider && !control.muteEndpoint.isEmpty))

        configureToggleButton(padButton)
        padButton.target = self
        padButton.action = #selector(padButtonChanged(_:))
        padButton.isHidden = control.padEndpoint.isEmpty

        configureToggleButton(phantomButton)
        phantomButton.target = self
        phantomButton.action = #selector(phantomButtonChanged(_:))
        phantomButton.isHidden = control.phantomEndpoint.isEmpty

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 4
        if control.kind == .slider {
            for button in [muteButton, padButton, phantomButton] where !button.isHidden {
                buttonStack.addArrangedSubview(button)
            }
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        if control.kind == .toggle {
            if control.displayStyle == .muteButton {
                muteButton.translatesAutoresizingMaskIntoConstraints = false
                addSubview(muteButton)
            } else {
                toggle.translatesAutoresizingMaskIntoConstraints = false
                addSubview(toggle)
            }
        } else {
            for subview in [valueLabel, slider] {
                subview.translatesAutoresizingMaskIntoConstraints = false
                addSubview(subview)
            }
            if showsMeter {
                levelView.translatesAutoresizingMaskIntoConstraints = false
                addSubview(levelView)
                buttonStack.translatesAutoresizingMaskIntoConstraints = false
                addSubview(buttonStack)
            }
        }

        valueLabel.isHidden = control.kind != .slider
        levelView.isHidden = !showsMeter

        if control.kind == .toggle {
            layoutToggleRow(height: viewHeight)
        } else if showsMeter {
            layoutMeterFaderRow(height: viewHeight)
        } else {
            layoutSimpleFaderRow(height: viewHeight)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRawValue(_ value: Double) {
        isUpdating = true
        slider.doubleValue = normalizedValue(from: value)
        valueLabel.stringValue = formatted(value)
        isUpdating = false
    }

    func setOn(_ isOn: Bool) {
        isUpdating = true
        toggle.state = isOn ? .on : .off
        muteButton.state = isOn ? .on : .off
        MuteButtonStyle.update(muteButton)
        isUpdating = false
    }

    func setLevel(_ value: Double) {
        levelView.setLevel(value)
    }

    func setMuted(_ muted: Bool) {
        isUpdating = true
        muteButton.state = muted ? .on : .off
        MuteButtonStyle.update(muteButton)
        isUpdating = false
    }

    func setPadEnabled(_ enabled: Bool) {
        isUpdating = true
        padButton.state = enabled ? .on : .off
        isUpdating = false
    }

    func setPhantomEnabled(_ enabled: Bool) {
        isUpdating = true
        phantomButton.state = enabled ? .on : .off
        isUpdating = false
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard !isUpdating else { return }
        let value = rawValue(from: sender.doubleValue)
        valueLabel.stringValue = formatted(value)
        onSliderChange?(value)
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard !isUpdating else { return }
        onToggleChange?(sender.state == .on)
    }

    @objc private func muteButtonChanged(_ sender: NSButton) {
        guard !isUpdating else { return }
        MuteButtonStyle.update(sender)
        if control.displayStyle == .muteButton && control.kind == .toggle {
            onToggleChange?(sender.state == .on)
        } else if !control.muteEndpoint.isEmpty {
            onEndpointToggleChange?([control.muteEndpoint] + control.linkedMuteEndpoints, sender.state == .on)
        }
    }

    @objc private func padButtonChanged(_ sender: NSButton) {
        guard !isUpdating else { return }
        onEndpointToggleChange?([control.padEndpoint] + control.linkedPadEndpoints, sender.state == .on)
    }

    @objc private func phantomButtonChanged(_ sender: NSButton) {
        guard !isUpdating else { return }
        onEndpointToggleChange?([control.phantomEndpoint] + control.linkedPhantomEndpoints, sender.state == .on)
    }

    private func layoutToggleRow(height: CGFloat) {
        var constraints = [
            widthAnchor.constraint(equalToConstant: 360),
            heightAnchor.constraint(equalToConstant: height),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -82)
        ]

        if control.displayStyle == .muteButton {
            constraints.append(contentsOf: [
                muteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
                muteButton.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            constraints.append(contentsOf: [
                toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func layoutSimpleFaderRow(height: CGFloat) {
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 360),
            heightAnchor.constraint(equalToConstant: height),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 112),

            slider.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -8),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 54)
        ])
    }

    private func layoutMeterFaderRow(height: CGFloat) {
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 360),
            heightAnchor.constraint(equalToConstant: height),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),

            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttonStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            valueLabel.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 54),

            levelView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            levelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            levelView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            levelView.heightAnchor.constraint(equalToConstant: 9),

            slider.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: levelView.bottomAnchor, constant: 7)
        ])
    }

    private func configureToggleButton(_ button: NSButton) {
        button.setButtonType(.toggle)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: button.title == "M" ? 30 : 48).isActive = true
    }

    private func normalizedValue(from rawValue: Double) -> Double {
        if usesGainScale {
            return normalizedGainValue(from: rawValue)
        }

        guard control.maxValue != control.minValue else {
            return 0
        }
        return min(max((rawValue - control.minValue) / (control.maxValue - control.minValue), 0), 1)
    }

    private func rawValue(from normalizedValue: Double) -> Double {
        if usesGainScale {
            return rawGainValue(from: normalizedValue)
        }

        return control.minValue + min(max(normalizedValue, 0), 1) * (control.maxValue - control.minValue)
    }

    private func formatted(_ value: Double) -> String {
        if usesGainScale {
            return formattedGain(value)
        }

        if abs(value.rounded() - value) < 0.01 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.2f", value)
    }

    private var usesGainScale: Bool {
        control.kind == .slider
            && abs(control.minValue) < 0.0001
            && abs(control.maxValue - 4) < 0.0001
    }

    private func normalizedGainValue(from rawValue: Double) -> Double {
        guard rawValue > 0 else {
            return 0
        }

        let decibels = 20 * log10(rawValue)
        return min(max((decibels - minimumGainDecibels) / (maximumGainDecibels - minimumGainDecibels), 0), 1)
    }

    private func rawGainValue(from normalizedValue: Double) -> Double {
        let clamped = min(max(normalizedValue, 0), 1)
        guard clamped > 0 else {
            return 0
        }

        let decibels = minimumGainDecibels + clamped * (maximumGainDecibels - minimumGainDecibels)
        return min(max(pow(10, decibels / 20), control.minValue), control.maxValue)
    }

    private func formattedGain(_ value: Double) -> String {
        guard value > 0 else {
            return "-inf"
        }

        let decibels = 20 * log10(value)
        if abs(decibels) < 0.05 {
            return "0dB"
        }
        if decibels > 0 {
            return String(format: "+%.1fdB", decibels)
        }
        return String(format: "%.1fdB", decibels)
    }

    private var minimumGainDecibels: Double {
        -60
    }

    private var maximumGainDecibels: Double {
        20 * log10(max(control.maxValue, 1))
    }
}

final class SegmentedLevelView: NSView {
    private let falloffPerSecond = 4.0
    private let repeatedPeakTolerance = 0.015
    private let repeatedPeakSuppressionInterval: TimeInterval = 0.35
    private var falloffTimer: Timer?
    private var falloffTarget: Double = 0
    private var lastFalloffUpdate = Date()
    private var lastRawValue: Double?
    private var lastAcceptedPeakValue: Double?
    private var lastAcceptedPeakDate = Date.distantPast
    private var displayedValue: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    deinit {
        falloffTimer?.invalidate()
    }

    override var isFlipped: Bool {
        true
    }

    func setLevel(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        let previousRawValue = lastRawValue ?? 0
        lastRawValue = clamped

        if clamped > displayedValue {
            let now = Date()
            if isRepeatedAcceptedPeak(clamped, at: now) {
                falloffTarget = min(falloffTarget, previousRawValue)
                startFalloff()
                return
            }

            displayedValue = clamped
            falloffTarget = min(previousRawValue, clamped)
            lastAcceptedPeakValue = clamped
            lastAcceptedPeakDate = now
            if displayedValue > falloffTarget + 0.001 {
                startFalloff()
            } else {
                stopFalloff()
            }
            return
        }

        falloffTarget = clamped
        startFalloff()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let segmentCount = 18
        let gap: CGFloat = 2
        let totalGapWidth = CGFloat(segmentCount - 1) * gap
        let segmentWidth = max((bounds.width - totalGapWidth) / CGFloat(segmentCount), 1)
        let activeSegments = Int((min(max(displayedValue, 0), 1) * Double(segmentCount)).rounded(.up))

        for index in 0..<segmentCount {
            let x = CGFloat(index) * (segmentWidth + gap)
            let rect = NSRect(x: x, y: 0, width: segmentWidth, height: bounds.height)
            let isActive = index < activeSegments
            color(for: index, active: isActive).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func color(for index: Int, active: Bool) -> NSColor {
        guard active else {
            return NSColor.separatorColor.withAlphaComponent(0.35)
        }

        switch index {
        case 0..<7:
            return NSColor(calibratedRed: 0.05, green: 0.34, blue: 0.18, alpha: 1)
        case 7..<13:
            return NSColor(calibratedRed: 0.36, green: 0.75, blue: 0.24, alpha: 1)
        case 13..<16:
            return NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.17, alpha: 1)
        default:
            return NSColor(calibratedRed: 0.88, green: 0.16, blue: 0.12, alpha: 1)
        }
    }

    private func startFalloff() {
        guard falloffTimer == nil else {
            return
        }

        lastFalloffUpdate = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFalloff()
            }
        }
        falloffTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func stopFalloff() {
        falloffTimer?.invalidate()
        falloffTimer = nil
    }

    private func isRepeatedAcceptedPeak(_ value: Double, at date: Date) -> Bool {
        guard let lastAcceptedPeakValue,
              abs(value - lastAcceptedPeakValue) <= repeatedPeakTolerance else {
            return false
        }
        return date.timeIntervalSince(lastAcceptedPeakDate) < repeatedPeakSuppressionInterval
    }

    private func updateFalloff() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFalloffUpdate)
        lastFalloffUpdate = now

        displayedValue = max(falloffTarget, displayedValue - falloffPerSecond * elapsed)
        if displayedValue <= falloffTarget + 0.001 {
            displayedValue = falloffTarget
            stopFalloff()
        }
    }
}

final class ChannelControlView: NSView {
    var onVolumeChange: ((Double) -> Void)?
    var onMuteChange: ((Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let levelIndicator = NSLevelIndicator()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let muteButton = NSButton(title: "Mute", target: nil, action: nil)
    private var isUpdating = false

    init(title: String, showsMute: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 74))

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        levelIndicator.minValue = 0
        levelIndicator.maxValue = 1
        levelIndicator.doubleValue = 0
        levelIndicator.levelIndicatorStyle = .continuousCapacity
        levelIndicator.isEditable = false

        slider.target = self
        slider.action = #selector(sliderChanged(_:))

        MuteButtonStyle.configure(muteButton, width: 64)
        muteButton.target = self
        muteButton.action = #selector(muteChanged(_:))
        muteButton.isHidden = !showsMute

        for subview in [titleLabel, levelIndicator, slider, muteButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 74),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor, constant: -10),

            muteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            muteButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            levelIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            levelIndicator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            levelIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            levelIndicator.heightAnchor.constraint(equalToConstant: 8),

            slider.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            slider.topAnchor.constraint(equalTo: levelIndicator.bottomAnchor, constant: 7),
            slider.trailingAnchor.constraint(equalTo: levelIndicator.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setVolume(_ value: Double) {
        isUpdating = true
        slider.doubleValue = min(max(value, 0), 1)
        isUpdating = false
    }

    func setLevel(_ value: Double) {
        levelIndicator.doubleValue = min(max(value, 0), 1)
    }

    func setMuted(_ muted: Bool) {
        isUpdating = true
        muteButton.state = muted ? .on : .off
        MuteButtonStyle.update(muteButton)
        isUpdating = false
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard !isUpdating else { return }
        onVolumeChange?(sender.doubleValue)
    }

    @objc private func muteChanged(_ sender: NSButton) {
        guard !isUpdating else { return }
        MuteButtonStyle.update(sender)
        onMuteChange?(sender.state == .on)
    }
}

final class SpecialToggleView: NSView {
    var onToggle: ((Bool) -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private var isUpdating = false

    init(name: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail

        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))

        for subview in [nameLabel, toggle] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 42),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOn(_ isOn: Bool) {
        isUpdating = true
        toggle.state = isOn ? .on : .off
        isUpdating = false
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard !isUpdating else { return }
        onToggle?(sender.state == .on)
    }
}
