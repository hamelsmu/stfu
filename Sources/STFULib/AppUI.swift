import AppKit
import ApplicationServices
import Foundation

func stfuYellow() -> NSColor {
    NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.12, alpha: 1)
}

func stfuRed() -> NSColor {
    NSColor(calibratedRed: 1.0, green: 0.18, blue: 0.20, alpha: 1)
}

func stfuBlack() -> NSColor {
    NSColor(calibratedWhite: 0.035, alpha: 1)
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

enum OffenderKind: Sendable {
    case safariTab(pid_t)
    case chromiumTab(
        appName: String,
        bundleID: String,
        appPID: pid_t,
        tabIndex: Int?,
        title: String,
        label: String
    )
    case unresolvedBrowser(appName: String, bundleID: String, appPID: pid_t)
    case app(AudioProcess)
    case blockedBrowser(appName: String, bundleID: String)
}

struct SoundOffender: Sendable {
    let name: String
    let detail: String
    let kind: OffenderKind

    init(name: String, detail: String, kind: OffenderKind) {
        self.name = name
        self.detail = detail
        self.kind = kind
    }
}

func soundOffenders() throws -> [SoundOffender] {
    let processes = try outputAudioProcesses()
    var offenders: [SoundOffender] = []
    var handledBrowserApps = Set<pid_t>()

    for process in processes {
        if let safariApp = runningApplication(bundleID: "com.apple.Safari"), isSafariRelated(process) {
            if let safari = safariTabInfo(pid: process.pid) {
                offenders.append(SoundOffender(
                    name: "Safari tab",
                    detail: "\(safari.title)\(safari.url.isEmpty ? "" : " - \(safari.url)")",
                    kind: .safariTab(process.pid)
                ))
            } else {
                offenders.append(SoundOffender(
                    name: "Safari",
                    detail: "Needs browser Automation permission to identify the noisy tab.",
                    kind: .unresolvedBrowser(
                        appName: "Safari",
                        bundleID: "com.apple.Safari",
                        appPID: safariApp.processIdentifier
                    )
                ))
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
                        detail: "Audio detected, but no noisy tab indicator was visible.",
                        kind: .unresolvedBrowser(
                            appName: chromium.name,
                            bundleID: chromium.bundleID,
                            appPID: app.processIdentifier
                        )
                    ))
                } else {
                    for tab in tabs {
                        let tabNumber = tab.index.map { "Tab \($0)" } ?? "Tab"
                        let detail = tab.title.isEmpty ? tab.label : tab.title
                        offenders.append(SoundOffender(
                            name: "\(chromium.name) \(tabNumber)",
                            detail: detail,
                            kind: .chromiumTab(
                                appName: chromium.name,
                                bundleID: chromium.bundleID,
                                appPID: app.processIdentifier,
                                tabIndex: tab.index,
                                title: tab.title,
                                label: tab.label
                            )
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

@MainActor
func browserApplication(bundleID: String, appPID: pid_t) -> NSRunningApplication? {
    if let app = NSRunningApplication(processIdentifier: appPID),
       app.bundleIdentifier == bundleID {
        return app
    }
    return runningApplication(bundleID: bundleID)
}

func matchesChromiumTab(_ tab: AXAudibleTab, offender: SoundOffender) -> Bool {
    guard case let .chromiumTab(_, _, _, tabIndex, title, label) = offender.kind else {
        return false
    }

    let indexMatches = tabIndex == nil || tab.index == tabIndex
    let titleMatches = !title.isEmpty && tab.title == title
    let labelMatches = !label.isEmpty && tab.label == label
    let detailMatches = tab.title == offender.detail || tab.label == offender.detail

    return indexMatches && (titleMatches || labelMatches || detailMatches)
}

@MainActor
func resolveChromiumTab(for offender: SoundOffender) -> (app: NSRunningApplication, tab: AXAudibleTab)? {
    guard case let .chromiumTab(_, bundleID, appPID, _, _, _) = offender.kind,
          let app = browserApplication(bundleID: bundleID, appPID: appPID) else {
        return nil
    }

    let tabs = audibleChromiumTabs(app: app)
    if let exact = tabs.first(where: { matchesChromiumTab($0, offender: offender) }) {
        return (app, exact)
    }
    if tabs.count == 1, let only = tabs.first {
        return (app, only)
    }
    return nil
}

@discardableResult
@MainActor
func focusOffender(_ offender: SoundOffender) -> Bool {
    switch offender.kind {
    case let .safariTab(pid):
        return focusSafariTab(pid: pid)
    case .chromiumTab:
        guard let resolved = resolveChromiumTab(for: offender) else {
            return false
        }
        return focusChromiumTab(app: resolved.app, window: resolved.tab.window, tab: resolved.tab.element)
    case let .unresolvedBrowser(_, bundleID, appPID):
        guard let app = browserApplication(bundleID: bundleID, appPID: appPID) else {
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
    }
}

@discardableResult
@MainActor
func closeOffender(_ offender: SoundOffender) -> Bool {
    switch offender.kind {
    case let .safariTab(pid):
        return closeSafariTab(pid: pid, dryRun: false)
    case let .chromiumTab(appName, _, _, _, _, _):
        guard let resolved = resolveChromiumTab(for: offender),
              focusChromiumTab(app: resolved.app, window: resolved.tab.window, tab: resolved.tab.element) else {
            fputs("Failed to select \(appName) tab; leaving tabs untouched.\n", stderr)
            return false
        }
        usleep(150_000)
        return closeActiveChromiumTab(appName: appName, app: resolved.app, label: offender.detail)
    case .unresolvedBrowser:
        return false
    case let .app(process):
        return closeApplication(process, dryRun: false)
    case .blockedBrowser:
        openAccessibilitySettings()
        return false
    }
}

func isClosableOffender(_ offender: SoundOffender) -> Bool {
    switch offender.kind {
    case .safariTab, .chromiumTab, .app:
        return true
    case .unresolvedBrowser, .blockedBrowser:
        return false
    }
}

func closeKey(for offender: SoundOffender) -> String {
    switch offender.kind {
    case let .safariTab(pid):
        return "safari:\(pid)"
    case let .chromiumTab(appName, bundleID, appPID, tabIndex, _, _):
        return "chromium:\(appName):\(bundleID):\(appPID):\(tabIndex.map(String.init) ?? "-"):\(offender.detail)"
    case let .unresolvedBrowser(appName, bundleID, appPID):
        return "unresolved:\(appName):\(bundleID):\(appPID)"
    case let .app(process):
        return "app:\(process.pid)"
    case let .blockedBrowser(appName, bundleID):
        return "blocked:\(appName):\(bundleID)"
    }
}

@MainActor
final class SetupAppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private let statusLabel = NSTextField(labelWithString: "Scanning sound sources...")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No active sound sources.")
    private lazy var closeAllButton: NSButton = {
        let button = NSButton(title: "STFU Everything", target: self, action: #selector(closeAll))
        button.bezelStyle = .rounded
        button.contentTintColor = stfuRed()
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private var offenders: [SoundOffender] = []
    private var scanError: Error?
    private var refreshGeneration = 0
    private var isClosingAll = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if window == nil {
            buildWindow()
        }
        refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "STFU"
        window.minSize = NSSize(width: 850, height: 520)
        window.center()

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = stfuBlack().cgColor
        window.contentView = content

        let heroView = STFUPulpHeroView()
        heroView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        configureTable()

        emptyLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        emptyLabel.textColor = stfuYellow()
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshAction))
        refreshButton.bezelStyle = .rounded
        refreshButton.contentTintColor = stfuYellow()
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [refreshButton, closeAllButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .gravityAreas
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [heroView, statusLabel, hintLabel, scrollView, emptyLabel, buttons] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            heroView.topAnchor.constraint(equalTo: content.topAnchor),
            heroView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            heroView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            heroView.heightAnchor.constraint(equalToConstant: 260),

            statusLabel.topAnchor.constraint(equalTo: heroView.bottomAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),

            hintLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 5),
            hintLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -18),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),

            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -26),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.target = self
        tableView.doubleAction = #selector(focusSelected)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1)
        tableView.gridColor = NSColor(calibratedWhite: 0.18, alpha: 1)

        let offenderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("offender"))
        offenderColumn.title = "Source"
        offenderColumn.width = 190
        tableView.addTableColumn(offenderColumn)

        let detailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        detailColumn.title = "Detected audio"
        detailColumn.width = 340
        tableView.addTableColumn(detailColumn)

        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = "Action"
        actionColumn.width = 260
        tableView.addTableColumn(actionColumn)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = tableView.backgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func refreshStatus() {
        refreshGeneration += 1
        let generation = refreshGeneration

        statusLabel.stringValue = "Scanning sound sources..."
        statusLabel.textColor = stfuYellow()
        hintLabel.stringValue = ""
        closeAllButton.isEnabled = !isClosingAll

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try soundOffenders() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshGeneration == generation else {
                    return
                }
                self.applyScanResult(result)
            }
        }
    }

    private func applyScanResult(_ result: Result<[SoundOffender], Error>) {
        switch result {
        case let .success(newOffenders):
            offenders = newOffenders
            scanError = nil
        case let .failure(error):
            offenders = []
            scanError = error
        }
        tableView.reloadData()
        emptyLabel.isHidden = !offenders.isEmpty
        closeAllButton.isHidden = offenders.filter(isClosable).count < 2
        closeAllButton.isEnabled = !isClosingAll

        if let scanError {
            statusLabel.stringValue = "Could not read audio sources."
            statusLabel.textColor = stfuRed()
            hintLabel.stringValue = "\(scanError)"
            return
        }

        if offenders.isEmpty {
            statusLabel.stringValue = "No active sound sources."
            statusLabel.textColor = .systemGreen
            hintLabel.stringValue = ""
            return
        }

        let needsAccessibility = offenders.contains { offender in
            if case .blockedBrowser = offender.kind {
                return true
            }
            return false
        }

        statusLabel.stringValue = "\(offenders.count) sound source\(offenders.count == 1 ? "" : "s")"
        statusLabel.textColor = stfuRed()
        if needsAccessibility {
            hintLabel.stringValue = "Enable STFU in Accessibility settings, then refresh. If it already looks enabled, toggle it off and on once."
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
        return false
    }

    private func isClosable(_ offender: SoundOffender) -> Bool {
        isClosableOffender(offender)
    }

    private func focusTitle(for offender: SoundOffender) -> String? {
        switch offender.kind {
        case .safariTab, .chromiumTab:
            return "Go to Tab"
        case .unresolvedBrowser, .app:
            return "Go to App"
        case .blockedBrowser:
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
        case .blockedBrowser:
            return "Open Settings"
        }
    }

    private func rowButton(title: String, color: NSColor, row: Int, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.contentTintColor = color
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
            stack.distribution = .fillEqually
            stack.translatesAutoresizingMaskIntoConstraints = false

            if let title = focusTitle(for: offender) {
                stack.addArrangedSubview(rowButton(
                    title: title,
                    color: stfuYellow(),
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
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 10),
                stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
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
            color = NSColor(calibratedWhite: 0.82, alpha: 1)
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
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
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
        _ = focusOffender(offender)
    }

    @objc private func focusRowButton(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < offenders.count else {
            return
        }
        _ = focusOffender(offenders[sender.tag])
    }

    @objc private func closeRowButton(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < offenders.count else {
            return
        }
        closeOffenderFromUI(offenders[sender.tag])
    }

    private func closeOffenderFromUI(_ offender: SoundOffender) {
        if case .app = offender.kind {
            confirmQuitApp(offender) { confirmed in
                guard confirmed else { return }
                Task { @MainActor in
                    self.performClose(offender)
                }
            }
            return
        }

        performClose(offender)
    }

    private func performClose(_ offender: SoundOffender) {
        _ = closeOffender(offender)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refreshStatus()
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
                self.isClosingAll = true
                self.closeAllButton.isEnabled = false
                self.closeNextOffender(
                    allowedKeys: Set(targets.map { closeKey(for: $0) }),
                    attempted: []
                )
            }
        }
    }

    private func closeNextOffender(allowedKeys: Set<String>, attempted: Set<String>) {
        DispatchQueue.global(qos: .userInitiated).async {
            let current = ((try? soundOffenders()) ?? []).filter { offender in
                isClosableOffender(offender) && allowedKeys.contains(closeKey(for: offender))
            }
            guard let offender = current.first(where: { !attempted.contains(closeKey(for: $0)) }) else {
                DispatchQueue.main.async {
                    self.isClosingAll = false
                    self.closeAllButton.isEnabled = true
                    self.refreshStatus()
                }
                return
            }

            DispatchQueue.main.async {
                var nextAttempted = attempted
                nextAttempted.insert(closeKey(for: offender))
                _ = closeOffender(offender)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.closeNextOffender(allowedKeys: allowedKeys, attempted: nextAttempted)
                }
            }
        }
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
