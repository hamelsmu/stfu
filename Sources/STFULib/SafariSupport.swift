import AppKit
import Foundation

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

struct SafariTabInfo {
    let title: String
    let url: String
}

func safariTabInfo(pid: pid_t) -> SafariTabInfo? {
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
    let lines = result.output
        .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .map(String.init)
    guard let title = lines.first, !title.isEmpty else {
        return nil
    }
    return SafariTabInfo(title: title, url: lines.dropFirst().first ?? "")
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
