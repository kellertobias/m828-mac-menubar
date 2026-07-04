import Foundation

extension Notification.Name {
    static let appConfigurationDidChange = Notification.Name("appConfigurationDidChange")
}

final class PreferencesStore {
    static let shared = PreferencesStore()

    private let key = "appConfiguration.v1"
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppConfiguration {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }

        do {
            let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
            let migratedConfiguration = configuration.migratedForManualMenuLayout()
            if migratedConfiguration != configuration {
                save(migratedConfiguration)
            }
            return migratedConfiguration
        } catch {
            NSLog("Could not decode configuration: \(error)")
            return .defaults
        }
    }

    func save(_ configuration: AppConfiguration) {
        do {
            let data = try JSONEncoder().encode(configuration)
            defaults.set(data, forKey: key)
            NotificationCenter.default.post(name: .appConfigurationDidChange, object: configuration)
        } catch {
            NSLog("Could not encode configuration: \(error)")
        }
    }
}

private extension AppConfiguration {
    func migratedForManualMenuLayout() -> AppConfiguration {
        var migrated = self

        if migrated.controlSources.isEmpty,
           !migrated.controlSections.isEmpty,
           migrated.controlSections.looksLikeGeneratedMixerCatalog {
            migrated.controlSources = migrated.controlSections.catalogSources()
            migrated.controlSections = []
        }

        migrated = migrated.normalizedStereoChannelSourceTitles()
        migrated = migrated.correctedPhysicalMonitorOutputs()
        migrated.pollingInterval = Self.normalizedMeterPollingInterval(migrated.pollingInterval)

        if migrated.controlSections.looksLikeActiveCopy(of: migrated.controlSources) {
            migrated.controlSections = []
        }

        let outputMeterOffsets = OutputMeterOffsets(sources: migrated.controlSources, sections: migrated.controlSections)
        migrated.controlSources = migrated.controlSources
            .map { $0.correctedOutputMeters(using: outputMeterOffsets) }
            .deduplicated()
        migrated.controlSections = migrated.controlSections.map { $0.correctedOutputMeters(using: outputMeterOffsets) }

        return migrated
    }

    static func normalizedMeterPollingInterval(_ interval: TimeInterval) -> TimeInterval {
        if abs(interval - 0.25) < 0.0001 {
            return AppConfiguration.defaults.pollingInterval
        }
        return min(max(interval, 1.0 / 30.0), AppConfiguration.defaults.pollingInterval)
    }

    func normalizedStereoChannelSourceTitles() -> AppConfiguration {
        var migrated = self
        var sourceIDChanges: [String: String] = [:]

        migrated.controlSources = migrated.controlSources.map { source in
            let normalizedSource = source.normalizedStereoChannelTitle()
            if normalizedSource.id != source.id {
                sourceIDChanges[source.id] = normalizedSource.id
            }
            return normalizedSource
        }

        if !sourceIDChanges.isEmpty {
            migrated.controlSections = migrated.controlSections.map {
                $0.remappedSourceIDs(sourceIDChanges)
            }
        }

        return migrated
    }

    func correctedPhysicalMonitorOutputs() -> AppConfiguration {
        var migrated = self
        var sourceIDChanges: [String: String] = [:]

        migrated.controlSources = migrated.controlSources.map { source in
            let correctedSource = source.correctedPhysicalMonitorOutput()
            if correctedSource.id != source.id {
                sourceIDChanges[source.id] = correctedSource.id
            }
            return correctedSource
        }

        migrated.controlSections = migrated.controlSections.map {
            $0.correctedPhysicalMonitorOutput().remappedSourceIDs(sourceIDChanges)
        }

        return migrated
    }
}

private struct OutputMeterOffsets {
    private let bankOffsets: [Int: Int]

    init(sources: [MixerControlSourceConfig], sections: [MixerControlSectionConfig]) {
        var bankCounts: [Int: Int] = [:]

        for source in sources {
            for control in source.controls {
                guard let endpoint = OutputTrimEndpoint(control.endpoint) else { continue }
                bankCounts[endpoint.bank] = max(bankCounts[endpoint.bank] ?? 0, endpoint.channel + endpoint.width)
            }
        }

        for section in sections {
            for control in section.controls {
                guard let endpoint = OutputTrimEndpoint(control.endpoint) else { continue }
                bankCounts[endpoint.bank] = max(bankCounts[endpoint.bank] ?? 0, endpoint.channel + endpoint.width)
            }
        }

        var offsets: [Int: Int] = [:]
        var nextOffset = 0
        for bank in bankCounts.keys.sorted() {
            offsets[bank] = nextOffset
            nextOffset += bankCounts[bank] ?? 0
        }
        bankOffsets = offsets
    }

    func meterEndpoint(for controlEndpoint: String) -> String? {
        guard let endpoint = OutputTrimEndpoint(controlEndpoint),
              let bankOffset = bankOffsets[endpoint.bank] else {
            return nil
        }
        return "meters/ext/output/\(bankOffset + endpoint.channel)"
    }
}

private struct OutputTrimEndpoint {
    let bank: Int
    let channel: Int
    let width: Int

    init?(_ endpoint: String) {
        let parts = endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)

        guard parts.count == 7,
              parts[0] == "datastore",
              parts[1] == "ext",
              parts[2] == "obank",
              parts[4] == "ch",
              let bank = Int(parts[3]),
              let channel = Int(parts[5]),
              parts[6] == "stereoTrim" || parts[6] == "trim" else {
            return nil
        }

        self.bank = bank
        self.channel = channel
        self.width = parts[6] == "stereoTrim" ? 2 : 1
    }
}

private extension MixerControlSourceConfig {
    func correctedPhysicalMonitorOutput() -> MixerControlSourceConfig {
        let correctedTitle: String
        if title.hasPrefix("Monitor Output: "),
           controls.contains(where: { $0.endpoint == "/datastore/ext/obank/1/ch/0/stereoTrim" }) {
            correctedTitle = "Output: \(String(title.dropFirst("Monitor Output: ".count)))"
        } else {
            correctedTitle = title
        }

        let correctedID = correctedTitle == title ? id : stableConfigurationID("source-\(correctedTitle)")
        return MixerControlSourceConfig(
            id: correctedID,
            title: correctedTitle,
            controls: controls.map {
                $0.correctedPhysicalMonitorOutput().replacingSourceID(correctedID)
            }
        )
    }

    func normalizedStereoChannelTitle() -> MixerControlSourceConfig {
        guard title.hasPrefix("Channel: "),
              controls.contains(where: { $0.hasLinkedStereoEndpoint }) else {
            return self
        }

        let channelName = String(title.dropFirst("Channel: ".count))
        guard !channelName.hasSuffix(" L/R") else {
            return self
        }

        let normalizedTitle = "Channel: \(channelName.strippedStereoSideSuffix) L/R"
        let normalizedID = stableConfigurationID("source-\(normalizedTitle)")
        return MixerControlSourceConfig(
            id: normalizedID,
            title: normalizedTitle,
            controls: controls.map { $0.replacingSourceID(normalizedID) }
        )
    }

    func correctedOutputMeters(using offsets: OutputMeterOffsets) -> MixerControlSourceConfig {
        MixerControlSourceConfig(
            id: id,
            title: title,
            controls: controls.map { $0.correctedOutputMeter(using: offsets) }
        )
    }
}

private extension MixerControlSectionConfig {
    func correctedPhysicalMonitorOutput() -> MixerControlSectionConfig {
        MixerControlSectionConfig(
            id: id,
            title: title,
            isEnabled: isEnabled,
            controls: controls.map { $0.correctedPhysicalMonitorOutput() }
        )
    }

    func remappedSourceIDs(_ replacements: [String: String]) -> MixerControlSectionConfig {
        MixerControlSectionConfig(
            id: id,
            title: title,
            isEnabled: isEnabled,
            controls: controls.map { $0.remappedSourceID(replacements) }
        )
    }

    func correctedOutputMeters(using offsets: OutputMeterOffsets) -> MixerControlSectionConfig {
        MixerControlSectionConfig(
            id: id,
            title: title,
            isEnabled: isEnabled,
            controls: controls.map { $0.correctedOutputMeter(using: offsets) }
        )
    }
}

private extension MixerControlConfig {
    var hasLinkedStereoEndpoint: Bool {
        !linkedEndpoints.isEmpty
            || !linkedMeterEndpoints.isEmpty
            || !linkedMuteEndpoints.isEmpty
            || !linkedPadEndpoints.isEmpty
            || !linkedPhantomEndpoints.isEmpty
    }

    func remappedSourceID(_ replacements: [String: String]) -> MixerControlConfig {
        guard let replacement = replacements[sourceID], replacement != sourceID else {
            return self
        }
        return replacingSourceID(replacement)
    }

    func replacingSourceID(_ replacement: String) -> MixerControlConfig {
        MixerControlConfig(
            id: id,
            title: title,
            kind: kind,
            displayStyle: displayStyle,
            sourceID: replacement,
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

    func correctedPhysicalMonitorOutput() -> MixerControlConfig {
        if endpoint == "/datastore/mix/monitor/0/matrix/fader" {
            return replacingProperties(
                title: title == "Level" ? "Trim" : title,
                displayStyle: .trimFader,
                endpoint: "/datastore/ext/ab/trim",
                meterEndpoint: "meters/mix/level/5/14",
                muteEndpoint: "/datastore/ext/ab/mute",
                minValue: -128,
                maxValue: 0
            )
        }

        if endpoint == "/datastore/mix/monitor/0/matrix/mute" {
            return replacingProperties(endpoint: "/datastore/ext/ab/mute")
        }

        if muteEndpoint == "/datastore/mix/monitor/0/matrix/mute" {
            return replacingProperties(muteEndpoint: "/datastore/ext/ab/mute")
        }

        return self
    }

    func replacingProperties(
        title: String? = nil,
        displayStyle: MixerControlDisplayStyle? = nil,
        endpoint: String? = nil,
        meterEndpoint: String? = nil,
        muteEndpoint: String? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil
    ) -> MixerControlConfig {
        MixerControlConfig(
            id: id,
            title: title ?? self.title,
            kind: kind,
            displayStyle: displayStyle ?? self.displayStyle,
            sourceID: sourceID,
            controlID: controlID,
            endpoint: endpoint ?? self.endpoint,
            linkedEndpoints: linkedEndpoints,
            meterEndpoint: meterEndpoint ?? self.meterEndpoint,
            linkedMeterEndpoints: linkedMeterEndpoints,
            muteEndpoint: muteEndpoint ?? self.muteEndpoint,
            linkedMuteEndpoints: linkedMuteEndpoints,
            padEndpoint: padEndpoint,
            linkedPadEndpoints: linkedPadEndpoints,
            phantomEndpoint: phantomEndpoint,
            linkedPhantomEndpoints: linkedPhantomEndpoints,
            minValue: minValue ?? self.minValue,
            maxValue: maxValue ?? self.maxValue
        )
    }

    func correctedOutputMeter(using offsets: OutputMeterOffsets) -> MixerControlConfig {
        if endpoint == "/datastore/mix/monitor/0/matrix/fader" {
            return correctedPhysicalMonitorOutput()
        }

        guard let meterEndpoint = offsets.meterEndpoint(for: endpoint) else {
            return self
        }

        return MixerControlConfig(
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
    var strippedStereoSideSuffix: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" Left", " Right", " L", " R"] where trimmed.hasSuffix(suffix) {
            return String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

private func stableConfigurationID(_ value: String) -> String {
    value
        .lowercased()
        .map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        .reduce(into: "") { partial, character in
            if !(partial.last == "-" && character == "-") {
                partial.append(character)
            }
        }
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

private extension Array where Element == MixerControlSourceConfig {
    func deduplicated() -> [MixerControlSourceConfig] {
        var seen: Set<String> = []
        var result: [MixerControlSourceConfig] = []

        for source in self {
            let key = ([source.title] + source.controls.map { "\($0.title):\($0.endpoint)" }).joined(separator: "|")
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(source)
        }

        return result
    }
}

private extension Array where Element == MixerControlSectionConfig {
    var looksLikeGeneratedMixerCatalog: Bool {
        count > 20 || contains { section in
            section.title.hasPrefix("Input: ")
                || section.title.hasPrefix("Channel: ")
                || section.title.hasPrefix("Output: ")
                || section.title.hasPrefix("Phones ")
                || section.title.hasPrefix("Monitor")
                || section.title.hasPrefix("Mixer Group ")
        }
    }

    func catalogSources() -> [MixerControlSourceConfig] {
        enumerated().map { sectionIndex, section in
            let sourceID = stableID("source-\(sectionIndex)-\(section.title)")
            let controls = section.controls.enumerated().map { controlIndex, control in
                MixerControlConfig(
                    id: control.id,
                    title: control.title,
                    kind: control.kind,
                    displayStyle: control.displayStyle,
                    sourceID: sourceID,
                    controlID: control.controlID.isEmpty
                        ? stableID("control-\(controlIndex)-\(control.title)-\(control.endpoint)")
                        : control.controlID,
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
            return MixerControlSourceConfig(id: sourceID, title: section.title, controls: controls)
        }
    }

    func looksLikeActiveCopy(of sources: [MixerControlSourceConfig]) -> Bool {
        guard count > 20, count == sources.count else {
            return false
        }

        return zip(self, sources).allSatisfy { section, source in
            section.title == source.title
                && section.controls.map(\.endpoint) == source.controls.map(\.endpoint)
        }
    }

    private func stableID(_ value: String) -> String {
        value
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { partial, character in
                if !(partial.last == "-" && character == "-") {
                    partial.append(character)
                }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
