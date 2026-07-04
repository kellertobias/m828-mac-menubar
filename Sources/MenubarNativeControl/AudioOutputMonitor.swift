import AppKit
import CoreAudio
import Foundation

struct AudioOutputProcess: Equatable {
    var pid: pid_t
    var bundleID: String
    var appName: String
    var executableName: String

    var searchableValues: [String] {
        [bundleID, appName, executableName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

final class AudioOutputMonitor {
    func currentOutputProcesses() -> [AudioOutputProcess] {
        processObjectIDs()
            .compactMap(processInfo(for:))
            .filter { $0.isRunningOutput }
            .map(\.process)
            .filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
            .sorted { lhs, rhs in
                lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
            }
    }

    func hasMatchingOutput(for identifiers: [String], in processes: [AudioOutputProcess]) -> Bool {
        guard !processes.isEmpty else {
            return false
        }

        let terms = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else {
            return true
        }

        return processes.contains { process in
            let values = process.searchableValues
            return terms.contains { term in
                values.contains { value in
                    value == term || value.contains(term)
                }
            }
        }
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processIDs
        )
        guard dataStatus == noErr else {
            return []
        }

        return processIDs.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func processInfo(for objectID: AudioObjectID) -> (process: AudioOutputProcess, isRunningOutput: Bool)? {
        guard let pid = readPID(objectID),
              let isRunningOutput = readUInt32(objectID, selector: kAudioProcessPropertyIsRunningOutput).map({ $0 != 0 }) else {
            return nil
        }

        let bundleID = readBundleID(objectID)
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let appName = runningApp?.localizedName ?? bundleID ?? "PID \(pid)"
        let executableName = runningApp?.executableURL?.lastPathComponent ?? ""

        return (
            AudioOutputProcess(
                pid: pid,
                bundleID: bundleID ?? "",
                appName: appName,
                executableName: executableName
            ),
            isRunningOutput
        )
    }

    private func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &pid)
        return status == noErr ? pid : nil
    }

    private func readUInt32(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    private func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        var bundleID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &bundleID)
        guard status == noErr else {
            return nil
        }
        return bundleID?.takeRetainedValue() as String?
    }

    private func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
