import AppKit
import Foundation

func shouldRunSetupApp(arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.count == 1
        && Bundle.main.bundleURL.pathExtension == "app"
        && isatty(STDOUT_FILENO) == 0
}

@MainActor
func runSetupApp() {
    let app = NSApplication.shared
    let delegate = SetupAppDelegate()
    app.delegate = delegate
    app.run()
}

public func runSTFU(arguments: [String] = CommandLine.arguments) -> Never {
    if shouldRunSetupApp(arguments: arguments) {
        MainActor.assumeIsolated {
            runSetupApp()
        }
        exit(0)
    }

    guard let options = parseOptions(Array(arguments.dropFirst())) else {
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
