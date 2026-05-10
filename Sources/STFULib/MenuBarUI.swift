import AppKit
import Combine
import Foundation
import SwiftUI

func menuBarPrimaryLine(sourceCount: Int, isScanning: Bool, hasError: Bool) -> String {
    if hasError {
        return "Could not read sound sources"
    }
    if isScanning && sourceCount == 0 {
        return "Scanning..."
    }
    if sourceCount == 0 {
        return "All quiet"
    }
    return "\(sourceCount) sound source\(sourceCount == 1 ? "" : "s")"
}

func menuBarStatusSystemImage(sourceCount: Int, isScanning: Bool, hasError: Bool) -> String {
    if hasError {
        return "exclamationmark.triangle.fill"
    }
    if isScanning && sourceCount == 0 {
        return "waveform"
    }
    return sourceCount == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
}

func menuBarFocusActionTitle(for offender: SoundOffender) -> String? {
    switch offender.kind {
    case .safariTab, .chromiumTab:
        return "Go to Tab"
    case .unresolvedBrowser, .app:
        return "Go to App"
    case .blockedBrowser, .blockedAutomation:
        return nil
    }
}

func menuBarCloseActionTitle(for offender: SoundOffender) -> String? {
    switch offender.kind {
    case .safariTab, .chromiumTab:
        return "Close Tab"
    case .app:
        return "Quit App"
    case .blockedBrowser, .blockedAutomation:
        return "Open Settings"
    case .unresolvedBrowser:
        return nil
    }
}

func menuBarNeedsDestructiveConfirmation(for offender: SoundOffender) -> Bool {
    if case .app = offender.kind {
        return true
    }
    return false
}

func menuBarNeedsCloseAllConfirmation(closableCount: Int) -> Bool {
    closableCount > 0
}

extension Notification.Name {
    static let stfuShowMainWindow = Notification.Name("dev.hamel.stfu.showMainWindow")
}

@MainActor
final class STFUMenuBarController: NSObject, NSPopoverDelegate {
    private let model = STFUMenuBarModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    override init() {
        super.init()
        configureStatusItem()
        configurePopover()
        observeModel()
        model.refresh(showScanning: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refresh(showScanning: false)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.confirmation = nil
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.toolTip = "STFU"
        button.setAccessibilityLabel("STFU")
        updateStatusItem()
    }

    private func configurePopover() {
        let view = STFUMenuBarPanel(model: model)
            .frame(width: 430)
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .transient
        popover.delegate = self
    }

    private func observeModel() {
        Publishers.CombineLatest3(model.$offenders, model.$isScanning, model.$scanError)
            .sink { [weak self] _, _, _ in
                Task { @MainActor in
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: model.statusSystemImage, accessibilityDescription: model.primaryLine)
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(configuration)
        button.contentTintColor = model.offenders.isEmpty ? stfuSecondaryText() : stfuYellow()
        button.toolTip = model.primaryLine
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.refresh(showScanning: model.offenders.isEmpty)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@MainActor
final class STFUMenuBarModel: ObservableObject {
    @Published var offenders: [SoundOffender] = []
    @Published var scanError: Error?
    @Published var isScanning = false
    @Published var isClosingAll = false
    @Published var lastUpdated: Date?
    @Published var confirmation: STFUMenuConfirmation?

    private var scanGeneration = 0

    var statusSystemImage: String {
        menuBarStatusSystemImage(
            sourceCount: offenders.count,
            isScanning: isScanning,
            hasError: scanError != nil
        )
    }

    var primaryLine: String {
        menuBarPrimaryLine(
            sourceCount: offenders.count,
            isScanning: isScanning,
            hasError: scanError != nil
        )
    }

    var closableOffenders: [SoundOffender] {
        offenders.filter(isOffenderClosable)
    }

    func refresh(showScanning: Bool) {
        scanGeneration += 1
        let generation = scanGeneration
        if showScanning {
            isScanning = true
        }

        Task.detached(priority: .userInitiated) {
            let result: ScanResult
            do {
                result = .success(try soundOffenders())
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                self.apply(result, generation: generation)
            }
        }
    }

    func focus(_ offender: SoundOffender) {
        Task.detached(priority: .userInitiated) {
            _ = focusOffender(offender)
        }
    }

    func close(_ offender: SoundOffender) {
        if menuBarNeedsDestructiveConfirmation(for: offender) {
            confirmation = .quit(offender)
            return
        }

        performClose(offender)
    }

    func closeAll() {
        let targets = closableOffenders
        guard menuBarNeedsCloseAllConfirmation(closableCount: targets.count) else {
            NSSound.beep()
            return
        }
        confirmation = .closeAll(offenderCloseKeyCounts(for: targets), count: targets.count)
    }

    func confirm() {
        guard let confirmation else {
            return
        }
        self.confirmation = nil

        switch confirmation.kind {
        case let .quit(offender):
            performClose(offender)
        case let .closeAll(keys):
            isClosingAll = true
            closeNextOffender(remainingKeys: keys)
        }
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    func openFullApp() {
        NotificationCenter.default.post(name: .stfuShowMainWindow, object: nil)
    }

    private func apply(_ result: ScanResult, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        switch result {
        case let .success(found):
            offenders = found
            scanError = nil
            lastUpdated = Date()
        case let .failure(error):
            offenders = []
            scanError = error
        }
        isScanning = false
    }

    private func performClose(_ offender: SoundOffender) {
        Task.detached(priority: .userInitiated) {
            _ = closeOffender(offender, waitForAppExit: false)
            await MainActor.run {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.refresh(showScanning: false)
                }
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
                    self.isClosingAll = false
                    self.refresh(showScanning: false)
                }
                return
            }

            let key = offenderCloseKey(for: offender)
            var nextRemainingKeys = remainingKeys
            guard closeOffender(offender, waitForAppExit: false) else {
                await MainActor.run {
                    self.isClosingAll = false
                    self.refresh(showScanning: false)
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
}

struct STFUMenuConfirmation: Identifiable {
    enum Kind {
        case quit(SoundOffender)
        case closeAll([String: Int])
    }

    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let kind: Kind

    static func quit(_ offender: SoundOffender) -> STFUMenuConfirmation {
        STFUMenuConfirmation(
            title: "Quit \(offender.name)?",
            message: "STFU will ask this app to quit. Unsaved work in that app could be lost.",
            confirmTitle: "Quit App",
            kind: .quit(offender)
        )
    }

    static func closeAll(_ keys: [String: Int], count: Int) -> STFUMenuConfirmation {
        STFUMenuConfirmation(
            title: "STFU everything?",
            message: "This will close \(count) noisy source\(count == 1 ? "" : "s"). Browser tabs close directly; apps may quit.",
            confirmTitle: "STFU Everything",
            kind: .closeAll(keys)
        )
    }
}

struct STFUMenuBarPanel: View {
    @ObservedObject var model: STFUMenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let confirmation = model.confirmation {
                confirmationCard(confirmation)
            } else if let scanError = model.scanError {
                messageCard(
                    title: "Audio scan failed",
                    message: "\(scanError)",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Color(nsColor: stfuRed())
                )
            }

            sourceList
            footer
        }
        .padding(14)
        .background(Color(nsColor: stfuCanvas()))
        .foregroundStyle(Color(nsColor: stfuPrimaryText()))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.statusSystemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(headerTint)
                .frame(width: 28, height: 28)
                .background(Color(nsColor: stfuPanel()))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("STFU")
                    .font(.system(size: 15, weight: .black))
                Text(model.primaryLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(headerTint)
            }

            Spacer(minLength: 8)

            if let lastUpdated = model.lastUpdated {
                Text(lastUpdated, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: stfuSecondaryText()))
            }

            if model.closableOffenders.count > 1 {
                iconButton("STFU Everything", systemImage: "speaker.slash.fill", tint: Color(nsColor: stfuRed())) {
                    model.closeAll()
                }
                .disabled(model.isClosingAll)
            }
        }
        .padding(12)
        .background(Color(nsColor: stfuPanel()))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: stfuBorder()), lineWidth: 1)
        )
    }

    private var sourceList: some View {
        Group {
            if model.offenders.isEmpty && model.scanError == nil {
                messageCard(
                    title: model.isScanning ? "Listening..." : "All quiet",
                    message: model.isScanning ? "Checking the usual suspects." : "No active sound sources.",
                    systemImage: model.statusSystemImage,
                    tint: headerTint
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.offenders.enumerated()), id: \.offset) { _, offender in
                            STFUMenuBarRow(offender: offender, model: model)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 310)
                .background(Color(nsColor: stfuPanel()))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: stfuBorder()), lineWidth: 1)
                )
                .frame(height: sourceListHeight)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.refresh(showScanning: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)

            Button {
                model.openFullApp()
            } label: {
                Label("Open STFU", systemImage: "macwindow")
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Menu", systemImage: "xmark.circle")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var headerTint: Color {
        if model.scanError != nil {
            return Color(nsColor: stfuRed())
        }
        return model.offenders.isEmpty ? Color(nsColor: stfuSecondaryText()) : Color(nsColor: stfuYellow())
    }

    private var sourceListHeight: CGFloat {
        let visibleRows = min(max(model.offenders.count, 1), 4)
        return CGFloat(visibleRows) * 76 + 8
    }

    private func confirmationCard(_ confirmation: STFUMenuConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: stfuYellow()))
                Text(confirmation.title)
                    .font(.system(size: 13, weight: .bold))
            }
            Text(confirmation.message)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: stfuSecondaryText()))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelConfirmation()
                }
                Button(confirmation.confirmTitle) {
                    model.confirm()
                }
                .tint(Color(nsColor: stfuRed()))
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: stfuRowSelected()).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: stfuYellow()).opacity(0.35), lineWidth: 1)
        )
    }

    private func messageCard(title: String, message: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: stfuSecondaryText()))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: stfuPanel()))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: stfuBorder()), lineWidth: 1)
        )
    }

    private func iconButton(
        _ title: String,
        systemImage: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tint)
        .help(title)
    }
}

struct STFUMenuBarRow: View {
    let offender: SoundOffender
    @ObservedObject var model: STFUMenuBarModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 26, height: 26)
                .background(Color(nsColor: stfuCanvas()))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(offender.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(nsColor: stfuYellow()))
                    .lineLimit(1)
                Text(offender.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: stfuSecondaryText()))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if let title = menuBarFocusActionTitle(for: offender) {
                    iconButton(title, systemImage: "arrow.up.forward.square") {
                        model.focus(offender)
                    }
                }
                if let title = menuBarCloseActionTitle(for: offender) {
                    iconButton(title, systemImage: closeSystemImage, tint: closeTint) {
                        model.close(offender)
                    }
                }
            }
        }
        .padding(9)
        .background(Color(nsColor: stfuRow()))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var systemImage: String {
        switch offender.kind {
        case .safariTab, .chromiumTab:
            return "globe"
        case .app:
            return "app"
        case .blockedBrowser, .blockedAutomation:
            return "lock.fill"
        case .unresolvedBrowser:
            return "questionmark.app"
        }
    }

    private var iconTint: Color {
        switch offender.kind {
        case .blockedBrowser, .blockedAutomation:
            return Color(nsColor: stfuYellow())
        case .unresolvedBrowser:
            return Color(nsColor: stfuSecondaryText())
        default:
            return Color(nsColor: stfuPrimaryText())
        }
    }

    private var closeSystemImage: String {
        switch offender.kind {
        case .blockedBrowser, .blockedAutomation:
            return "gearshape.fill"
        case .app:
            return "power"
        case .safariTab, .chromiumTab:
            return "xmark"
        case .unresolvedBrowser:
            return "xmark"
        }
    }

    private var closeTint: Color? {
        switch offender.kind {
        case .blockedBrowser, .blockedAutomation:
            return Color(nsColor: stfuYellow())
        case .app, .safariTab, .chromiumTab:
            return Color(nsColor: stfuRed())
        case .unresolvedBrowser:
            return nil
        }
    }

    private func iconButton(
        _ title: String,
        systemImage: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tint)
        .help(title)
    }
}
