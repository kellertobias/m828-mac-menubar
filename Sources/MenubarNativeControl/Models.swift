import Foundation

enum ChannelRole: String, Codable, CaseIterable {
    case monitor = "Monitor"
    case headphones = "Headphones"
    case input = "Input"
}

enum SliderScale: String, Codable, CaseIterable {
    case logarithmic = "Logarithmic"
    case linear = "Linear"
}

enum MixerControlKind: String, Codable {
    case slider = "Slider"
    case toggle = "Toggle"
}

enum MixerControlDisplayStyle: String, Codable {
    case simpleToggle = "Simple Toggle"
    case muteButton = "Mute Button"
    case simpleFader = "Simple Fader"
    case meterFader = "Meter Fader"
    case trimFader = "Trim Fader"
}

struct MixerControlConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var kind: MixerControlKind
    var displayStyle: MixerControlDisplayStyle
    var sourceID: String
    var controlID: String
    var endpoint: String
    var linkedEndpoints: [String]
    var meterEndpoint: String
    var linkedMeterEndpoints: [String]
    var muteEndpoint: String
    var linkedMuteEndpoints: [String]
    var padEndpoint: String
    var linkedPadEndpoints: [String]
    var phantomEndpoint: String
    var linkedPhantomEndpoints: [String]
    var minValue: Double
    var maxValue: Double

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case displayStyle
        case sourceID
        case controlID
        case endpoint
        case linkedEndpoints
        case meterEndpoint
        case linkedMeterEndpoints
        case muteEndpoint
        case linkedMuteEndpoints
        case padEndpoint
        case linkedPadEndpoints
        case phantomEndpoint
        case linkedPhantomEndpoints
        case minValue
        case maxValue
    }

    init(
        id: UUID = UUID(),
        title: String,
        kind: MixerControlKind,
        displayStyle: MixerControlDisplayStyle? = nil,
        sourceID: String = "",
        controlID: String = "",
        endpoint: String,
        linkedEndpoints: [String] = [],
        meterEndpoint: String = "",
        linkedMeterEndpoints: [String] = [],
        muteEndpoint: String = "",
        linkedMuteEndpoints: [String] = [],
        padEndpoint: String = "",
        linkedPadEndpoints: [String] = [],
        phantomEndpoint: String = "",
        linkedPhantomEndpoints: [String] = [],
        minValue: Double = 0,
        maxValue: Double = 1
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.displayStyle = displayStyle ?? (kind == .toggle ? .simpleToggle : .simpleFader)
        self.sourceID = sourceID
        self.controlID = controlID
        self.endpoint = endpoint
        self.linkedEndpoints = linkedEndpoints
        self.meterEndpoint = meterEndpoint
        self.linkedMeterEndpoints = linkedMeterEndpoints
        self.muteEndpoint = muteEndpoint
        self.linkedMuteEndpoints = linkedMuteEndpoints
        self.padEndpoint = padEndpoint
        self.linkedPadEndpoints = linkedPadEndpoints
        self.phantomEndpoint = phantomEndpoint
        self.linkedPhantomEndpoints = linkedPhantomEndpoints
        self.minValue = minValue
        self.maxValue = maxValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(MixerControlKind.self, forKey: .kind)
        displayStyle = try container.decodeIfPresent(MixerControlDisplayStyle.self, forKey: .displayStyle)
            ?? (kind == .toggle ? .simpleToggle : .simpleFader)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        controlID = try container.decodeIfPresent(String.self, forKey: .controlID) ?? ""
        endpoint = try container.decode(String.self, forKey: .endpoint)
        linkedEndpoints = try container.decodeIfPresent([String].self, forKey: .linkedEndpoints) ?? []
        meterEndpoint = try container.decodeIfPresent(String.self, forKey: .meterEndpoint) ?? ""
        linkedMeterEndpoints = try container.decodeIfPresent([String].self, forKey: .linkedMeterEndpoints) ?? []
        muteEndpoint = try container.decodeIfPresent(String.self, forKey: .muteEndpoint) ?? ""
        linkedMuteEndpoints = try container.decodeIfPresent([String].self, forKey: .linkedMuteEndpoints) ?? []
        padEndpoint = try container.decodeIfPresent(String.self, forKey: .padEndpoint) ?? ""
        linkedPadEndpoints = try container.decodeIfPresent([String].self, forKey: .linkedPadEndpoints) ?? []
        phantomEndpoint = try container.decodeIfPresent(String.self, forKey: .phantomEndpoint) ?? ""
        linkedPhantomEndpoints = try container.decodeIfPresent([String].self, forKey: .linkedPhantomEndpoints) ?? []
        minValue = try container.decodeIfPresent(Double.self, forKey: .minValue) ?? 0
        maxValue = try container.decodeIfPresent(Double.self, forKey: .maxValue) ?? 1
    }
}

struct MixerControlSectionConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var isEnabled: Bool
    var controls: [MixerControlConfig]

    init(
        id: UUID = UUID(),
        title: String,
        isEnabled: Bool = true,
        controls: [MixerControlConfig]
    ) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.controls = controls
    }
}

struct MixerControlSourceConfig: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var controls: [MixerControlConfig]
}

struct ChannelConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var role: ChannelRole
    var displayName: String
    var isEnabled: Bool
    var volumeEndpoint: String
    var levelEndpoint: String
    var muteEndpoint: String
    var supportsMute: Bool
    var nameEndpoint: String
    var sliderScale: SliderScale

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case displayName
        case isEnabled
        case volumeEndpoint
        case levelEndpoint
        case muteEndpoint
        case supportsMute
        case nameEndpoint
        case sliderScale
    }

    init(
        id: UUID = UUID(),
        role: ChannelRole,
        displayName: String,
        isEnabled: Bool = true,
        volumeEndpoint: String = "",
        levelEndpoint: String = "",
        muteEndpoint: String = "",
        supportsMute: Bool = false,
        nameEndpoint: String = "",
        sliderScale: SliderScale = .logarithmic
    ) {
        self.id = id
        self.role = role
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.volumeEndpoint = volumeEndpoint
        self.levelEndpoint = levelEndpoint
        self.muteEndpoint = muteEndpoint
        self.supportsMute = supportsMute
        self.nameEndpoint = nameEndpoint
        self.sliderScale = sliderScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChannelRole.self, forKey: .role)
        displayName = try container.decode(String.self, forKey: .displayName)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        volumeEndpoint = try container.decode(String.self, forKey: .volumeEndpoint)
        levelEndpoint = try container.decode(String.self, forKey: .levelEndpoint)
        muteEndpoint = try container.decode(String.self, forKey: .muteEndpoint)
        supportsMute = try container.decodeIfPresent(Bool.self, forKey: .supportsMute) ?? (role != .headphones)
        nameEndpoint = try container.decode(String.self, forKey: .nameEndpoint)
        sliderScale = try container.decode(SliderScale.self, forKey: .sliderScale)
    }
}

struct SpecialConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var setEndpoint: String
    var stateEndpoint: String
    var onValue: String
    var offValue: String
    var autoToggleWithMedia: Bool
    var mediaAppIdentifiers: [String]
    var mediaTurnsSpecialOn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        setEndpoint: String = "",
        stateEndpoint: String = "",
        onValue: String = "1",
        offValue: String = "0",
        autoToggleWithMedia: Bool = false,
        mediaAppIdentifiers: [String] = [],
        mediaTurnsSpecialOn: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.setEndpoint = setEndpoint
        self.stateEndpoint = stateEndpoint
        self.onValue = onValue
        self.offValue = offValue
        self.autoToggleWithMedia = autoToggleWithMedia
        self.mediaAppIdentifiers = mediaAppIdentifiers
        self.mediaTurnsSpecialOn = mediaTurnsSpecialOn
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case setEndpoint
        case stateEndpoint
        case onValue
        case offValue
        case autoToggleWithMedia
        case mediaAppIdentifiers
        case mediaTurnsSpecialOn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        setEndpoint = try container.decode(String.self, forKey: .setEndpoint)
        stateEndpoint = try container.decode(String.self, forKey: .stateEndpoint)
        onValue = try container.decode(String.self, forKey: .onValue)
        offValue = try container.decode(String.self, forKey: .offValue)
        autoToggleWithMedia = try container.decodeIfPresent(Bool.self, forKey: .autoToggleWithMedia) ?? false
        mediaAppIdentifiers = try container.decodeIfPresent([String].self, forKey: .mediaAppIdentifiers) ?? []
        mediaTurnsSpecialOn = try container.decodeIfPresent(Bool.self, forKey: .mediaTurnsSpecialOn) ?? true
    }
}

struct AppConfiguration: Codable, Equatable {
    var mixerHost: String
    var launchAtLogin: Bool
    var channels: [ChannelConfig]
    var specials: [SpecialConfig]
    var controlSections: [MixerControlSectionConfig]
    var controlSources: [MixerControlSourceConfig]
    var pollingInterval: TimeInterval

    enum CodingKeys: String, CodingKey {
        case mixerHost
        case launchAtLogin
        case channels
        case specials
        case controlSections
        case controlSources
        case pollingInterval
    }

    static let defaults = AppConfiguration(
        mixerHost: "192.168.1.100",
        launchAtLogin: false,
        channels: [],
        specials: [],
        controlSections: [],
        controlSources: [],
        pollingInterval: 0.05
    )

    init(
        mixerHost: String,
        launchAtLogin: Bool,
        channels: [ChannelConfig],
        specials: [SpecialConfig],
        controlSections: [MixerControlSectionConfig],
        controlSources: [MixerControlSourceConfig],
        pollingInterval: TimeInterval
    ) {
        self.mixerHost = mixerHost
        self.launchAtLogin = launchAtLogin
        self.channels = channels
        self.specials = specials
        self.controlSections = controlSections
        self.controlSources = controlSources
        self.pollingInterval = pollingInterval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mixerHost = try container.decode(String.self, forKey: .mixerHost)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        channels = try container.decode([ChannelConfig].self, forKey: .channels)
        specials = try container.decode([SpecialConfig].self, forKey: .specials)
        controlSections = try container.decodeIfPresent([MixerControlSectionConfig].self, forKey: .controlSections) ?? []
        controlSources = try container.decodeIfPresent([MixerControlSourceConfig].self, forKey: .controlSources) ?? []
        pollingInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .pollingInterval) ?? Self.defaults.pollingInterval
    }
}

enum VolumeMapper {
    static func mixerValue(from sliderValue: Double, scale: SliderScale) -> Double {
        let clamped = min(max(sliderValue, 0), 1)
        switch scale {
        case .linear:
            return clamped
        case .logarithmic:
            return pow(clamped, 2.4)
        }
    }

    static func sliderValue(from mixerValue: Double, scale: SliderScale) -> Double {
        let clamped = min(max(mixerValue, 0), 1)
        switch scale {
        case .linear:
            return clamped
        case .logarithmic:
            return pow(clamped, 1.0 / 2.4)
        }
    }
}
