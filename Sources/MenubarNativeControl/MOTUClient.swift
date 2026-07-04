import Foundation

enum MixerIOKind: String, Codable {
    case input = "Input"
    case output = "Output"
    case other = "Other"
}

struct MixerIOEndpoint: Identifiable, Codable, Hashable {
    var id: String { "\(kind.rawValue):\(name):\(baseEndpoint)" }
    var kind: MixerIOKind
    var name: String
    var baseEndpoint: String
    var nameEndpoint: String
    var volumeEndpoint: String
    var levelEndpoint: String
    var muteEndpoint: String
}

private enum MixerBusKind {
    case aux
    case group

    var datastorePrefix: String {
        switch self {
        case .aux: return "mix/aux"
        case .group: return "mix/group"
        }
    }

    var inputBankName: String {
        switch self {
        case .aux: return "Mix Aux"
        case .group: return "Mix Group"
        }
    }

    var titlePrefix: String {
        switch self {
        case .aux: return "Aux"
        case .group: return "Group"
        }
    }
}

private struct MixerBusDestination {
    var index: Int
    var title: String
    var linkedIndex: Int?
}

final class MOTUClient {
    private static let monitorLevelMeterEndpoint = "meters/mix/level/5/14"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func readNumber(host: String, endpoint: String, completion: @escaping (Double?) -> Void) {
        if endpoint.normalizedEndpointPath.hasPrefix("meters/") {
            readMeterNumber(host: host, endpoint: endpoint, completion: completion)
            return
        }

        get(host: host, endpoint: endpoint) { result in
            completion(result.flatMap(Self.parseNumber))
        }
    }

    func readString(host: String, endpoint: String, completion: @escaping (String?) -> Void) {
        get(host: host, endpoint: endpoint) { result in
            completion(result.flatMap(Self.parseString))
        }
    }

    func readBool(host: String, endpoint: String, onValue: String, completion: @escaping (Bool?) -> Void) {
        readString(host: host, endpoint: endpoint) { value in
            guard let value else {
                completion(nil)
                return
            }
            completion(Self.valuesMatch(value, onValue))
        }
    }

    func sendValue(host: String, endpoint: String, value: String, completion: ((Bool) -> Void)? = nil) {
        guard var request = requestForValue(host: host, endpoint: endpoint, value: value) else {
            completion?(false)
            return
        }

        request.timeoutInterval = 2.0
        session.dataTask(with: request) { _, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else {
                completion?(false)
                return
            }
            completion?((200...299).contains(http.statusCode))
        }.resume()
    }

    func discoverNames(host: String, completion: @escaping ([String]) -> Void) {
        let candidates = [
            "/datastore",
            "/datastore/ext",
            "/datastore/ext/ibank",
            "/datastore/ext/obank",
            "/datastore/ext/mix"
        ]
        let lock = NSLock()
        let group = DispatchGroup()
        var names = Set<String>()

        for endpoint in candidates {
            group.enter()
            get(host: host, endpoint: endpoint) { data in
                if let data {
                    let found = Self.collectNames(from: data)
                    lock.lock()
                    names.formUnion(found)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(Array(names).sorted())
        }
    }

    func scanMixerIO(host: String, completion: @escaping ([MixerIOEndpoint]) -> Void) {
        let candidates = [
            "/datastore",
            "/datastore/ext",
            "/datastore/ext/ibank",
            "/datastore/ext/obank",
            "/datastore/ext/mix",
            "/datastore/ext/avb",
            "/datastore/ext/usb"
        ]
        let lock = NSLock()
        let group = DispatchGroup()
        var endpoints = Set<MixerIOEndpoint>()

        for endpoint in candidates {
            group.enter()
            get(host: host, endpoint: endpoint) { data in
                defer { group.leave() }
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) else {
                    return
                }

                let found = Self.collectMixerIO(from: object, rootEndpoint: endpoint)
                lock.lock()
                endpoints.formUnion(found)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(
                Array(endpoints).sorted { lhs, rhs in
                    if lhs.kind.rawValue != rhs.kind.rawValue {
                        return lhs.kind.rawValue < rhs.kind.rawValue
                    }
                    let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                    if nameOrder != .orderedSame {
                        return nameOrder == .orderedAscending
                    }
                    return lhs.baseEndpoint.localizedStandardCompare(rhs.baseEndpoint) == .orderedAscending
                }
            )
        }
    }

    func scanControlSources(host: String, completion: @escaping ([MixerControlSourceConfig]) -> Void) {
        get(host: host, endpoint: "/datastore") { data in
            guard let data,
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    completion([])
                }
                return
            }

            let sources = Self.buildControlSources(from: values)
            DispatchQueue.main.async {
                completion(sources)
            }
        }
    }

    func readMeterNumbers(host: String, endpoints: [String], completion: @escaping ([String: Double]) -> Void) {
        let requests = endpoints.reduce(into: [String: MeterRequest]()) { partial, endpoint in
            let normalized = endpoint.normalizedEndpointPath
            guard !normalized.isEmpty,
                  let request = MeterRequest(endpoint: normalized),
                  request.query != "ext/output" else {
                return
            }
            partial[endpoint] = request
        }

        let query = Set(requests.values.map(\.query))
            .sorted()
            .joined(separator: ":")
        guard !query.isEmpty else {
            completion([:])
            return
        }

        let escapedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        get(host: host, endpoint: "/meters?meters=\(escapedQuery)") { data in
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion([:])
                return
            }

            var result: [String: Double] = [:]
            for (endpoint, request) in requests {
                guard let values = object[request.responseKey] as? [Any],
                      request.index >= 0,
                      request.index < values.count,
                      let value = Self.meterNumber(from: values[request.index]) else {
                    continue
                }
                result[endpoint] = value
            }
            completion(result)
        }
    }

    private func readMeterNumber(host: String, endpoint: String, completion: @escaping (Double?) -> Void) {
        let meterPath = endpoint.normalizedEndpointPath
        guard let request = MeterRequest(endpoint: meterPath) else {
            completion(nil)
            return
        }

        let escapedQuery = request.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? request.query
        get(host: host, endpoint: "/meters?meters=\(escapedQuery)") { data in
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = object[request.responseKey] as? [Any],
                  request.index >= 0,
                  request.index < values.count else {
                completion(nil)
                return
            }

            completion(Self.meterNumber(from: values[request.index]))
        }
    }

    private func get(host: String, endpoint: String, completion: @escaping (Data?) -> Void) {
        guard let url = makeURL(host: host, endpoint: endpoint) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }

    private func requestForValue(host: String, endpoint: String, value: String) -> URLRequest? {
        if endpoint.contains("{value}") {
            let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            guard let url = makeURL(host: host, endpoint: endpoint.replacingOccurrences(of: "{value}", with: escaped)) else {
                return nil
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            return request
        }

        let normalizedPath = endpoint.normalizedEndpointPath
        if normalizedPath.hasPrefix("datastore/") {
            guard let url = makeURL(host: host, endpoint: "/datastore?client=menubar-native-control") else {
                return nil
            }

            let key = normalizedPath.removingDatastorePrefix
            let jsonValue: Any = Double(value) ?? value
            guard let jsonData = try? JSONSerialization.data(withJSONObject: [key: jsonValue]),
                  let jsonString = String(data: jsonData, encoding: .utf8),
                  let escaped = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return nil
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("json=\(escaped)".utf8)
            return request
        }

        guard let url = makeURL(host: host, endpoint: endpoint) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(value.utf8)
        return request
    }

    private func makeURL(host: String, endpoint: String) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedEndpoint.isEmpty else {
            return nil
        }

        if let absolute = URL(string: trimmedEndpoint), absolute.scheme != nil {
            return absolute
        }

        let normalizedHost: String
        if trimmedHost.lowercased().hasPrefix("http://") || trimmedHost.lowercased().hasPrefix("https://") {
            normalizedHost = String(trimmedHost.drop(while: { $0 == "/" }))
        } else {
            normalizedHost = "http://\(trimmedHost)"
        }

        let base = normalizedHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = trimmedEndpoint.hasPrefix("/") ? trimmedEndpoint : "/\(trimmedEndpoint)"
        return URL(string: "\(base)\(path)")
    }

    private static func parseNumber(_ data: Data) -> Double? {
        if let value = try? JSONSerialization.jsonObject(with: data), let number = findNumber(in: value) {
            return number
        }
        return parseString(data).flatMap(Double.init)
    }

    private static func parseString(_ data: Data) -> String? {
        if let value = try? JSONSerialization.jsonObject(with: data) {
            if let string = findString(in: value) {
                return string
            }
            if let number = findNumber(in: value) {
                return String(number)
            }
            if let bool = findBool(in: value) {
                return bool ? "1" : "0"
            }
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func findNumber(in value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let dictionary = value as? [String: Any] {
            for key in ["value", "val", "data", "current"] {
                if let nested = dictionary[key], let number = findNumber(in: nested) {
                    return number
                }
            }
        }
        return nil
    }

    private static func findString(in value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let dictionary = value as? [String: Any] {
            for key in ["value", "val", "data", "current", "name"] {
                if let nested = dictionary[key], let string = findString(in: nested) {
                    return string
                }
            }
        }
        return nil
    }

    private static func findBool(in value: Any) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let dictionary = value as? [String: Any] {
            for key in ["value", "val", "data", "current"] {
                if let nested = dictionary[key], let bool = findBool(in: nested) {
                    return bool
                }
            }
        }
        return nil
    }

    private static func collectNames(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        var names: [String] = []
        collectNames(from: object, names: &names)
        return names
    }

    private static func collectNames(from value: Any, names: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if key.lowercased() == "name", let name = nested as? String, !name.isEmpty {
                    names.append(name)
                }
                collectNames(from: nested, names: &names)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectNames(from: nested, names: &names)
            }
        }
    }

    private static func collectMixerIO(from value: Any, rootEndpoint: String) -> [MixerIOEndpoint] {
        var endpoints = collectFlatMixerIO(from: value)
        guard endpoints.isEmpty else {
            return endpoints
        }

        collectMixerIO(from: value, endpoint: rootEndpoint, endpoints: &endpoints)
        return endpoints
    }

    private static func collectFlatMixerIO(from value: Any) -> [MixerIOEndpoint] {
        guard let dictionary = value as? [String: Any] else {
            return []
        }

        let keys = Set(dictionary.keys)
        var endpoints: [MixerIOEndpoint] = []
        endpoints.append(contentsOf: collectFlatBankIO(
            keys: keys,
            values: dictionary,
            bankPrefix: "ext/ibank",
            kind: .input,
            meterPrefix: "meters/ext/input"
        ))
        endpoints.append(contentsOf: collectFlatBankIO(
            keys: keys,
            values: dictionary,
            bankPrefix: "ext/obank",
            kind: .output,
            meterPrefix: "meters/ext/output"
        ))
        return endpoints
    }

    private static func collectFlatBankIO(
        keys: Set<String>,
        values: [String: Any],
        bankPrefix: String,
        kind: MixerIOKind,
        meterPrefix: String
    ) -> [MixerIOEndpoint] {
        let bankNumbers = keys.compactMap { key -> Int? in
            let pattern = #"^\#(bankPrefix)/(\d+)/name$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
                  let range = Range(match.range(at: 1), in: key) else {
                return nil
            }
            return Int(key[range])
        }.sorted()

        var endpoints: [MixerIOEndpoint] = []
        var meterIndex = 0

        for bankNumber in bankNumbers {
            let bankName = stringValue(values["\(bankPrefix)/\(bankNumber)/name"]) ?? "\(kind.rawValue) Bank \(bankNumber)"
            let channelCount = intValue(values["\(bankPrefix)/\(bankNumber)/userCh"])
                ?? intValue(values["\(bankPrefix)/\(bankNumber)/calcCh"])
                ?? intValue(values["\(bankPrefix)/\(bankNumber)/maxCh"])
                ?? 0

            guard channelCount > 0 else {
                continue
            }

            for channelNumber in 0..<channelCount {
                let channelBase = "\(bankPrefix)/\(bankNumber)/ch/\(channelNumber)"
                let explicitName = stringValue(values["\(channelBase)/name"])
                let defaultName = stringValue(values["\(channelBase)/defaultName"])
                let channelName = [explicitName, defaultName, "\(bankName) \(channelNumber + 1)"]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "\(bankName) \(channelNumber + 1)"

                endpoints.append(
                    MixerIOEndpoint(
                        kind: kind,
                        name: channelName,
                        baseEndpoint: "/datastore/\(channelBase)",
                        nameEndpoint: "/datastore/\(channelBase)/name",
                        volumeEndpoint: firstExistingEndpoint(keys: keys, baseEndpoint: "/datastore/\(channelBase)", suffixes: [
                            "trim", "gain", "volume", "fader"
                        ]),
                        levelEndpoint: "\(meterPrefix)/\(meterIndex)",
                        muteEndpoint: firstExistingEndpoint(keys: keys, baseEndpoint: "/datastore/\(channelBase)", suffixes: [
                            "mute"
                        ])
                    )
                )
                meterIndex += 1
            }
        }

        return endpoints
    }

    private static func buildControlSections(from values: [String: Any]) -> [MixerControlSectionConfig] {
        let keys = Set(values.keys)
        var sections: [MixerControlSectionConfig] = []

        sections.append(contentsOf: buildInputControlSections(values: values, keys: keys))
        sections.append(contentsOf: buildOutputControlSections(values: values, keys: keys))
        sections.append(contentsOf: buildMonitorControlSections(values: values, keys: keys))
        sections.append(contentsOf: buildMixerChannelSections(values: values, keys: keys))
        sections.append(contentsOf: buildMixerGroupSections(values: values, keys: keys))

        return sections.filter { !$0.controls.isEmpty }
    }

    private static func buildControlSources(from values: [String: Any]) -> [MixerControlSourceConfig] {
        let keys = Set(values.keys)
        var inputTrimSections = buildInputControlSectionsByAssignment(values: values, keys: keys)
        let mixerChannelSections = buildMixerChannelSections(values: values, keys: keys)
        var sources: [MixerControlSourceConfig] = []

        if let mixBank = mixInputBank(values: values, keys: keys) {
            var index = 0
            while index < mixerChannelSections.count {
                let section = mixerChannelSections[index]
                let channelFormat = mixChannelFormat(values: values, channel: index)

                if channelFormat.width == 2, channelFormat.side == 1 {
                    index += 1
                    continue
                }

                let assignedInput = assignedInputKey(values: values, mixBank: mixBank, channel: index)
                let assignedInputSection = assignedInput.flatMap { inputTrimSections.removeValue(forKey: $0) }

                if channelFormat.width == 2,
                   channelFormat.side == 0,
                   index + 1 < mixerChannelSections.count {
                    let pairIndex = index + 1
                    let pairAssignedInput = assignedInputKey(values: values, mixBank: mixBank, channel: pairIndex)
                    let pairInputSection = pairAssignedInput.flatMap { inputTrimSections.removeValue(forKey: $0) }
                    let inputControls = linkedStereoControls(
                        primary: assignedInputSection?.controls ?? [],
                        secondary: pairInputSection?.controls ?? []
                    )
                    let channelControls = linkedStereoControls(
                        primary: section.controls,
                        secondary: mixerChannelSections[pairIndex].controls
                    )
                    let title = stereoChannelTitle(
                        left: section.title.removingPrefix("Channel: "),
                        right: mixerChannelSections[pairIndex].title.removingPrefix("Channel: ")
                    )
                    sources.append(makeControlSource(title: "Channel: \(title)", controls: inputControls + channelControls))
                    index += 2
                    continue
                }

                let controls = (assignedInputSection?.controls ?? []) + section.controls
                let title = section.title.removingPrefix("Channel: ")
                sources.append(makeControlSource(title: "Channel: \(title)", controls: controls))
                index += 1
            }
        } else {
            for section in mixerChannelSections {
                sources.append(makeControlSource(title: section.title, controls: section.controls))
            }
        }

        for section in inputTrimSections.values.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            sources.append(makeControlSource(title: section.title, controls: section.controls))
        }

        let nonChannelSections = buildOutputControlSections(values: values, keys: keys)
            + buildMonitorControlSections(values: values, keys: keys)
            + buildMixerGroupSections(values: values, keys: keys)
        for section in nonChannelSections {
            sources.append(makeControlSource(title: section.title, controls: section.controls))
        }

        return deduplicatedSources(sources)
    }

    private static func buildInputControlSections(values: [String: Any], keys: Set<String>) -> [MixerControlSectionConfig] {
        buildInputControlSectionsByAssignment(values: values, keys: keys)
            .values
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func buildInputControlSectionsByAssignment(values: [String: Any], keys: Set<String>) -> [String: MixerControlSectionConfig] {
        var sections: [String: MixerControlSectionConfig] = [:]
        var meterIndex = 0

        for bank in bankNumbers(keys: keys, prefix: "ext/ibank") {
            let count = activeChannelCount(values: values, prefix: "ext/ibank", bank: bank)
            guard count > 0 else { continue }

            for channel in 0..<count {
                let base = "ext/ibank/\(bank)/ch/\(channel)"
                let meterEndpoint = "meters/ext/input/\(meterIndex)"
                meterIndex += 1
                let hasHardwareControl = keys.contains("\(base)/trimRange")
                    || keys.contains("\(base)/pad")
                    || keys.contains("\(base)/48V")
                guard hasHardwareControl else { continue }

                var controls: [MixerControlConfig] = []
                if let range = rangeValue(values["\(base)/trimRange"]) {
                    controls.append(MixerControlConfig(
                        title: "Gain Trim",
                        kind: .slider,
                        displayStyle: .trimFader,
                        endpoint: "/datastore/\(base)/trim",
                        meterEndpoint: meterEndpoint,
                        padEndpoint: keys.contains("\(base)/pad") ? "/datastore/\(base)/pad" : "",
                        phantomEndpoint: keys.contains("\(base)/48V") ? "/datastore/\(base)/48V" : "",
                        minValue: range.min,
                        maxValue: range.max
                    ))
                }

                sections["\(bank):\(channel)"] = MixerControlSectionConfig(
                    title: "Input: \(channelName(values: values, base: base, fallback: "Input \(bank).\(channel + 1)"))",
                    controls: controls
                )
            }
        }

        return sections
    }

    private static func buildOutputControlSections(values: [String: Any], keys: Set<String>) -> [MixerControlSectionConfig] {
        var sections: [MixerControlSectionConfig] = []
        var outputMeterBase = 0

        for bank in bankNumbers(keys: keys, prefix: "ext/obank") {
            let bankName = stringValue(values["ext/obank/\(bank)/name"]) ?? ""
            let count = activeChannelCount(values: values, prefix: "ext/obank", bank: bank)
            guard count > 0 else { continue }

            for channel in stride(from: 0, to: count, by: 2) {
                let base = "ext/obank/\(bank)/ch/\(channel)"
                let meterEndpoint = "meters/ext/output/\(outputMeterBase + channel)"
                if let range = rangeValue(values["\(base)/stereoTrimRange"]) {
                    let title: String
                    let isMonitorOutput = isMonitorOutputName(bankName)
                    if bankName.localizedCaseInsensitiveContains("phone") {
                        title = "Phones \(channel / 2 + 1): \(stereoName(values: values, base: base, fallback: "Headphone \(channel / 2 + 1)"))"
                    } else if isMonitorOutput {
                        title = "Monitor Output: \(stereoName(values: values, base: base, fallback: "Main"))"
                    } else {
                        title = "Output: \(stereoName(values: values, base: base, fallback: "\(bankName) \(channel + 1)"))"
                    }

                    sections.append(MixerControlSectionConfig(
                        title: title,
                        controls: [
                            MixerControlConfig(
                                title: "Trim",
                                kind: .slider,
                                displayStyle: .trimFader,
                                endpoint: "/datastore/\(base)/stereoTrim",
                                meterEndpoint: meterEndpoint,
                                minValue: range.min,
                                maxValue: range.max
                            )
                        ]
                    ))
                } else {
                    let monoBase = "ext/obank/\(bank)/ch/\(channel)"
                    if let range = rangeValue(values["\(monoBase)/trimRange"]) {
                        let channelTitle = channelName(values: values, base: monoBase, fallback: "\(bankName) \(channel + 1)")
                        let isMonitorOutput = isMonitorOutputName("\(bankName) \(channelTitle)")
                        sections.append(MixerControlSectionConfig(
                            title: isMonitorOutput ? "Monitor Output: \(channelTitle)" : "Output: \(channelTitle)",
                            controls: [
                                MixerControlConfig(
                                    title: "Trim",
                                    kind: .slider,
                                    displayStyle: .trimFader,
                                    endpoint: "/datastore/\(monoBase)/trim",
                                    meterEndpoint: meterEndpoint,
                                    minValue: range.min,
                                    maxValue: range.max
                                )
                            ]
                        ))
                    }
                }
            }

            outputMeterBase += count
        }

        return sections
    }

    private static func buildMonitorControlSections(values: [String: Any], keys: Set<String>) -> [MixerControlSectionConfig] {
        var controls: [MixerControlConfig] = []

        let monitorBase = "ext/ab"
        if keys.contains("\(monitorBase)/trim") {
            let range = rangeValue(values["\(monitorBase)/trimRange"]) ?? (-128, 0)
            controls.append(MixerControlConfig(
                title: "Trim",
                kind: .slider,
                displayStyle: .trimFader,
                endpoint: "/datastore/\(monitorBase)/trim",
                meterEndpoint: monitorLevelMeterEndpoint,
                muteEndpoint: keys.contains("\(monitorBase)/mute") ? "/datastore/\(monitorBase)/mute" : "",
                minValue: range.min,
                maxValue: range.max
            ))
        }
        if keys.contains("\(monitorBase)/mute") {
            controls.append(MixerControlConfig(title: "Mute", kind: .toggle, displayStyle: .muteButton, endpoint: "/datastore/\(monitorBase)/mute"))
        }

        if !controls.isEmpty {
            return [MixerControlSectionConfig(title: "Monitor", controls: controls)]
        }

        let base = "mix/monitor/0/matrix"
        if keys.contains("\(base)/fader") {
            controls.append(MixerControlConfig(
                title: "Level",
                kind: .slider,
                displayStyle: .meterFader,
                endpoint: "/datastore/\(base)/fader",
                meterEndpoint: monitorLevelMeterEndpoint,
                muteEndpoint: keys.contains("\(base)/mute") ? "/datastore/\(base)/mute" : "",
                minValue: 0,
                maxValue: 4
            ))
        }
        if keys.contains("\(base)/mute") {
            controls.append(MixerControlConfig(title: "Mute", kind: .toggle, displayStyle: .muteButton, endpoint: "/datastore/\(base)/mute"))
        }

        return controls.isEmpty ? [] : [MixerControlSectionConfig(title: "Monitor", controls: controls)]
    }

    private static func buildMixerChannelSections(values: [String: Any], keys: Set<String>) -> [MixerControlSectionConfig] {
        guard let mixBank = bankNumbers(keys: keys, prefix: "ext/obank").first(where: {
            (stringValue(values["ext/obank/\($0)/name"]) ?? "").localizedCaseInsensitiveContains("Mix In")
        }) else {
            return []
        }

        let count = min(activeChannelCount(values: values, prefix: "ext/obank", bank: mixBank), 32)
        guard count > 0 else { return [] }

        var sections: [MixerControlSectionConfig] = []
        for channel in 0..<count {
            let channelBase = "mix/chan/\(channel)"
            var controls: [MixerControlConfig] = []

            appendSlider(&controls, title: "Channel", endpoint: "\(channelBase)/matrix/fader", keys: keys, minValue: 0, maxValue: 4)
            appendSlider(&controls, title: "Main", endpoint: "\(channelBase)/matrix/main/0/send", keys: keys, minValue: 0, maxValue: 4, style: .meterFader, meterEndpoint: "meters/ext/input/\(channel)", muteEndpoint: "/datastore/\(channelBase)/matrix/mute")

            let groupIndexes = sendIndexes(keys: keys, prefix: "\(channelBase)/matrix/group")
            for group in mixerBusDestinations(values: values, keys: keys, kind: .group, indexes: groupIndexes) {
                appendSlider(
                    &controls,
                    title: group.title,
                    endpoint: "\(channelBase)/matrix/group/\(group.index)/send",
                    keys: keys,
                    minValue: 0,
                    maxValue: 4,
                    linkedEndpoints: group.linkedIndex.map { ["\(channelBase)/matrix/group/\($0)/send"] } ?? []
                )
            }

            let auxIndexes = sendIndexes(keys: keys, prefix: "\(channelBase)/matrix/aux")
            for aux in mixerBusDestinations(values: values, keys: keys, kind: .aux, indexes: auxIndexes) {
                appendSlider(
                    &controls,
                    title: aux.title,
                    endpoint: "\(channelBase)/matrix/aux/\(aux.index)/send",
                    keys: keys,
                    minValue: 0,
                    maxValue: 4,
                    linkedEndpoints: aux.linkedIndex.map { ["\(channelBase)/matrix/aux/\($0)/send"] } ?? []
                )
            }

            appendToggle(&controls, title: "Mute", endpoint: "\(channelBase)/matrix/mute", keys: keys, style: .muteButton)
            appendToggle(&controls, title: "Comp", endpoint: "\(channelBase)/comp/enable", keys: keys)
            appendToggle(&controls, title: "EQ High", endpoint: "\(channelBase)/eq/highshelf/enable", keys: keys)
            appendToggle(&controls, title: "EQ High-Mid", endpoint: "\(channelBase)/eq/mid1/enable", keys: keys)
            appendToggle(&controls, title: "EQ Low-Mid", endpoint: "\(channelBase)/eq/mid2/enable", keys: keys)
            appendToggle(&controls, title: "EQ Low", endpoint: "\(channelBase)/eq/lowshelf/enable", keys: keys)

            sections.append(MixerControlSectionConfig(
                title: "Channel: \(channelName(values: values, base: "ext/obank/\(mixBank)/ch/\(channel)", fallback: "Channel \(channel + 1)"))",
                controls: controls
            ))
        }

        return sections
    }

    private static func buildMixerGroupSections(values: [String: Any], keys: Set<String>) -> [MixerControlSectionConfig] {
        let groupIndexes = keys.compactMap { key -> Int? in
            let prefix = "mix/group/"
            guard key.hasPrefix(prefix), key.hasSuffix("/matrix/fader") else { return nil }
            return Int(key.dropFirst(prefix.count).split(separator: "/").first ?? "")
        }.sorted()

        return mixerBusDestinations(values: values, keys: keys, kind: .group, indexes: groupIndexes).map { group in
            var controls: [MixerControlConfig] = []
            appendSlider(
                &controls,
                title: "Group Level",
                endpoint: "mix/group/\(group.index)/matrix/fader",
                keys: keys,
                minValue: 0,
                maxValue: 4,
                linkedEndpoints: group.linkedIndex.map { ["mix/group/\($0)/matrix/fader"] } ?? []
            )
            appendToggle(&controls, title: "Mute", endpoint: "mix/group/\(group.index)/matrix/mute", keys: keys, style: .muteButton)
            appendSlider(
                &controls,
                title: "Main",
                endpoint: "mix/group/\(group.index)/matrix/main/0/send",
                keys: keys,
                minValue: 0,
                maxValue: 4,
                linkedEndpoints: group.linkedIndex.map { ["mix/group/\($0)/matrix/main/0/send"] } ?? []
            )

            return MixerControlSectionConfig(title: "Mixer \(group.title)", controls: controls)
        }
    }

    private static func appendSlider(
        _ controls: inout [MixerControlConfig],
        title: String,
        endpoint: String,
        keys: Set<String>,
        minValue: Double,
        maxValue: Double,
        style: MixerControlDisplayStyle = .simpleFader,
        meterEndpoint: String = "",
        muteEndpoint: String = "",
        linkedEndpoints: [String] = []
    ) {
        guard keys.contains(endpoint) else { return }
        controls.append(MixerControlConfig(
            title: title,
            kind: .slider,
            displayStyle: style,
            endpoint: "/datastore/\(endpoint)",
            linkedEndpoints: linkedEndpoints
                .filter { keys.contains($0) }
                .map { "/datastore/\($0)" },
            meterEndpoint: meterEndpoint,
            muteEndpoint: muteEndpoint,
            minValue: minValue,
            maxValue: maxValue
        ))
    }

    private static func appendToggle(
        _ controls: inout [MixerControlConfig],
        title: String,
        endpoint: String,
        keys: Set<String>,
        style: MixerControlDisplayStyle = .simpleToggle
    ) {
        guard keys.contains(endpoint) else { return }
        controls.append(MixerControlConfig(title: title, kind: .toggle, displayStyle: style, endpoint: "/datastore/\(endpoint)"))
    }

    private static func sendIndexes(keys: Set<String>, prefix: String) -> [Int] {
        keys.compactMap { key -> Int? in
            guard key.hasPrefix("\(prefix)/"), key.hasSuffix("/send") else { return nil }
            return Int(key.dropFirst(prefix.count + 1).split(separator: "/").first ?? "")
        }.sorted()
    }

    private static func mixerBusDestinations(
        values: [String: Any],
        keys: Set<String>,
        kind: MixerBusKind,
        indexes: [Int]
    ) -> [MixerBusDestination] {
        let busBank = mixerBusInputBank(values: values, keys: keys, kind: kind)
        return indexes.sorted().compactMap { index in
            let format = mixerBusFormat(values: values, keys: keys, kind: kind, index: index, busBank: busBank)
            guard format.side == 0 else {
                return nil
            }

            let linkedIndex = format.width == 2 ? index + 1 : nil
            let numberTitle = linkedIndex.map {
                "\(kind.titlePrefix) \(index + 1)-\($0 + 1)"
            } ?? "\(kind.titlePrefix) \(index + 1)"
            if let busName = mixerBusOutputName(values: values, bank: busBank, index: index, linkedIndex: linkedIndex) {
                return MixerBusDestination(index: index, title: "\(numberTitle): \(busName)", linkedIndex: linkedIndex)
            }
            return MixerBusDestination(index: index, title: numberTitle, linkedIndex: linkedIndex)
        }
    }

    private static func mixerBusInputBank(values: [String: Any], keys: Set<String>, kind: MixerBusKind) -> Int? {
        bankNumbers(keys: keys, prefix: "ext/ibank").first(where: {
            (stringValue(values["ext/ibank/\($0)/name"]) ?? "").localizedCaseInsensitiveContains(kind.inputBankName)
        })
    }

    private static func mixerBusFormat(
        values: [String: Any],
        keys: Set<String>,
        kind: MixerBusKind,
        index: Int,
        busBank: Int?
    ) -> (width: Int, side: Int) {
        if let value = stringValue(values["\(kind.datastorePrefix)/\(index)/config/format"]) {
            return formatValue(value)
        }

        guard kind == .group,
              let busBank,
              index.isMultiple(of: 2),
              mixerBusChannelExists(values: values, bank: busBank, index: index + 1),
              !keys.contains("\(kind.datastorePrefix)/\(index + 1)/matrix/fader") else {
            return (1, 0)
        }

        return (2, 0)
    }

    private static func mixerBusChannelExists(values: [String: Any], bank: Int, index: Int) -> Bool {
        values["ext/ibank/\(bank)/ch/\(index)/name"] != nil
            || values["ext/ibank/\(bank)/ch/\(index)/defaultName"] != nil
    }

    private static func mixerBusOutputName(values: [String: Any], bank: Int?, index: Int, linkedIndex: Int?) -> String? {
        guard let bank else {
            return nil
        }

        let leftName = explicitChannelName(values: values, base: "ext/ibank/\(bank)/ch/\(index)")
        guard let linkedIndex else {
            return leftName
        }

        let rightName = explicitChannelName(values: values, base: "ext/ibank/\(bank)/ch/\(linkedIndex)")
        return stereoBusOutputName(left: leftName, right: rightName)
    }

    private static func explicitChannelName(values: [String: Any], base: String) -> String? {
        guard let name = stringValue(values["\(base)/name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private static func stereoBusOutputName(left: String?, right: String?) -> String? {
        let leftBase = left.map(strippedStereoSuffix(_:)) ?? ""
        let rightBase = right.map(strippedStereoSuffix(_:)) ?? ""

        if !leftBase.isEmpty, leftBase == rightBase {
            return leftBase
        }
        if !leftBase.isEmpty, rightBase.isEmpty {
            return leftBase
        }
        if leftBase.isEmpty, !rightBase.isEmpty {
            return rightBase
        }
        if let left, let right, !left.isEmpty, !right.isEmpty {
            return "\(left) / \(right)"
        }
        return nil
    }

    private static func bankNumbers(keys: Set<String>, prefix: String) -> [Int] {
        keys.compactMap { key -> Int? in
            guard key.hasPrefix("\(prefix)/"), key.hasSuffix("/name") else { return nil }
            return Int(key.dropFirst(prefix.count + 1).split(separator: "/").first ?? "")
        }.sorted()
    }

    private static func activeChannelCount(values: [String: Any], prefix: String, bank: Int) -> Int {
        let user = intValue(values["\(prefix)/\(bank)/userCh"]) ?? 0
        let calculated = intValue(values["\(prefix)/\(bank)/calcCh"]) ?? 0
        let max = intValue(values["\(prefix)/\(bank)/maxCh"]) ?? 0
        return user > 0 ? user : (calculated > 0 ? calculated : max)
    }

    private static func channelName(values: [String: Any], base: String, fallback: String) -> String {
        let explicit = stringValue(values["\(base)/name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return explicit
        }

        let defaultName = stringValue(values["\(base)/defaultName"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let defaultName, !defaultName.isEmpty {
            return defaultName
        }

        return fallback
    }

    private static func stereoName(values: [String: Any], base: String, fallback: String) -> String {
        let name = channelName(values: values, base: base, fallback: fallback)
        return strippedStereoSuffix(name)
    }

    private static func rangeValue(_ value: Any?) -> (min: Double, max: Double)? {
        guard let string = value as? String else { return nil }
        let parts = string.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return (min(parts[0], parts[1]), max(parts[0], parts[1]))
    }

    private static func makeControlSource(title: String, controls: [MixerControlConfig]) -> MixerControlSourceConfig {
        let sourceID = stableID("source-\(title)")
        let preparedControls = controls.enumerated().map { index, control in
            MixerControlConfig(
                id: control.id,
                title: displayTitle(for: control.title),
                kind: control.kind,
                displayStyle: control.displayStyle,
                sourceID: sourceID,
                controlID: stableID("control-\(index)-\(control.title)-\(control.endpoint)"),
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

        return MixerControlSourceConfig(id: sourceID, title: title, controls: preparedControls)
    }

    private static func deduplicatedSources(_ sources: [MixerControlSourceConfig]) -> [MixerControlSourceConfig] {
        var seen: Set<String> = []
        var result: [MixerControlSourceConfig] = []

        for source in sources {
            let key = ([source.title] + source.controls.map { "\($0.title):\($0.endpoint)" }).joined(separator: "|")
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(source)
        }

        return result
    }

    private static func displayTitle(for title: String) -> String {
        if title == "Comp" {
            return "Compressor"
        }
        if title == "Channel" {
            return "Channel Level"
        }
        if title == "Main" {
            return "Main Level"
        }
        return title
    }

    private static func linkedStereoControls(
        primary: [MixerControlConfig],
        secondary: [MixerControlConfig]
    ) -> [MixerControlConfig] {
        primary.map { control in
            guard let linked = secondary.first(where: { canLinkStereoControl($0, to: control) }) else {
                return control
            }

            return MixerControlConfig(
                id: control.id,
                title: control.title,
                kind: control.kind,
                displayStyle: control.displayStyle,
                sourceID: control.sourceID,
                controlID: control.controlID,
                endpoint: control.endpoint,
                linkedEndpoints: (control.linkedEndpoints + [linked.endpoint] + linked.linkedEndpoints).filter { !$0.isEmpty },
                meterEndpoint: control.meterEndpoint,
                linkedMeterEndpoints: (control.linkedMeterEndpoints + [linked.meterEndpoint] + linked.linkedMeterEndpoints).filter { !$0.isEmpty },
                muteEndpoint: control.muteEndpoint,
                linkedMuteEndpoints: (control.linkedMuteEndpoints + [linked.muteEndpoint] + linked.linkedMuteEndpoints).filter { !$0.isEmpty },
                padEndpoint: control.padEndpoint,
                linkedPadEndpoints: (control.linkedPadEndpoints + [linked.padEndpoint] + linked.linkedPadEndpoints).filter { !$0.isEmpty },
                phantomEndpoint: control.phantomEndpoint,
                linkedPhantomEndpoints: (control.linkedPhantomEndpoints + [linked.phantomEndpoint] + linked.linkedPhantomEndpoints).filter { !$0.isEmpty },
                minValue: control.minValue,
                maxValue: control.maxValue
            )
        }
    }

    private static func canLinkStereoControl(_ candidate: MixerControlConfig, to control: MixerControlConfig) -> Bool {
        candidate.kind == control.kind && displayTitle(for: candidate.title) == displayTitle(for: control.title)
    }

    private static func mixInputBank(values: [String: Any], keys: Set<String>) -> Int? {
        bankNumbers(keys: keys, prefix: "ext/obank").first(where: {
            (stringValue(values["ext/obank/\($0)/name"]) ?? "").localizedCaseInsensitiveContains("Mix In")
        })
    }

    private static func assignedInputKey(values: [String: Any], mixBank: Int, channel: Int) -> String? {
        guard let value = stringValue(values["ext/obank/\(mixBank)/ch/\(channel)/src"]),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func mixChannelFormat(values: [String: Any], channel: Int) -> (width: Int, side: Int) {
        guard let value = stringValue(values["mix/chan/\(channel)/config/format"]) else {
            return (1, 0)
        }

        return formatValue(value)
    }

    private static func formatValue(_ value: String) -> (width: Int, side: Int) {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else {
            return (1, 0)
        }
        return (max(parts[0], 1), max(parts[1], 0))
    }

    private static func stereoChannelTitle(left: String, right: String) -> String {
        let leftBase = strippedStereoSuffix(left)
        let rightBase = strippedStereoSuffix(right)
        if !leftBase.isEmpty, leftBase == rightBase, hasStereoSideSuffix(left), hasStereoSideSuffix(right) {
            return "\(leftBase) L/R"
        }

        if right.hasPrefix(leftBase), !leftBase.isEmpty {
            return leftBase
        }
        return left
    }

    private static func hasStereoSideSuffix(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(" L")
            || trimmed.hasSuffix(" R")
            || trimmed.hasSuffix(" Left")
            || trimmed.hasSuffix(" Right")
    }

    private static func strippedStereoSuffix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" Left", " Right", " L", " R"] where trimmed.hasSuffix(suffix) {
            return String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func isMonitorOutputName(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("monitor")
    }

    private static func matchingSourceKey(_ title: String) -> String {
        stableID(
            title
                .replacingOccurrences(of: "Input: ", with: "")
                .replacingOccurrences(of: "Channel: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func stableID(_ value: String) -> String {
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

    private static func firstExistingEndpoint(keys: Set<String>, baseEndpoint: String, suffixes: [String]) -> String {
        let datastorePath = baseEndpoint.normalizedEndpointPath.removingDatastorePrefix
        for suffix in suffixes where keys.contains("\(datastorePath)/\(suffix)") {
            return "\(baseEndpoint)/\(suffix)"
        }
        return ""
    }

    private static func collectMixerIO(from value: Any, endpoint: String, endpoints: inout [MixerIOEndpoint]) {
        if let dictionary = value as? [String: Any] {
            if let name = namedValue(in: dictionary), shouldIncludeNamedNode(name: name, endpoint: endpoint) {
                endpoints.append(
                    MixerIOEndpoint(
                        kind: classify(endpoint: endpoint, name: name),
                        name: name,
                        baseEndpoint: endpoint,
                        nameEndpoint: endpoint.appendingDatastorePathComponent("name"),
                        volumeEndpoint: firstEndpoint(in: dictionary, baseEndpoint: endpoint, matching: [
                            "volume", "vol", "fader", "gain", "trim"
                        ]),
                        levelEndpoint: firstEndpoint(in: dictionary, baseEndpoint: endpoint, matching: [
                            "level", "meter", "peak", "rms"
                        ]),
                        muteEndpoint: firstEndpoint(in: dictionary, baseEndpoint: endpoint, matching: [
                            "mute"
                        ])
                    )
                )
            }

            for (key, nested) in dictionary {
                collectMixerIO(
                    from: nested,
                    endpoint: endpoint.appendingDatastorePathComponent(key),
                    endpoints: &endpoints
                )
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                collectMixerIO(
                    from: nested,
                    endpoint: endpoint.appendingDatastorePathComponent(String(index)),
                    endpoints: &endpoints
                )
            }
        }
    }

    private static func namedValue(in dictionary: [String: Any]) -> String? {
        for key in ["name", "label", "title"] {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func shouldIncludeNamedNode(name: String, endpoint: String) -> Bool {
        let normalized = "\(endpoint) \(name)".lowercased()
        let relevantTerms = [
            "ibank", "obank", "input", "output", "mic", "line", "analog", "monitor",
            "phone", "headphone", "main", "avb", "usb", "return", "send"
        ]
        return relevantTerms.contains { normalized.contains($0) }
    }

    private static func classify(endpoint: String, name: String) -> MixerIOKind {
        let normalized = "\(endpoint) \(name)".lowercased()
        let outputTerms = ["obank", "output", "monitor", "phone", "headphone", "main", "out", "send"]
        let inputTerms = ["ibank", "input", "mic", "line", "in", "return"]

        if outputTerms.contains(where: { normalized.contains($0) }) {
            return .output
        }
        if inputTerms.contains(where: { normalized.contains($0) }) {
            return .input
        }
        return .other
    }

    private static func firstEndpoint(in dictionary: [String: Any], baseEndpoint: String, matching terms: [String]) -> String {
        let keys = dictionary.keys.sorted()
        guard let key = keys.first(where: { key in
            let normalized = key.lowercased()
            return terms.contains { normalized.contains($0) }
        }) else {
            return ""
        }
        return baseEndpoint.appendingDatastorePathComponent(key)
    }

    private static func valuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let leftNumber = Double(left), let rightNumber = Double(right) {
            return abs(leftNumber - rightNumber) < 0.0001
        }
        return left == right || (["true", "on", "yes"].contains(left) && ["1", "true", "on", "yes"].contains(right))
    }

    private static func meterNumber(from value: Any) -> Double? {
        let number: Double?
        if let intValue = value as? Int {
            number = Double(intValue)
        } else if let doubleValue = value as? Double {
            number = doubleValue
        } else if let numberValue = value as? NSNumber {
            number = numberValue.doubleValue
        } else {
            number = nil
        }

        guard let number else {
            return nil
        }
        return min(max(number / 1000.0, 0), 1)
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue)
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }
}

private struct MeterRequest {
    let query: String
    let responseKey: String
    let index: Int

    init?(endpoint: String) {
        let components = endpoint
            .normalizedEndpointPath
            .split(separator: "/")
            .map(String.init)

        guard components.first == "meters", components.count >= 4 else {
            return nil
        }

        query = "\(components[1])/\(components[2])"

        if components.count == 4, let index = Int(components[3]) {
            responseKey = query
            self.index = index
        } else if components.count >= 5, let index = Int(components[4]) {
            responseKey = "\(query)/\(components[3])"
            self.index = index
        } else {
            return nil
        }
    }
}

private extension String {
    var normalizedEndpointPath: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var removingDatastorePrefix: String {
        if hasPrefix("datastore/") {
            return String(dropFirst("datastore/".count))
        }
        return self
    }

    func appendingDatastorePathComponent(_ component: String) -> String {
        let safeComponent = component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
        if hasSuffix("/") {
            return "\(self)\(safeComponent)"
        }
        return "\(self)/\(safeComponent)"
    }

    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else {
            return self
        }
        return String(dropFirst(prefix.count))
    }
}
