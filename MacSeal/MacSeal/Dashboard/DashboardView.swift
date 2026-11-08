import AppKit
import Foundation
import LocalAuthentication
import Observation
import ServiceManagement
import Sparkle
import SwiftUI

enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case sealing = "Sealing"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .sealing: "lock.fill"
        case .settings: "gearshape.fill"
        }
    }
}

enum UnsealAuthMethod: String, CaseIterable, Identifiable {
    case none = "None"
    case touchID = "Touch ID"
    case password = "Password"
    case touchIDOrPassword = "Touch ID or Password"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .touchID: "Touch ID"
        case .password: "Password"
        case .touchIDOrPassword: "Touch ID or Password"
        }
    }

    var description: String {
        switch self {
        case .none:
            "Unseal immediately without authentication."
        case .touchID:
            "Require Touch ID to unseal."
        case .password:
            "Require macOS authentication to unseal."
        case .touchIDOrPassword:
            "Require Touch ID or your macOS password to unseal."
        }
    }
}

@MainActor
final class ShortcutMonitor {
    var onTriggered: (() -> Void)?
    var onHoldingChanged: ((Bool) -> Void)?
    var duration = 1.0
    var shortcut = "⌘ ⇧ S"

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workItem: DispatchWorkItem?

    func start() {
        guard globalMonitor == nil && localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
            return event
        }
    }

    func stop() {
        cancel()
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
        onHoldingChanged?(false)
    }

    private func handle(_ event: NSEvent) {
        let expectedKey: UInt16
        let expectedModifiers: NSEvent.ModifierFlags

        switch shortcut {
        case "⌘ ⇧ S":
            expectedKey = 1
            expectedModifiers = [.command, .shift]
        case "⌘ ⇧ D":
            expectedKey = 2
            expectedModifiers = [.command, .shift]
        case "⌘ ⌥ S":
            expectedKey = 1
            expectedModifiers = [.command, .option]
        case "⌃ ⇧ S":
            expectedKey = 1
            expectedModifiers = [.control, .shift]
        default:
            return
        }

        if event.type == .keyUp && event.keyCode == expectedKey {
            cancel()
            return
        }

        guard event.type == .keyDown,
              event.keyCode == expectedKey,
              !event.isARepeat else {
            return
        }

        let modifiers = event.modifierFlags.intersection(
            [.command, .shift, .option, .control]
        )
        guard modifiers == expectedModifiers, workItem == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.workItem = nil
            self.onHoldingChanged?(false)
            self.onTriggered?()
        }
        workItem = item
        onHoldingChanged?(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }
}

enum SealTransition: Equatable {
    case sealing
    case unsealing
    case authenticating
}

@MainActor
@Observable
final class SealedModeState {
    var transition: SealTransition?
    var authenticationMessage: String?
}

final class SealedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            switch key {
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            case "z":
                if event.modifierFlags.contains(.shift) {
                    if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
                } else if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) {
                    return true
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct DashboardView: View {
    @State private var selectedPage: DashboardPage = .overview
    @State private var hasStartedAutomatically = false
    @State private var isSealed = false
    @State private var isAuthenticating = false
    @State private var shortcutMonitor = ShortcutMonitor()
    @State private var sealedWindow: NSWindow?
    @State private var sealedModeState = SealedModeState()
    @State private var updaterController: SPUStandardUpdaterController?

    @AppStorage("macseal.unsealAuthMethod")
    private var unsealAuthMethod: UnsealAuthMethod = .none

    @AppStorage("macseal.startWebsite")
    private var startWebsite = "https://www.apple.com"

    @AppStorage("macseal.sealOnLaunch")
    private var sealOnLaunch = false

    @AppStorage("macseal.launchAtLogin")
    private var launchAtLogin = false

    @AppStorage("macseal.shortcutEnabled")
    private var shortcutEnabled = true

    @AppStorage("macseal.holdDuration")
    private var holdDuration = 1.0

    @AppStorage("macseal.shortcut")
    private var shortcutChoice = "⌘ ⇧ S"

    @AppStorage("macseal.restrictDomain")
    private var restrictDomain = false

    @AppStorage("macseal.soundEffects")
    private var soundEffectsEnabled = true

    @AppStorage("macseal.showWebsiteToolbar")
    private var showWebsiteToolbar = true

    private var websiteURL: URL? {
        let website = startWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !website.isEmpty else { return nil }
        let address = website.contains("://") ? website : "https://" + website

        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil else {
            return nil
        }
        return components.url
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 850, minHeight: 600)
        .overlay {
            if sealedModeState.transition == .sealing {
                SealTransitionOverlay(
                    transition: .sealing,
                    shortcut: shortcutChoice
                )
            }
        }
        .onAppear {
            configureUpdater()
            configureShortcut()
            shortcutMonitor.start()
            guard sealOnLaunch, !hasStartedAutomatically else { return }
            hasStartedAutomatically = true
            DispatchQueue.main.async {
                sealMac()
            }
        }
        .onDisappear {
            shortcutMonitor.stop()
        }
        .onChange(of: shortcutChoice) { _, _ in
            configureShortcut()
        }
        .onChange(of: shortcutEnabled) { _, enabled in
            if enabled {
                configureShortcut()
            } else {
                shortcutMonitor.cancel()
            }
        }
        .onChange(of: holdDuration) { _, _ in
            configureShortcut()
        }
        .onChange(of: launchAtLogin) { _, enabled in
            updateLaunchAtLogin(enabled)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacSeal")
                        .font(.title2.bold())
                    Text("Website sealing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)

            ForEach(DashboardPage.allCases) { page in
                Button {
                    selectedPage = page
                } label: {
                    Label(page.rawValue, systemImage: page.icon)
                        .font(.system(size: 13, weight: .medium))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            if selectedPage == page {
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(Color.accentColor.opacity(0.18))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPage == page ? Color.accentColor : .primary)
            }

            Spacer()

            Label(isSealed ? "Sealed" : "Unsealed", systemImage: "circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(isSealed ? .orange : .green)
                .padding(12)
        }
        .padding(8)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
    }

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selectedPage {
            case .overview:
                overviewPage
            case .sealing:
                sealingPage
            case .settings:
                settingsPage
            }
        }
        .id(selectedPage)
        .transition(.opacity.combined(with: .offset(y: 8)))
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: selectedPage)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    updaterController?.checkForUpdates(nil)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(updaterController?.updater.canCheckForUpdates == false)
                .help("Check for MacSeal updates")
                .accessibilityLabel("Check for MacSeal updates")
            }
        }
    }

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageTitle("Overview", subtitle: "Your website sealing controls.")

                GroupBox("Protection status") {
                    HStack(spacing: 16) {
                        Image(systemName: isSealed ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 35))
                            .foregroundStyle(isSealed ? .orange : .green)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(isSealed ? "Mac is sealed" : "Mac is unsealed")
                                .font(.headline)
                            Text(isSealed ? "Your startup website is active." : "Your website is ready to seal.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(isSealed ? "Unseal" : "Seal") {
                            if isSealed {
                                handleUnsealRequest()
                            } else {
                                sealMac()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                }

                GroupBox("Current setup") {
                    VStack(alignment: .leading, spacing: 12) {
                        settingRow("Startup website", value: startWebsite, icon: "globe")
                        Divider()
                        settingRow("Shortcut", value: shortcutEnabled ? shortcutChoice : "Disabled", icon: "keyboard")
                        Divider()
                        settingRow("Hold duration", value: String(format: "%.1f seconds", holdDuration), icon: "timer")
                        Divider()
                        settingRow("Unseal authentication", value: unsealAuthMethod.title, icon: "touchid")
                    }
                    .padding(8)
                }

                HoldToSealButton(duration: holdDuration, action: sealMac)
            }
            .padding(28)
        }
    }

    private var sealingPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageTitle("Sealing", subtitle: "Choose how to seal and unseal your website.")

                GroupBox("Seal your website") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label(isSealed ? "Currently sealed" : "Currently unsealed", systemImage: "lock.shield.fill")
                            Spacer()
                            Button(isSealed ? "Unseal" : "Seal now") {
                                if isSealed {
                                    handleUnsealRequest()
                                } else {
                                    sealMac()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        HoldToSealButton(duration: holdDuration, action: sealMac)
                    }
                    .padding(10)
                }

                GroupBox("Keyboard shortcut") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Enable global shortcut", isOn: $shortcutEnabled)
                        Picker("Shortcut", selection: $shortcutChoice) {
                            Text("⌘ ⇧ S").tag("⌘ ⇧ S")
                            Text("⌘ ⇧ D").tag("⌘ ⇧ D")
                            Text("⌘ ⌥ S").tag("⌘ ⌥ S")
                            Text("⌃ ⇧ S").tag("⌃ ⇧ S")
                        }
                        .disabled(!shortcutEnabled)

                        HStack {
                            Text("Hold duration")
                            Spacer()
                            Text("\(holdDuration, specifier: "%.1f") seconds")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $holdDuration, in: 1...5, step: 0.5)
                            .disabled(!shortcutEnabled)
                    }
                    .padding(10)
                }

                GroupBox("Emergency recovery") {
                    Label(
                        "The sealed website toolbar includes an Unseal button.",
                        systemImage: "checkmark.shield.fill"
                    )
                    .padding(10)
                }
            }
            .padding(28)
        }
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageTitle("Settings", subtitle: "Set up startup, website, and sealing behavior.")

                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Seal automatically when MacSeal opens", isOn: $sealOnLaunch)
                        Toggle("Open MacSeal at login", isOn: $launchAtLogin)
                        Text("Automatic sealing starts the website when MacSeal opens. Login startup is managed by macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }

                GroupBox("Website to seal") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("https://www.apple.com", text: $startWebsite)
                            .textFieldStyle(.roundedBorder)
                        if websiteURL == nil {
                            Label("Enter a valid website address using HTTP or HTTPS.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(10)
                }

                GroupBox("Sealed website toolbar") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show website toolbar while sealed", isOn: $showWebsiteToolbar)
                        Text("The toolbar contains the website address, navigation controls, and an Unseal button. When hidden, use the configured keyboard shortcut to unseal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }

                GroupBox("Navigation protection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Restrict navigation to startup domains", isOn: $restrictDomain)
                        Text("When enabled, the sealed website can navigate only to the startup domain and its subdomains.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }

                GroupBox("Unseal authentication") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Authentication method", selection: $unsealAuthMethod) {
                            ForEach(UnsealAuthMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        Text(unsealAuthMethod.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }

                GroupBox("Sound effects") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Sound effects on seal/unseal", isOn: $soundEffectsEnabled)
                        Text("Play native macOS sounds when sealing and unsealing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }

                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MacSeal")
                            .font(.headline)
                        Text("Version \(currentVersion)")
                            .foregroundStyle(.secondary)
                        Text("Website sealing for macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
            }
            .padding(28)
        }
    }

    private func configureUpdater() {
        guard updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        controller.startUpdater()
        updaterController = controller
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            launchAtLogin = false
            print("Unable to update MacSeal login item: \(error)")
        }
    }

    private func sealMac() {
        guard !isSealed, let screen = NSScreen.main else { return }
        guard let websiteURL else {
            selectedPage = .settings
            return
        }

        isSealed = true
        UserDefaults.standard.set(true, forKey: "macseal.isSealed")
        NSApp.presentationOptions = [
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication
        ]

        let window = SealedWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.acceptsMouseMovedEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true

        let hostingView = NSHostingView(
            rootView: SealedModeView(
                url: websiteURL,
                shortcut: shortcutChoice,
                sealedModeState: sealedModeState,
                onUnsealRequested: handleUnsealRequest
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        window.contentView = hostingView
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        if soundEffectsEnabled {
            NSSound(named: "Purr")?.play()
        }
        sealedWindow = window
    }

    private func unsealMac() {
        sealedModeState.transition = nil
        sealedWindow?.close()
        sealedWindow = nil
        NSApp.presentationOptions = []
        UserDefaults.standard.set(false, forKey: "macseal.isSealed")
        isSealed = false
        if soundEffectsEnabled {
            NSSound(named: "Ping")?.play()
        }
    }

    private func handleUnsealRequest() {
        guard isSealed else { return }
        switch unsealAuthMethod {
        case .none:
            unsealMac()
        case .touchID:
            authenticateAndUnseal(
                policy: .deviceOwnerAuthenticationWithBiometrics,
                requireBiometricsOnly: true
            )
        case .password, .touchIDOrPassword:
            authenticateAndUnseal(
                policy: .deviceOwnerAuthentication,
                requireBiometricsOnly: false
            )
        }
    }

    private func authenticateAndUnseal(
        policy: LAPolicy,
        requireBiometricsOnly: Bool
    ) {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        sealedModeState.authenticationMessage = nil
        sealedModeState.transition = .authenticating

        let context = LAContext()
        if requireBiometricsOnly {
            context.localizedFallbackTitle = ""
        }

        var authError: NSError?
        guard context.canEvaluatePolicy(policy, error: &authError) else {
            isAuthenticating = false
            sealedModeState.transition = nil
            sealedModeState.authenticationMessage =
                authError?.localizedDescription ?? "Authentication is unavailable. MacSeal remains sealed."
            return
        }

        let reason = "Verify your identity to unseal MacSeal."
        context.evaluatePolicy(policy, localizedReason: reason) { success, error in
            Task { @MainActor in
                self.isAuthenticating = false
                self.sealedModeState.transition = nil
                if success {
                    self.unsealMac()
                } else if error.map({ ($0 as NSError).code != LAError.userCancel.rawValue }) ?? true {
                    self.sealedModeState.authenticationMessage =
                        error?.localizedDescription ?? "Authentication failed. MacSeal remains sealed."
                }
            }
        }
    }

    private func configureShortcut() {
        shortcutMonitor.shortcut = shortcutChoice
        shortcutMonitor.duration = holdDuration
        shortcutMonitor.onHoldingChanged = { isHolding in
            if isHolding {
                sealedModeState.transition = isSealed ? .unsealing : .sealing
            } else if !isAuthenticating {
                sealedModeState.transition = nil
            }
        }
        shortcutMonitor.onTriggered = {
            guard shortcutEnabled else { return }
            if isSealed {
                handleUnsealRequest()
            } else {
                sealMac()
            }
        }
    }

    private func pageTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private func settingRow(_ title: String, value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct HoldToSealButton: View {
    let duration: Double
    let action: () -> Void

    @State private var isHolding = false
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            Text(isHolding ? "Keep holding…" : "Hold to Seal")
                .font(.headline)
            ProgressView(value: progress)
                .frame(maxWidth: 300)
                .tint(.green)
            Text("\(duration, specifier: "%.1f") seconds")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onLongPressGesture(
            minimumDuration: duration,
            maximumDistance: 30,
            pressing: { pressing in
                isHolding = pressing
                if pressing {
                    progress = 0
                    withAnimation(.linear(duration: duration)) {
                        progress = 1
                    }
                } else {
                    progress = 0
                }
            },
            perform: {
                action()
                isHolding = false
                progress = 0
            }
        )
    }
}

struct SealTransitionOverlay: View {
    let transition: SealTransition
    let shortcut: String

    @State private var isAnimating = false

    private var title: LocalizedStringKey {
        switch transition {
        case .sealing: "Sealing…"
        case .unsealing: "Unsealing…"
        case .authenticating: "Authenticating…"
        }
    }

    private var symbolName: String {
        switch transition {
        case .sealing: "lock.fill"
        case .unsealing: "lock.open.fill"
        case .authenticating: "touchid"
        }
    }

    private var tint: Color {
        switch transition {
        case .sealing: .orange
        case .unsealing: .green
        case .authenticating: .blue
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 54, height: 54)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                Image(systemName: symbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .scaleEffect(isAnimating ? 1.08 : 0.92)
            }
            Text(title)
                .font(.headline)
            if transition == .authenticating {
                Text("Confirm your identity to unseal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Keep holding \(shortcut)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}
