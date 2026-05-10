import AppKit
import ApplicationServices
import CoreAudio
import Darwin
import Foundation

struct AudioProcess: Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
}

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let error: String
}

enum STFUError: Error, CustomStringConvertible, Sendable {
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

struct Options: Equatable {
    var dryRun = false
    var list = false
    var all = false
    var verbose = false
    var doctor = false
    var requestAccessibility = false
    var bundleID: String?
}

func parseOptions(_ args: [String], emitErrors: Bool = true) -> Options? {
    var options = Options()
    func emit(_ message: String) {
        if emitErrors {
            fputs(message, stderr)
        }
    }

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
                emit("--bundle-id requires a value\n\n\(usage)\n")
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
            emit("Unknown argument: \(arg)\n\n\(usage)\n")
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

        guard let pid = try? audioPID(objectID: objectID) else {
            continue
        }
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

func closeSafariTab(pid: pid_t, dryRun: Bool) -> Bool {
    guard let tab = safariTabInfo(pid: pid) else {
        return false
    }

    if dryRun {
        print("Would close Safari tab: \(tab.title) (\(tab.url))")
        return true
    }

    let script = """
    tell application "Safari"
      repeat with w in windows
        repeat with t in tabs of w
          try
            if (pid of t) is \(pid) then
              close t
              return "closed"
            end if
          end try
        end repeat
      end repeat
    end tell
    return ""
    """
    let result = runAppleScript(script)
    let match = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    if !match.isEmpty {
        print("Closed Safari tab: \(tab.title) (\(tab.url))")
        return true
    }
    return false
}

struct SafariTabInfo: Sendable {
    let title: String
    let url: String
}

enum SafariTabLookupResult: Sendable {
    case found(SafariTabInfo)
    case notFound
    case automationDenied(String)
}

func isAutomationDenied(_ result: CommandResult) -> Bool {
    let detail = "\(result.output)\n\(result.error)".lowercased()
    return result.status != 0
        && (detail.contains("-1743")
            || detail.contains("not authorized")
            || detail.contains("not allowed to send apple events")
            || detail.contains("not permitted")
            || detail.contains("privacy"))
}

func safariTabInfo(pid: pid_t) -> SafariTabInfo? {
    if case let .found(info) = safariTabLookup(pid: pid) {
        return info
    }
    return nil
}

func safariTabLookup(pid: pid_t) -> SafariTabLookupResult {
    let script = """
    tell application "Safari"
      repeat with w in windows
        repeat with t in tabs of w
          try
            if (pid of t) is \(pid) then
              return (name of t) & "\n" & (URL of t)
            end if
          end try
        end repeat
      end repeat
    end tell
    return ""
    """
    let result = runAppleScript(script)
    if isAutomationDenied(result) {
        let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return .automationDenied(detail.isEmpty ? result.output : detail)
    }

    let lines = result.output
        .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .map(String.init)
    guard let title = lines.first, !title.isEmpty else {
        return .notFound
    }
    return .found(SafariTabInfo(title: title, url: lines.dropFirst().first ?? ""))
}

func focusSafariTab(pid: pid_t) -> Bool {
    let script = """
    tell application "Safari"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          try
            if (pid of t) is \(pid) then
              set current tab of w to t
              set index of w to 1
              return "focused"
            end if
          end try
        end repeat
      end repeat
    end tell
    return ""
    """
    return !runAppleScript(script).output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

let chromiumApps: [(name: String, bundleID: String)] = [
    ("Google Chrome", "com.google.Chrome"),
    ("Google Chrome Canary", "com.google.Chrome.canary"),
    ("Microsoft Edge", "com.microsoft.edgemac"),
    ("Brave Browser", "com.brave.Browser"),
    ("Chromium", "org.chromium.Chromium"),
    ("Arc", "company.thebrowser.Browser")
]

func runningApplication(bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}

func parentPID(of pid: pid_t) -> pid_t? {
    let result = runCommand("/bin/ps", ["-p", "\(pid)", "-o", "ppid="])
    guard result.status == 0 else {
        return nil
    }
    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return pid_t(trimmed)
}

func chromiumAncestorApplication(for process: AudioProcess, bundleID: String) -> NSRunningApplication? {
    var pid = process.pid
    for _ in 0..<12 {
        if let app = NSRunningApplication(processIdentifier: pid),
           app.bundleIdentifier == bundleID {
            return app
        }

        guard let parent = parentPID(of: pid), parent > 1, parent != pid else {
            break
        }
        pid = parent
    }

    return nil
}

func runningChromiumApplication(for process: AudioProcess, bundleID: String) -> NSRunningApplication? {
    if let app = chromiumAncestorApplication(for: process, bundleID: bundleID) {
        return app
    }
    return runningApplication(bundleID: bundleID)
}

func isSafariRelated(_ process: AudioProcess) -> Bool {
    if process.bundleID == "com.apple.Safari"
        || process.bundleID?.hasPrefix("com.apple.Safari.") == true
        || process.bundleID?.hasPrefix("com.apple.WebKit.") == true {
        return true
    }

    var pid = process.pid
    for _ in 0..<12 {
        if let app = NSRunningApplication(processIdentifier: pid),
           app.bundleIdentifier == "com.apple.Safari" {
            return true
        }

        guard let parent = parentPID(of: pid), parent > 1, parent != pid else {
            break
        }
        pid = parent
    }

    return false
}

func accessibilityTrusted(prompt: Bool = false) -> Bool {
    guard prompt else {
        return AXIsProcessTrusted()
    }

    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func requestAccessibilityAccess() {
    if accessibilityTrusted(prompt: true) {
        print("Accessibility permission is already granted.")
    } else {
        print("macOS opened the Accessibility permission prompt.")
        print("Grant access for the app that runs stfu, then run stfu again.")
    }
}

func openAccessibilitySettings() {
    _ = accessibilityTrusted(prompt: true)

    let urls = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security"
    ]

    for value in urls {
        guard let url = URL(string: value), NSWorkspace.shared.open(url) else {
            continue
        }
        return
    }
}

func openAutomationSettings() {
    let urls = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
        "x-apple.systempreferences:com.apple.preference.security"
    ]

    for value in urls {
        guard let url = URL(string: value), NSWorkspace.shared.open(url) else {
            continue
        }
        return
    }
}

func axAttribute(_ element: AXUIElement, _ attribute: CFString) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard error == .success else {
        return nil
    }
    return value
}

func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    if let value = axAttribute(element, attribute) as? String {
        return value
    }
    if let value = axAttribute(element, attribute) as? NSNumber {
        return value.stringValue
    }
    return nil
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    let childAttributes: [CFString] = [
        kAXChildrenAttribute as CFString,
        kAXVisibleChildrenAttribute as CFString,
        kAXTabsAttribute as CFString,
        kAXRowsAttribute as CFString,
        kAXVisibleRowsAttribute as CFString,
        kAXColumnsAttribute as CFString,
        kAXVisibleColumnsAttribute as CFString,
        kAXLinkedUIElementsAttribute as CFString
    ]

    var children: [AXUIElement] = []
    var seen = Set<Int>()
    for attribute in childAttributes {
        guard let values = axAttribute(element, attribute) as? [AXUIElement] else {
            continue
        }
        for value in values {
            let id = Int(CFHash(value))
            if seen.insert(id).inserted {
                children.append(value)
            }
        }
    }
    return children
}

func axWindows(_ appElement: AXUIElement) -> [AXUIElement] {
    let windows = axAttribute(appElement, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
    guard let focusedValue = axAttribute(appElement, kAXFocusedWindowAttribute as CFString) else {
        return windows
    }
    guard CFGetTypeID(focusedValue as CFTypeRef) == AXUIElementGetTypeID() else {
        return windows
    }
    let focused = focusedValue as! AXUIElement

    var ordered = [focused]
    for window in windows where !CFEqual(window, focused) {
        ordered.append(window)
    }
    return ordered
}

func focusedWindow(for app: NSRunningApplication) -> AXUIElement? {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    guard let focusedValue = axAttribute(appElement, kAXFocusedWindowAttribute as CFString),
          CFGetTypeID(focusedValue as CFTypeRef) == AXUIElementGetTypeID() else {
        return nil
    }
    return (focusedValue as! AXUIElement)
}

func axOwnText(_ element: AXUIElement) -> [String] {
    [
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXValueAttribute,
        kAXHelpAttribute,
        kAXRoleAttribute,
        kAXRoleDescriptionAttribute,
        kAXSubroleAttribute,
        kAXIdentifierAttribute
    ].compactMap { axString(element, $0 as CFString) }
}

func axCombinedText(_ element: AXUIElement) -> String {
    axOwnText(element)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: " | ")
}

func isAudibleIndicatorText(_ text: String) -> Bool {
    let lower = text.lowercased()
    if lower.contains("unmute") || lower.contains("muted") {
        return false
    }
    return lower.contains("audio playing")
        || lower.contains("playing audio")
        || lower.contains("sound playing")
        || lower.contains("playing sound")
        || lower.contains("mute tab")
        || lower.contains("mute site")
}

func isTabLikeAXElement(_ element: AXUIElement) -> Bool {
    let role = (axString(element, kAXRoleAttribute as CFString) ?? "").lowercased()
    let roleDescription = (axString(element, kAXRoleDescriptionAttribute as CFString) ?? "").lowercased()
    let subrole = (axString(element, kAXSubroleAttribute as CFString) ?? "").lowercased()

    return role.contains("tab")
        || role.contains("radio")
        || roleDescription.contains("tab")
        || subrole.contains("tab")
}

struct AXAudibleTab {
    let element: AXUIElement
    let window: AXUIElement
    let label: String
    let title: String
    let index: Int?

    var candidate: ChromiumTabCandidate {
        ChromiumTabCandidate(index: index, title: title, label: label)
    }
}

struct ChromiumTabCandidate: Hashable, Sendable {
    let index: Int?
    let title: String
    let label: String

    var detail: String {
        title.isEmpty ? label : title
    }
}

func findAudibleTab(in root: AXUIElement, verbose: Bool) -> AXAudibleTab? {
    findAudibleTabs(in: root, verbose: verbose).first
}

func tabTitle(from text: String) -> String {
    let parts = text
        .split(separator: "|")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let candidate = parts.first ?? text
    let noiseSuffixes = [
        " - Audio playing",
        " - Playing audio",
        " - Mute tab",
        " - Mute site"
    ]
    return noiseSuffixes.reduce(candidate) { title, suffix in
        title.replacingOccurrences(of: suffix, with: "", options: [.caseInsensitive])
    }.trimmingCharacters(in: .whitespacesAndNewlines)
}

func tabIndex(_ element: AXUIElement) -> Int? {
    if let number = axAttribute(element, kAXValueAttribute as CFString) as? NSNumber {
        return number.intValue
    }
    if let value = axString(element, kAXValueAttribute as CFString), let number = Int(value) {
        return number
    }
    return nil
}

func findAudibleTabs(in root: AXUIElement, verbose: Bool) -> [AXAudibleTab] {
    var stack: [(element: AXUIElement, path: [AXUIElement])] = [(root, [root])]
    var seen = Set<Int>()
    var seenTabs = Set<Int>()
    var matches: [AXAudibleTab] = []
    var visited = 0
    let maxVisited = 4_000

    while let current = stack.popLast(), visited < maxVisited {
        let currentID = Int(CFHash(current.element))
        guard seen.insert(currentID).inserted else {
            continue
        }
        visited += 1

        let text = axCombinedText(current.element)
        if isAudibleIndicatorText(text) {
            let tab = current.path.reversed().first(where: isTabLikeAXElement)
            if let tab {
                let tabText = axCombinedText(tab)
                let label = tabText.isEmpty ? text : tabText
                let tabID = Int(CFHash(tab))
                if seenTabs.insert(tabID).inserted {
                    matches.append(AXAudibleTab(
                        element: tab,
                        window: root,
                        label: label,
                        title: tabTitle(from: label),
                        index: tabIndex(tab)
                    ))
                }
            } else if isTabLikeAXElement(current.element) {
                let tabID = Int(CFHash(current.element))
                if seenTabs.insert(tabID).inserted {
                    matches.append(AXAudibleTab(
                        element: current.element,
                        window: root,
                        label: text,
                        title: tabTitle(from: text),
                        index: tabIndex(current.element)
                    ))
                }
            } else if verbose {
                print("Found an audio indicator but could not map it to a tab: \(text)")
            }
        }

        let children = axChildren(current.element)
        for child in children.reversed() {
            stack.append((child, current.path + [child]))
        }
    }

    if verbose, visited >= maxVisited {
        print("Stopped Accessibility scan after \(maxVisited) elements.")
    }
    return matches
}

func isFrontmost(_ app: NSRunningApplication) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
}

func waitUntilFrontmost(_ app: NSRunningApplication, timeout: TimeInterval = 1.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if isFrontmost(app) {
            return true
        }
        usleep(50_000)
    }
    return isFrontmost(app)
}

func activateAndConfirmFrontmost(_ app: NSRunningApplication, timeout: TimeInterval = 1.0) -> Bool {
    app.activate()
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    _ = AXUIElementSetAttributeValue(
        appElement,
        kAXFrontmostAttribute as CFString,
        kCFBooleanTrue
    )
    return waitUntilFrontmost(app, timeout: timeout)
}

func waitUntilFocusedWindow(
    _ window: AXUIElement,
    in app: NSRunningApplication,
    timeout: TimeInterval = 0.8
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let focused = focusedWindow(for: app), CFEqual(focused, window) {
            return true
        }
        usleep(50_000)
    }
    guard let focused = focusedWindow(for: app) else {
        return false
    }
    return CFEqual(focused, window)
}

func sendCommandW(to app: NSRunningApplication, expectedWindow: AXUIElement? = nil) -> Bool {
    guard activateAndConfirmFrontmost(app) else {
        fputs("Could not confirm target app is frontmost; leaving current window untouched.\n", stderr)
        return false
    }
    if let expectedWindow, !waitUntilFocusedWindow(expectedWindow, in: app, timeout: 0.2) {
        fputs("Could not confirm target browser window is focused; leaving current window untouched.\n", stderr)
        return false
    }

    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 13, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 13, keyDown: false) else {
        return false
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
}

func closeActiveChromiumTab(
    appName: String,
    app: NSRunningApplication,
    window: AXUIElement,
    label: String
) -> Bool {
    if sendCommandW(to: app, expectedWindow: window) {
        print("Closed \(appName) tab via Accessibility: \(label)")
        return true
    }

    fputs("Failed to send Command-W to \(appName) after selecting tab.\n", stderr)
    return false
}

func closeChromiumAudibleTabWithAccessibility(
    appName: String,
    app: NSRunningApplication,
    dryRun: Bool,
    verbose: Bool
) -> Bool {
    guard accessibilityTrusted() else {
        if verbose {
            print("\(appName) Accessibility probe is unavailable.")
            print("Run `stfu --request-accessibility`, grant access in System Settings, then retry.")
        }
        return false
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let windows = axWindows(appElement)
    if windows.isEmpty {
        if verbose {
            print("\(appName) did not expose any Accessibility windows.")
        }
        return false
    }

    for window in windows {
        guard let candidate = findAudibleTab(in: window, verbose: verbose) else {
            continue
        }

        if dryRun {
            print("Would close \(appName) tab via Accessibility: \(candidate.label)")
            return true
        }

        let raiseError = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard raiseError == .success else {
            if verbose {
                print("Raising \(appName) window returned Accessibility error \(raiseError.rawValue).")
            }
            fputs("Could not confirm the intended \(appName) window; leaving browser untouched.\n", stderr)
            return false
        }
        let pressError = AXUIElementPerformAction(candidate.element, kAXPressAction as CFString)
        if pressError != .success {
            if verbose {
                print("Selecting \(appName) tab returned Accessibility error \(pressError.rawValue).")
            }
            fputs("Could not confirm the intended \(appName) tab selection; leaving browser untouched.\n", stderr)
            return false
        }
        usleep(200_000)
        guard waitUntilFocusedWindow(window, in: app) else {
            fputs("Could not confirm the intended \(appName) window is focused; leaving browser untouched.\n", stderr)
            return false
        }
        return closeActiveChromiumTab(appName: appName, app: app, window: window, label: candidate.label)
    }

    return false
}

func focusChromiumTab(app: NSRunningApplication, window: AXUIElement, tab: AXUIElement) -> Bool {
    guard activateAndConfirmFrontmost(app) else {
        return false
    }
    guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
        return false
    }
    guard AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success else {
        return false
    }
    usleep(100_000)
    return waitUntilFrontmost(app, timeout: 0.5)
        && waitUntilFocusedWindow(window, in: app)
}

func audibleChromiumTabs(app: NSRunningApplication, verbose: Bool = false) -> [AXAudibleTab] {
    guard accessibilityTrusted() else {
        return []
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    return axWindows(appElement).flatMap { findAudibleTabs(in: $0, verbose: verbose) }
}

func runningBrowserApplication(_ snapshot: BrowserAppSnapshot) -> NSRunningApplication? {
    if let app = NSRunningApplication(processIdentifier: snapshot.pid),
       app.bundleIdentifier == snapshot.bundleID {
        return app
    }
    return runningApplication(bundleID: snapshot.bundleID)
}

func runningChromiumApplication(_ snapshot: ChromiumTabSnapshot) -> NSRunningApplication? {
    if let app = NSRunningApplication(processIdentifier: snapshot.appPID),
       app.bundleIdentifier == snapshot.bundleID {
        return app
    }
    return nil
}

func chromiumTabMatches(_ snapshot: ChromiumTabSnapshot, _ candidate: ChromiumTabCandidate) -> Bool {
    if let expectedIndex = snapshot.tabIndex,
       let candidateIndex = candidate.index,
       expectedIndex != candidateIndex {
        return false
    }

    let expectedDetail = snapshot.title.isEmpty ? snapshot.label : snapshot.title
    return candidate.detail == expectedDetail
        || candidate.label == snapshot.label
        || (!snapshot.title.isEmpty && candidate.title == snapshot.title)
}

func chromiumTabMatches(_ snapshot: ChromiumTabSnapshot, _ tab: AXAudibleTab) -> Bool {
    chromiumTabMatches(snapshot, tab.candidate)
}

func selectChromiumTabCandidate(
    for snapshot: ChromiumTabSnapshot,
    from candidates: [ChromiumTabCandidate]
) -> ChromiumTabCandidate? {
    let matches = candidates.filter { chromiumTabMatches(snapshot, $0) }
    return matches.count == 1 ? matches[0] : nil
}

func resolveChromiumTab(
    _ snapshot: ChromiumTabSnapshot,
    verbose: Bool = false
) -> (app: NSRunningApplication, tab: AXAudibleTab)? {
    guard let app = runningChromiumApplication(snapshot) else {
        if verbose {
            print("\(snapshot.appName) is no longer running.")
        }
        return nil
    }

    let tabs = audibleChromiumTabs(app: app, verbose: verbose)
    let candidates = tabs.map(\.candidate)
    if let candidate = selectChromiumTabCandidate(for: snapshot, from: candidates),
       let tab = tabs.first(where: { $0.candidate == candidate }) {
        return (app, tab)
    }

    if verbose {
        let matches = candidates.filter { chromiumTabMatches(snapshot, $0) }
        print("Could not resolve \(snapshot.appName) tab unambiguously; matches=\(matches.count), audibleTabs=\(tabs.count).")
    }
    return nil
}

func isChromiumRelated(_ process: AudioProcess, appBundleID: String) -> Bool {
    if process.bundleID == appBundleID || process.bundleID?.hasPrefix(appBundleID + ".") == true {
        return true
    }
    return chromiumAncestorApplication(for: process, bundleID: appBundleID) != nil
}

func matchesBundleFilter(_ process: AudioProcess, filter: String) -> Bool {
    if let bundleID = process.bundleID,
       bundleID == filter || bundleID.hasPrefix(filter + ".") {
        return true
    }

    if filter == "com.apple.Safari" {
        return isSafariRelated(process)
    }

    if chromiumApps.contains(where: { $0.bundleID == filter }) {
        return isChromiumRelated(process, appBundleID: filter)
    }

    return false
}

func closeChromiumMediaTab(appName: String, dryRun: Bool, verbose: Bool) -> Bool {
    let probe = """
    (() => {
      const media = Array.from(document.querySelectorAll('audio,video'));
      return media.some((el) => {
        const audible = !el.muted && Number(el.volume || 0) > 0;
        return audible && !el.paused && !el.ended && el.readyState >= 2;
      }) ? 'true' : 'false';
    })();
    """

    let script = """
    tell application \(appleScriptString(appName))
      if (count of windows) is 0 then return "__STFU_NO_WINDOWS__"
      set firstError to ""
      repeat with w in windows
        repeat with t in tabs of w
          try
            set isPlaying to execute t javascript \(appleScriptString(probe))
            if isPlaying is "true" then
              set tabTitle to title of t
              set tabURL to URL of t
              if \(dryRun ? "false" : "true") then close t
              return tabTitle & " (" & tabURL & ")"
            end if
          on error errMsg
            if firstError is "" then set firstError to errMsg
          end try
        end repeat
      end repeat
      if firstError is not "" then return "__STFU_ERROR__" & firstError
    end tell
    return ""
    """

    let result = runAppleScript(script)
    let match = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    if match == "__STFU_NO_WINDOWS__" {
        if verbose {
            print("\(appName) is running, but it did not expose any AppleScript windows.")
        }
        return false
    }
    if match.hasPrefix("__STFU_ERROR__") {
        if verbose {
            let message = String(match.dropFirst("__STFU_ERROR__".count))
            print("\(appName) tab probe failed: \(message)")
            if message.contains("Executing JavaScript through AppleScript is turned off") {
                print("Enable it in \(appName): View > Developer > Allow JavaScript from Apple Events.")
            }
        }
        return false
    }
    if !match.isEmpty {
        print("\(dryRun ? "Would close" : "Closed") \(appName) tab: \(match)")
        return true
    }
    if verbose {
        let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            print("No \(appName) media tab match: \(detail)")
        }
    }
    return false
}

func closeApplication(_ process: AudioProcess, dryRun: Bool, waitForExit: Bool = true) -> Bool {
    if dryRun {
        print("Would close app: \(process.name) [pid \(process.pid)]")
        return true
    }

    guard let current = currentAudioProcess(matching: process) else {
        fputs("\(process.name) [pid \(process.pid)] is no longer the same active audio source; leaving it untouched.\n", stderr)
        return false
    }

    if let app = NSRunningApplication(processIdentifier: current.pid),
       application(app, matches: current) {
        let didTerminate = app.terminate()
        if didTerminate, !waitForExit {
            print("Asked app to quit: \(current.name) [pid \(current.pid)]")
            return true
        }
        if didTerminate, waitForProcessExit(pid: current.pid, timeout: 2.0) {
            print("Closed app: \(current.name) [pid \(current.pid)]")
            return true
        }
        if didTerminate {
            print("Asked app to quit: \(current.name) [pid \(current.pid)]")
            return true
        }
    }

    let result = runCommand("/bin/kill", ["-TERM", "\(current.pid)"])
    if result.status == 0, !waitForExit {
        print("Asked process to terminate: \(current.name) [pid \(current.pid)]")
        return true
    }
    if result.status == 0, waitForProcessExit(pid: current.pid, timeout: 2.0) {
        print("Terminated process: \(current.name) [pid \(current.pid)]")
        return true
    }
    if result.status == 0 {
        fputs("Asked \(current.name) [pid \(current.pid)] to quit, but it is still running.\n", stderr)
        return false
    }

    fputs("Failed to close \(current.name) [pid \(current.pid)]: \(result.error)\n", stderr)
    return false
}

func currentAudioProcess(matching snapshot: AudioProcess) -> AudioProcess? {
    guard let current = (try? outputAudioProcesses())?.first(where: { $0.pid == snapshot.pid }) else {
        return nil
    }
    if let bundleID = snapshot.bundleID {
        return current.bundleID == bundleID ? current : nil
    }
    return current.name == snapshot.name ? current : nil
}

func application(_ app: NSRunningApplication, matches process: AudioProcess) -> Bool {
    if let bundleID = process.bundleID {
        return app.bundleIdentifier == bundleID
    }
    return (app.localizedName ?? app.bundleIdentifier ?? "pid \(process.pid)") == process.name
}

func processExists(pid: pid_t) -> Bool {
    errno = 0
    if Darwin.kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

func waitForProcessExit(pid: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !processExists(pid: pid) {
            return true
        }
        usleep(100_000)
    }
    return !processExists(pid: pid)
}

func handleProcess(_ process: AudioProcess, options: Options) -> Bool {
    if runningApplication(bundleID: "com.apple.Safari") != nil, isSafariRelated(process) {
        if closeSafariTab(pid: process.pid, dryRun: options.dryRun) {
            return true
        }
        fputs("Could not identify an audible Safari tab; leaving Safari untouched.\n", stderr)
        return false
    }

    for app in chromiumApps where runningApplication(bundleID: app.bundleID) != nil {
        if isChromiumRelated(process, appBundleID: app.bundleID) {
            let runningApp = runningChromiumApplication(for: process, bundleID: app.bundleID)
            if closeChromiumAudibleTabWithAccessibility(
                appName: app.name,
                app: runningApp ?? runningApplication(bundleID: app.bundleID)!,
                dryRun: options.dryRun,
                verbose: options.verbose
            ) {
                return true
            }
            if closeChromiumMediaTab(appName: app.name, dryRun: options.dryRun, verbose: options.verbose) {
                return true
            }
            fputs("Could not identify an audible tab in \(app.name); leaving browser process untouched.\n", stderr)
            return false
        }
    }

    return closeApplication(process, dryRun: options.dryRun)
}

func doctorChromiumApp(_ app: (name: String, bundleID: String)) {
    guard let running = runningApplication(bundleID: app.bundleID) else {
        print("[skip] \(app.name): not running")
        return
    }

    if accessibilityTrusted() {
        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        let windowCount = axWindows(appElement).count
        if windowCount == 0 {
            print("[fail] \(app.name): Accessibility is allowed, but no windows are exposed")
        } else {
            print("[ok] \(app.name): Accessibility can inspect \(windowCount) window\(windowCount == 1 ? "" : "s")")
        }
    } else {
        print("[fail] \(app.name): Accessibility permission is not granted")
        print("       Run: stfu --request-accessibility")
    }

    let windowCountScript = """
    tell application \(appleScriptString(app.name))
      return count of windows
    end tell
    """
    let windowResult = runAppleScript(windowCountScript)
    if isAutomationDenied(windowResult) {
        print("[fail] \(app.name): Automation permission is not granted")
        print("       Open System Settings > Privacy & Security > Automation, then enable \(app.name) under STFU.")
        return
    }

    let windowCount = Int(windowResult.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    if windowCount == 0 {
        print("[warn] \(app.name): no AppleScript windows are exposed for tab close fallback")
        return
    }
    print("[ok] \(app.name): AppleScript can close tabs in \(windowCount) window\(windowCount == 1 ? "" : "s")")

    let jsScript = """
    tell application \(appleScriptString(app.name))
      return execute active tab of front window javascript "1 + 1"
    end tell
    """
    let jsResult = runAppleScript(jsScript)
    if isAutomationDenied(jsResult) {
        print("[fail] \(app.name): Automation permission is not granted")
        print("       Open System Settings > Privacy & Security > Automation, then enable \(app.name) under STFU.")
        return
    }

    if jsResult.status == 0 {
        print("[ok] \(app.name): JavaScript tab probe fallback is allowed")
        return
    }

    let detail = jsResult.error.trimmingCharacters(in: .whitespacesAndNewlines)
    if detail.contains("Executing JavaScript through AppleScript is turned off") {
        print("[skip] \(app.name): JavaScript tab probe fallback is disabled")
    } else {
        print("[skip] \(app.name): JavaScript tab probe fallback failed")
        if !detail.isEmpty {
            print("       \(detail)")
        }
    }
}

func runDoctor() {
    do {
        _ = try outputAudioProcesses()
        print("[ok] CoreAudio process detection works")
    } catch {
        print("[fail] CoreAudio process detection failed: \(error)")
    }

    if accessibilityTrusted() {
        print("[ok] Accessibility permission is granted")
    } else {
        print("[fail] Accessibility permission is not granted")
        print("       Run: stfu --request-accessibility")
    }

    if runningApplication(bundleID: "com.apple.Safari") != nil {
        let script = """
        tell application "Safari"
          return count of windows
        end tell
        """
        let result = runAppleScript(script)
        if isAutomationDenied(result) {
            print("[fail] Safari: Automation permission is not granted")
            print("       Open System Settings > Privacy & Security > Automation, then enable Safari under STFU.")
        } else if result.status == 0 {
            print("[ok] Safari is running; Safari tab matching uses WebContent PIDs")
        } else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[warn] Safari: Automation check failed")
            if !detail.isEmpty {
                print("       \(detail)")
            }
        }
    } else {
        print("[skip] Safari: not running")
    }

    for app in chromiumApps {
        doctorChromiumApp(app)
    }
}

func stfuYellow() -> NSColor {
    NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.18, alpha: 1)
}

func stfuRed() -> NSColor {
    NSColor(calibratedRed: 0.95, green: 0.22, blue: 0.24, alpha: 1)
}

func stfuBlack() -> NSColor {
    NSColor(calibratedRed: 0.055, green: 0.052, blue: 0.049, alpha: 1)
}

func stfuCanvas() -> NSColor {
    NSColor(calibratedRed: 0.075, green: 0.072, blue: 0.068, alpha: 1)
}

func stfuPanel() -> NSColor {
    NSColor(calibratedRed: 0.115, green: 0.108, blue: 0.102, alpha: 1)
}

func stfuRow() -> NSColor {
    NSColor(calibratedRed: 0.145, green: 0.137, blue: 0.128, alpha: 1)
}

func stfuRowSelected() -> NSColor {
    NSColor(calibratedRed: 0.28, green: 0.21, blue: 0.11, alpha: 1)
}

func stfuBorder() -> NSColor {
    NSColor(calibratedWhite: 1, alpha: 0.10)
}

func stfuPrimaryText() -> NSColor {
    NSColor(calibratedWhite: 0.92, alpha: 1)
}

func stfuSecondaryText() -> NSColor {
    NSColor(calibratedWhite: 0.70, alpha: 1)
}

@MainActor
final class STFUPulpHeroView: NSView {
    private let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "pulpfiction_new", withExtension: "webp") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    override func draw(_ dirtyRect: NSRect) {
        stfuBlack().setFill()
        bounds.fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        if let image {
            let imageSize = image.size
            if imageSize.width > 0, imageSize.height > 0 {
                let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
                let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let drawRect = NSRect(
                    x: bounds.midX - drawSize.width / 2,
                    y: bounds.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )

                image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)

                NSColor(calibratedWhite: 0, alpha: 0.22).setFill()
                bounds.fill()
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left

        let fontSize = min(bounds.height * 0.48, bounds.width * 0.18)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .black),
            .foregroundColor: NSColor.white.withAlphaComponent(0.84),
            .strokeColor: NSColor.black.withAlphaComponent(0.24),
            .strokeWidth: -2,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: "STFU", attributes: attributes)
        let textHeight = text.size().height
        text.draw(in: NSRect(
            x: 48,
            y: bounds.midY - textHeight / 2,
            width: bounds.width - 96,
            height: textHeight * 1.25
        ))
    }
}

@MainActor
final class STFUOffenderRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        stfuRow().setFill()
        path.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        stfuRowSelected().setFill()
        path.fill()
        stfuYellow().withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func drawSeparator(in dirtyRect: NSRect) {}
}

struct BrowserAppSnapshot: Hashable, Sendable {
    let name: String
    let bundleID: String
    let pid: pid_t
}

struct ChromiumTabSnapshot: Hashable, Sendable {
    let appName: String
    let bundleID: String
    let appPID: pid_t
    let tabIndex: Int?
    let title: String
    let label: String
}

enum OffenderKind: Sendable {
    case safariTab(pid_t)
    case chromiumTab(ChromiumTabSnapshot)
    case unresolvedBrowser(BrowserAppSnapshot)
    case app(AudioProcess)
    case blockedBrowser(appName: String, bundleID: String)
    case blockedAutomation(BrowserAppSnapshot)
}

final class SoundOffender: Sendable {
    let name: String
    let detail: String
    let kind: OffenderKind

    init(name: String, detail: String, kind: OffenderKind) {
        self.name = name
        self.detail = detail
        self.kind = kind
    }
}

typealias ScanResult = Result<[SoundOffender], Error>

func soundOffenders() throws -> [SoundOffender] {
    let processes = try outputAudioProcesses()
    var offenders: [SoundOffender] = []
    var handledBrowserApps = Set<pid_t>()
    var addedSafariFallback = false

    for process in processes {
        if let safariApp = runningApplication(bundleID: "com.apple.Safari"), isSafariRelated(process) {
            switch safariTabLookup(pid: process.pid) {
            case let .found(safari):
                offenders.append(SoundOffender(
                    name: "Safari tab",
                    detail: "\(safari.title)\(safari.url.isEmpty ? "" : " - \(safari.url)")",
                    kind: .safariTab(process.pid)
                ))
            case .automationDenied:
                if !addedSafariFallback {
                    addedSafariFallback = true
                    offenders.append(SoundOffender(
                        name: "Safari",
                        detail: "Needs Automation permission to identify noisy Safari tabs.",
                        kind: .blockedAutomation(BrowserAppSnapshot(
                            name: "Safari",
                            bundleID: "com.apple.Safari",
                            pid: safariApp.processIdentifier
                        ))
                    ))
                }
            case .notFound:
                if !addedSafariFallback {
                    addedSafariFallback = true
                    offenders.append(SoundOffender(
                        name: "Safari",
                        detail: "Audio detected, but no matching Safari tab was found. Bring Safari forward, then refresh.",
                        kind: .unresolvedBrowser(BrowserAppSnapshot(
                            name: "Safari",
                            bundleID: "com.apple.Safari",
                            pid: safariApp.processIdentifier
                        ))
                    ))
                }
            }
            continue
        }

        var matchedChromium = false
        for chromium in chromiumApps where isChromiumRelated(process, appBundleID: chromium.bundleID) {
            matchedChromium = true
            guard let app = runningChromiumApplication(for: process, bundleID: chromium.bundleID) else {
                continue
            }
            guard handledBrowserApps.insert(app.processIdentifier).inserted else {
                continue
            }

            if accessibilityTrusted() {
                let tabs = audibleChromiumTabs(app: app)
                if tabs.isEmpty {
                    offenders.append(SoundOffender(
                        name: chromium.name,
                        detail: "No noisy tab badge was visible. Bring the tab forward, keep the tab strip visible, then refresh.",
                        kind: .unresolvedBrowser(BrowserAppSnapshot(
                            name: chromium.name,
                            bundleID: chromium.bundleID,
                            pid: app.processIdentifier
                        ))
                    ))
                } else {
                    for tab in tabs {
                        let detail = tab.title.isEmpty ? tab.label : tab.title
                        let tabNumber = tab.index.map { "Tab \($0)" } ?? "Tab"
                        offenders.append(SoundOffender(
                            name: "\(chromium.name) \(tabNumber)",
                            detail: detail,
                            kind: .chromiumTab(ChromiumTabSnapshot(
                                appName: chromium.name,
                                bundleID: chromium.bundleID,
                                appPID: app.processIdentifier,
                                tabIndex: tab.index,
                                title: tab.title,
                                label: tab.label
                            ))
                        ))
                    }
                }
            } else {
                offenders.append(SoundOffender(
                    name: chromium.name,
                    detail: "Needs Accessibility to identify noisy browser tabs.",
                    kind: .blockedBrowser(appName: chromium.name, bundleID: chromium.bundleID)
                ))
            }
        }

        if matchedChromium {
            continue
        }

        offenders.append(SoundOffender(
            name: process.name,
            detail: "App audio source",
            kind: .app(process)
        ))
    }

    return offenders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

@discardableResult
func focusOffender(_ offender: SoundOffender) -> Bool {
    switch offender.kind {
    case let .safariTab(pid):
        return focusSafariTab(pid: pid)
    case let .chromiumTab(snapshot):
        guard let resolved = resolveChromiumTab(snapshot) else {
            return false
        }
        return focusChromiumTab(app: resolved.app, window: resolved.tab.window, tab: resolved.tab.element)
    case let .unresolvedBrowser(snapshot):
        guard let app = runningBrowserApplication(snapshot) else {
            return false
        }
        app.activate()
        return true
    case let .app(process):
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            app.activate()
            return true
        }
        return false
    case .blockedBrowser:
        openAccessibilitySettings()
        return true
    case .blockedAutomation:
        openAutomationSettings()
        return true
    }
}

@discardableResult
func closeOffender(_ offender: SoundOffender, waitForAppExit: Bool = true) -> Bool {
    switch offender.kind {
    case let .safariTab(pid):
        return closeSafariTab(pid: pid, dryRun: false)
    case let .chromiumTab(snapshot):
        guard let resolved = resolveChromiumTab(snapshot, verbose: true),
              focusChromiumTab(app: resolved.app, window: resolved.tab.window, tab: resolved.tab.element) else {
            fputs("Could not confirm the intended \(snapshot.appName) tab selection; leaving browser untouched.\n", stderr)
            return false
        }
        usleep(150_000)
        return closeActiveChromiumTab(
            appName: snapshot.appName,
            app: resolved.app,
            window: resolved.tab.window,
            label: offender.detail
        )
    case .unresolvedBrowser:
        return false
    case let .app(process):
        return closeApplication(process, dryRun: false, waitForExit: waitForAppExit)
    case .blockedBrowser:
        openAccessibilitySettings()
        return false
    case .blockedAutomation:
        openAutomationSettings()
        return false
    }
}

func offenderCloseKey(for offender: SoundOffender) -> String {
    switch offender.kind {
    case let .safariTab(pid):
        return "safari:\(pid)"
    case let .chromiumTab(snapshot):
        let detail = snapshot.title.isEmpty ? snapshot.label : snapshot.title
        return "chromium:\(snapshot.bundleID):\(snapshot.appPID):\(detail)"
    case let .unresolvedBrowser(snapshot):
        return "unresolved:\(snapshot.bundleID):\(snapshot.pid)"
    case let .app(process):
        return "app:\(process.pid)"
    case let .blockedBrowser(_, bundleID):
        return "accessibility:\(bundleID)"
    case let .blockedAutomation(snapshot):
        return "automation:\(snapshot.bundleID):\(snapshot.pid)"
    }
}

func offenderCloseKeyCounts(for offenders: [SoundOffender]) -> [String: Int] {
    offenders.reduce(into: [:]) { counts, offender in
        counts[offenderCloseKey(for: offender), default: 0] += 1
    }
}

func isOffenderClosable(_ offender: SoundOffender) -> Bool {
    switch offender.kind {
    case .safariTab, .chromiumTab, .app:
        return true
    case .unresolvedBrowser, .blockedBrowser, .blockedAutomation:
        return false
    }
}

@MainActor
final class SetupAppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private let statusLabel = NSTextField(labelWithString: "Scanning sound sources...")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let listBackgroundView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No active sound sources.")
    private lazy var closeAllButton: NSButton = {
        let button = NSButton(title: "STFU Everything", target: self, action: #selector(closeAll))
        button.bezelStyle = .rounded
        button.contentTintColor = stfuRed()
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private var offenders: [SoundOffender] = []
    private var scanError: Error?
    private var scanGeneration = 0
    private var menuBarController: STFUMenuBarController?
    private var showWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        NSApp.setActivationPolicy(.regular)
        if menuBarController == nil {
            menuBarController = STFUMenuBarController()
        }
        if showWindowObserver == nil {
            showWindowObserver = NotificationCenter.default.addObserver(
                forName: .stfuShowMainWindow,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.showMainWindow(activate: true)
                }
            }
        }
        showMainWindow(activate: true)
    }

    private func showMainWindow(activate: Bool) {
        if activate {
            NSApp.activate()
        }
        if window == nil {
            buildWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(activate: true)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else {
            start()
            return
        }
        refreshStatus()
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "STFU"
        window.minSize = NSSize(width: 860, height: 620)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = stfuCanvas()
        window.center()

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = stfuCanvas().cgColor
        window.contentView = content

        let heroView = STFUPulpHeroView()
        heroView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        statusLabel.textColor = stfuPrimaryText()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 13, weight: .regular)
        hintLabel.textColor = stfuSecondaryText()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        configureTable()

        emptyLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        emptyLabel.textColor = stfuSecondaryText()
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshAction))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .large
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [refreshButton, closeAllButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .gravityAreas
        buttons.translatesAutoresizingMaskIntoConstraints = false

        listBackgroundView.wantsLayer = true
        listBackgroundView.layer?.backgroundColor = stfuPanel().cgColor
        listBackgroundView.layer?.cornerRadius = 12
        listBackgroundView.layer?.borderWidth = 1
        listBackgroundView.layer?.borderColor = stfuBorder().cgColor
        listBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        listBackgroundView.addSubview(scrollView)

        for view in [heroView, statusLabel, hintLabel, listBackgroundView, emptyLabel, buttons] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            heroView.topAnchor.constraint(equalTo: content.topAnchor),
            heroView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            heroView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            heroView.heightAnchor.constraint(equalToConstant: 220),

            statusLabel.topAnchor.constraint(equalTo: heroView.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),

            hintLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 5),
            hintLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

            listBackgroundView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 14),
            listBackgroundView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            listBackgroundView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            listBackgroundView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: listBackgroundView.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: listBackgroundView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: listBackgroundView.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: listBackgroundView.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: listBackgroundView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listBackgroundView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: listBackgroundView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: listBackgroundView.trailingAnchor, constant: -20),

            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -30),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.target = self
        tableView.doubleAction = #selector(focusSelected)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.style = .plain

        let offenderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("offender"))
        offenderColumn.title = "Source"
        offenderColumn.width = 210
        tableView.addTableColumn(offenderColumn)

        let detailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        detailColumn.title = "Detected audio"
        detailColumn.width = 370
        tableView.addTableColumn(detailColumn)

        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = "Action"
        actionColumn.width = 260
        tableView.addTableColumn(actionColumn)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func refreshStatus() {
        scanGeneration += 1
        let generation = scanGeneration
        statusLabel.stringValue = offenders.isEmpty ? "Scanning sound sources..." : "Refreshing sound sources..."
        statusLabel.textColor = stfuPrimaryText()
        hintLabel.stringValue = ""

        Task.detached(priority: .userInitiated) {
            let result: ScanResult
            do {
                result = .success(try soundOffenders())
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                self.applyScanResult(result, generation: generation)
            }
        }
    }

    private func applyScanResult(_ result: ScanResult, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        switch result {
        case let .success(found):
            offenders = found
            scanError = nil
        case let .failure(error):
            offenders = []
            scanError = error
        }

        tableView.reloadData()
        emptyLabel.isHidden = !offenders.isEmpty
        closeAllButton.isHidden = offenders.filter(isClosable).count < 2

        if let scanError {
            statusLabel.stringValue = "Could not read audio sources."
            statusLabel.textColor = stfuRed()
            hintLabel.textColor = stfuSecondaryText()
            hintLabel.stringValue = "\(scanError)"
            return
        }

        if offenders.isEmpty {
            statusLabel.stringValue = "No active sound sources."
            statusLabel.textColor = stfuPrimaryText()
            hintLabel.textColor = stfuSecondaryText()
            hintLabel.stringValue = ""
            return
        }

        let needsAccessibility = offenders.contains { offender in
            if case .blockedBrowser = offender.kind {
                return true
            }
            return false
        }
        let needsAutomation = offenders.contains { offender in
            if case .blockedAutomation = offender.kind {
                return true
            }
            return false
        }

        statusLabel.stringValue = "\(offenders.count) sound source\(offenders.count == 1 ? "" : "s")"
        statusLabel.textColor = stfuPrimaryText()
        hintLabel.textColor = stfuSecondaryText()
        if needsAccessibility {
            hintLabel.stringValue = "Enable STFU in Accessibility settings, then refresh. If it already looks enabled, toggle it off and on once."
        } else if needsAutomation {
            hintLabel.stringValue = "In Automation settings, enable the affected browser under STFU, then refresh."
        } else {
            hintLabel.stringValue = ""
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        offenders.count
    }

    private func isBlockedBrowser(_ offender: SoundOffender) -> Bool {
        if case .blockedBrowser = offender.kind {
            return true
        }
        if case .blockedAutomation = offender.kind {
            return true
        }
        return false
    }

    private func isClosable(_ offender: SoundOffender) -> Bool {
        isOffenderClosable(offender)
    }

    private func focusTitle(for offender: SoundOffender) -> String? {
        switch offender.kind {
        case .safariTab, .chromiumTab:
            return "Go to Tab"
        case .unresolvedBrowser, .app:
            return "Go to App"
        case .blockedBrowser, .blockedAutomation:
            return nil
        }
    }

    private func closeTitle(for offender: SoundOffender) -> String? {
        switch offender.kind {
        case .safariTab, .chromiumTab:
            return "Close Tab"
        case .app:
            return "Quit App"
        case .unresolvedBrowser:
            return nil
        case .blockedBrowser, .blockedAutomation:
            return "Open Settings"
        }
    }

    private func rowButton(title: String, color: NSColor?, row: Int, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if let color {
            button.contentTintColor = color
        }
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.tag = row
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        return button
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < offenders.count, let identifier = tableColumn?.identifier else {
            return nil
        }
        let offender = offenders[row]

        if identifier.rawValue == "action" {
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.distribution = .fill
            stack.translatesAutoresizingMaskIntoConstraints = false

            if let title = focusTitle(for: offender) {
                stack.addArrangedSubview(rowButton(
                    title: title,
                    color: nil,
                    row: row,
                    action: #selector(focusRowButton(_:))
                ))
            }

            if let title = closeTitle(for: offender) {
                stack.addArrangedSubview(rowButton(
                    title: title,
                    color: isBlockedBrowser(offender) ? stfuYellow() : stfuRed(),
                    row: row,
                    action: #selector(closeRowButton(_:))
                ))
            }

            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12)
            ])
            return container
        }

        let text: String
        let font: NSFont
        let color: NSColor
        if identifier.rawValue == "offender" {
            text = offender.name
            font = .systemFont(ofSize: 15, weight: .semibold)
            color = stfuYellow()
        } else {
            text = offender.detail
            font = .systemFont(ofSize: 13, weight: .regular)
            color = stfuSecondaryText()
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        STFUOffenderRowView()
    }

    private func selectedOffender() -> SoundOffender? {
        let row = tableView.selectedRow
        guard row >= 0, row < offenders.count else {
            return nil
        }
        return offenders[row]
    }

    @objc private func refreshAction() {
        refreshStatus()
    }

    @objc private func focusSelected() {
        guard let offender = selectedOffender() else {
            NSSound.beep()
            return
        }
        performFocus(offender)
    }

    @objc private func focusRowButton(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < offenders.count else {
            return
        }
        performFocus(offenders[sender.tag])
    }

    private func performFocus(_ offender: SoundOffender) {
        switch offender.kind {
        case .blockedBrowser, .blockedAutomation:
            _ = focusOffender(offender)
        default:
            Task.detached(priority: .userInitiated) {
                _ = focusOffender(offender)
            }
        }
    }

    @objc private func closeRowButton(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < offenders.count else {
            return
        }
        closeOffenderFromUI(offenders[sender.tag])
    }

    private func closeOffenderFromUI(_ offender: SoundOffender) {
        switch offender.kind {
        case .app:
            confirmQuitApp(offender) { confirmed in
                guard confirmed else { return }
                Task { @MainActor in
                    self.performClose(offender)
                }
            }
            return
        case .blockedBrowser, .blockedAutomation:
            _ = closeOffender(offender, waitForAppExit: false)
            return
        case .safariTab, .chromiumTab, .unresolvedBrowser:
            break
        }

        performClose(offender)
    }

    private func performClose(_ offender: SoundOffender) {
        Task.detached(priority: .userInitiated) {
            _ = closeOffender(offender, waitForAppExit: false)
            await MainActor.run {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.refreshStatus()
                }
            }
        }
    }

    @objc private func closeAll() {
        let targets = offenders.filter(isClosable)
        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }

        confirmCloseAll(targets) { confirmed in
            guard confirmed else { return }
            Task { @MainActor in
                self.closeAllButton.isEnabled = false
                self.closeNextOffender(
                    remainingKeys: self.closeKeyCounts(for: targets)
                )
            }
        }
    }

    private func closeNextOffender(remainingKeys: [String: Int]) {
        Task.detached(priority: .userInitiated) {
            let current = (try? soundOffenders()) ?? []
            let currentTargets = current.filter { offender in
                isOffenderClosable(offender) && (remainingKeys[offenderCloseKey(for: offender)] ?? 0) > 0
            }

            guard let offender = currentTargets.first else {
                await MainActor.run {
                    self.closeAllButton.isEnabled = true
                    self.refreshStatus()
                }
                return
            }

            let key = offenderCloseKey(for: offender)
            var nextRemainingKeys = remainingKeys
            guard closeOffender(offender, waitForAppExit: false) else {
                await MainActor.run {
                    self.closeAllButton.isEnabled = true
                    self.refreshStatus()
                }
                return
            }

            let remaining = (nextRemainingKeys[key] ?? 1) - 1
            if remaining > 0 {
                nextRemainingKeys[key] = remaining
            } else {
                nextRemainingKeys.removeValue(forKey: key)
            }

            await MainActor.run {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.closeNextOffender(remainingKeys: nextRemainingKeys)
                }
            }
        }
    }

    private func closeKeyCounts(for offenders: [SoundOffender]) -> [String: Int] {
        offenderCloseKeyCounts(for: offenders)
    }

    private func confirmQuitApp(_ offender: SoundOffender, completion: @escaping (Bool) -> Void) {
        guard let window else {
            completion(false)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Quit \(offender.name)?"
        alert.informativeText = "STFU will ask this app to quit, and may terminate its audio process if it does not respond. Unsaved work in that app could be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit App")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    private func confirmCloseAll(_ targets: [SoundOffender], completion: @escaping (Bool) -> Void) {
        guard let window else {
            completion(false)
            return
        }

        let visibleNames = targets.prefix(5).map(\.name).joined(separator: ", ")
        let suffix = targets.count > 5 ? ", and \(targets.count - 5) more" : ""

        let alert = NSAlert()
        alert.messageText = "STFU everything?"
        alert.informativeText = "This will close browser tabs and quit apps currently producing sound. App quits may terminate audio processes and unsaved work could be lost: \(visibleNames)\(suffix)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "STFU Everything")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

}

func shouldRunSetupApp() -> Bool {
    CommandLine.arguments.count == 1
        && Bundle.main.bundleURL.pathExtension == "app"
        && isatty(STDOUT_FILENO) == 0
}

@MainActor private var setupAppDelegate: SetupAppDelegate?

@MainActor
func runSetupApp() {
    let app = NSApplication.shared
    setupAppDelegate = SetupAppDelegate()
    app.delegate = setupAppDelegate
    setupAppDelegate?.start()
    app.run()
}

@MainActor
public func runSTFU() {
    if shouldRunSetupApp() {
        runSetupApp()
        exit(0)
    }

    guard let options = parseOptions(Array(CommandLine.arguments.dropFirst())) else {
        exit(2)
    }

    if options.doctor {
        runDoctor()
        exit(0)
    }

    if options.requestAccessibility {
        requestAccessibilityAccess()
        exit(accessibilityTrusted() ? 0 : 1)
    }

    do {
        var processes = try outputAudioProcesses()
        if let bundleID = options.bundleID {
            processes = processes.filter { matchesBundleFilter($0, filter: bundleID) }
        }

        if processes.isEmpty {
            if let bundleID = options.bundleID {
                print("No output audio processes found for \(bundleID).")
            } else {
                print("No output audio processes found.")
            }
            exit(1)
        }

        if options.list {
            for process in processes {
                print("[pid \(process.pid)] \(process.name) \(process.bundleID ?? "(no bundle id)")")
            }
            if !options.dryRun && !options.all {
                exit(0)
            }
        }

        var closedCount = 0
        for process in processes {
            if handleProcess(process, options: options) {
                closedCount += 1
                if !options.all {
                    break
                }
            }
        }

        exit(closedCount == 0 ? 1 : 0)
    } catch {
        fputs("stfu: \(error)\n", stderr)
        exit(1)
    }
}
