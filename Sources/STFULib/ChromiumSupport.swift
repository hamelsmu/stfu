import AppKit
import ApplicationServices
import Foundation

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
    let focused = focusedValue as! AXUIElement

    var ordered = [focused]
    for window in windows where !CFEqual(window, focused) {
        ordered.append(window)
    }
    return ordered
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
        || lower.contains("speaker")
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
    return candidate
        .replacingOccurrences(of: " - Audio playing", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
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

func sendCommandW(to app: NSRunningApplication) -> Bool {
    app.activate()
    usleep(200_000)

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

func closeActiveChromiumTab(appName: String, app: NSRunningApplication, label: String) -> Bool {
    if sendCommandW(to: app) {
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

        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let pressError = AXUIElementPerformAction(candidate.element, kAXPressAction as CFString)
        if pressError != .success, verbose {
            print("Selecting \(appName) tab returned Accessibility error \(pressError.rawValue).")
        }
        usleep(200_000)
        return closeActiveChromiumTab(appName: appName, app: app, label: candidate.label)
    }

    return false
}

func focusChromiumTab(app: NSRunningApplication, window: AXUIElement, tab: AXUIElement) -> Bool {
    app.activate()
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    return AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success
}

func audibleChromiumTabs(app: NSRunningApplication, verbose: Bool = false) -> [AXAudibleTab] {
    guard accessibilityTrusted() else {
        return []
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    return axWindows(appElement).flatMap { findAudibleTabs(in: $0, verbose: verbose) }
}

func isChromiumRelated(_ process: AudioProcess, appBundleID: String) -> Bool {
    if process.bundleID == appBundleID || process.bundleID?.hasPrefix(appBundleID + ".") == true {
        return true
    }
    return chromiumAncestorApplication(for: process, bundleID: appBundleID) != nil
}

func matchesBundleFilter(_ process: AudioProcess, filter: String) -> Bool {
    guard let bundleID = process.bundleID else {
        return false
    }
    return bundleID == filter || bundleID.hasPrefix(filter + ".")
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

func closeApplication(_ process: AudioProcess, dryRun: Bool) -> Bool {
    if dryRun {
        print("Would close app: \(process.name) [pid \(process.pid)]")
        return true
    }

    if let app = NSRunningApplication(processIdentifier: process.pid) {
        let didTerminate = app.terminate()
        if didTerminate {
            print("Closed app: \(process.name) [pid \(process.pid)]")
            return true
        }
    }

    let result = runCommand("/bin/kill", ["-TERM", "\(process.pid)"])
    if result.status == 0 {
        print("Terminated process: \(process.name) [pid \(process.pid)]")
        return true
    }

    fputs("Failed to close \(process.name) [pid \(process.pid)]: \(result.error)\n", stderr)
    return false
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
        print("[ok] Safari is running; Safari tab matching uses WebContent PIDs")
    } else {
        print("[skip] Safari: not running")
    }

    for app in chromiumApps {
        doctorChromiumApp(app)
    }
}
