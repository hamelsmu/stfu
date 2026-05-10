import AppKit
import ApplicationServices
import CoreAudio
import Foundation

struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
}

struct CommandResult {
    let status: Int32
    let output: String
    let error: String
}

enum STFUError: Error, CustomStringConvertible {
    case audioStatus(OSStatus, String)

    var description: String {
        switch self {
        case let .audioStatus(status, context):
            return "\(context): CoreAudio returned \(status)"
        }
    }
}

let usage = """
stfu: close the macOS app or browser tab that is currently producing audio

Usage:
  stfu [--dry-run] [--list] [--all] [--verbose]
  stfu --doctor
  stfu --request-accessibility

Options:
  --dry-run                Print what would be closed.
  --list                   List processes CoreAudio says are producing output.
  --all                    Close every detected audio producer, not just the first.
  --bundle-id ID           Only act on this bundle id, including helper processes.
  --verbose                Print extra detail while looking for browser tabs.
  --doctor                 Check browser support and permissions.
  --request-accessibility  Ask macOS for Accessibility permission.
  -h, --help               Show this help.
"""

struct Options {
    var dryRun = false
    var list = false
    var all = false
    var verbose = false
    var doctor = false
    var requestAccessibility = false
    var bundleID: String?
}

func parseOptions(_ args: [String]) -> Options? {
    var options = Options()
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--dry-run":
            options.dryRun = true
        case "--list":
            options.list = true
        case "--all":
            options.all = true
        case "--bundle-id":
            index += 1
            guard index < args.count else {
                fputs("--bundle-id requires a value\n\n\(usage)\n", stderr)
                return nil
            }
            options.bundleID = args[index]
        case "--verbose":
            options.verbose = true
        case "--doctor":
            options.doctor = true
        case "--request-accessibility":
            options.requestAccessibility = true
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fputs("Unknown argument: \(arg)\n\n\(usage)\n", stderr)
            return nil
        }
        index += 1
    }
    return options
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func audioObjectIDs(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> [AudioObjectID] {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else {
        throw STFUError.audioStatus(status, "Unable to read property size")
    }
    guard size > 0 else {
        return []
    }

    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var values = Array(repeating: AudioObjectID(0), count: count)
    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values)
    guard status == noErr else {
        throw STFUError.audioStatus(status, "Unable to read object IDs")
    }
    return values
}

func audioUInt32(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> UInt32 {
    var address = propertyAddress(selector, scope: scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr else {
        throw STFUError.audioStatus(status, "Unable to read UInt32 property")
    }
    return value
}

func audioPID(objectID: AudioObjectID) throws -> pid_t {
    var address = propertyAddress(kAudioProcessPropertyPID)
    var value = pid_t(0)
    var size = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr else {
        throw STFUError.audioStatus(status, "Unable to read process PID")
    }
    return value
}

func audioString(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr, let retained = value else {
        return nil
    }
    return retained.takeRetainedValue() as String
}

func processName(pid: pid_t) -> String {
    if let app = NSRunningApplication(processIdentifier: pid) {
        return app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
    }

    let result = runCommand("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "pid \(pid)" : URL(fileURLWithPath: trimmed).lastPathComponent
}

func outputAudioProcesses() throws -> [AudioProcess] {
    let processIDs = try audioObjectIDs(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyProcessObjectList
    )

    var processes: [AudioProcess] = []
    for objectID in processIDs {
        let running = (try? audioUInt32(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningOutput
        )) ?? 0
        guard running != 0 else {
            continue
        }

        let pid = try audioPID(objectID: objectID)
        processes.append(AudioProcess(
            objectID: objectID,
            pid: pid,
            bundleID: audioString(objectID: objectID, selector: kAudioProcessPropertyBundleID),
            name: processName(pid: pid)
        ))
    }

    return Array(Set(processes)).sorted { $0.pid < $1.pid }
}

func runCommand(_ launchPath: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let stdoutBox = DataBox()
    let stderrBox = DataBox()
    let outputGroup = DispatchGroup()

    outputGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.set(stdout.fileHandleForReading.readDataToEndOfFile())
        outputGroup.leave()
    }

    outputGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.set(stderr.fileHandleForReading.readDataToEndOfFile())
        outputGroup.leave()
    }

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        stdout.fileHandleForReading.closeFile()
        stderr.fileHandleForReading.closeFile()
        outputGroup.wait()
        return CommandResult(status: 127, output: "", error: String(describing: error))
    }

    outputGroup.wait()
    let output = String(data: stdoutBox.value(), encoding: .utf8) ?? ""
    let error = String(data: stderrBox.value(), encoding: .utf8) ?? ""
    return CommandResult(status: process.terminationStatus, output: output, error: error)
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

func runAppleScript(_ source: String) -> CommandResult {
    runCommand("/usr/bin/osascript", ["-e", source])
}

func appleScriptString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
