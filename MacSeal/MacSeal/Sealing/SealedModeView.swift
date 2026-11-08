//
//  SealedModeView.swift
//  MacSeal
//
//  Created by Arthur Collin-Tremblay Cmsc on 2026-11-04.
//

import SwiftUI
import AppKit
import WebKit
import Observation

// MARK: - Hover Cursor Modifier

struct PointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

// MARK: - Web Browser Controller

@MainActor
@Observable
final class WebBrowserController {
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0.0
    var currentURLString = ""
    var currentTitle = ""
    var pageZoom: CGFloat = 1.0
    var isDomainBlocked = false
    var blockedDomain = ""

    weak var webView: WKWebView?

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    func stop() {
        webView?.stopLoading()
    }

    func loadHome(url: URL) {
        isDomainBlocked = false
        webView?.load(URLRequest(url: url))
    }

    func load(urlString: String) {
        isDomainBlocked = false
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !trimmed.contains("://") {
            if trimmed.contains(".") && !trimmed.contains(" ") {
                trimmed = "https://" + trimmed
            } else {
                let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
                trimmed = "https://www.google.com/search?q=" + encoded
            }
        }

        if let targetURL = URL(string: trimmed) {
            webView?.load(URLRequest(url: targetURL))
        }
    }

    func zoomIn() {
        pageZoom = min(pageZoom + 0.15, 2.5)
        webView?.pageZoom = pageZoom
    }

    func zoomOut() {
        pageZoom = max(pageZoom - 0.15, 0.5)
        webView?.pageZoom = pageZoom
    }

    func resetZoom() {
        pageZoom = 1.0
        webView?.pageZoom = 1.0
    }
}

// MARK: - Sealed Web Browser

struct SealedWebBrowser: NSViewRepresentable {
    let url: URL
    @Bindable var controller: WebBrowserController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, initialURL: url)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Inject CSS rule guaranteeing all clickable elements show the pointer/click cursor
        let clickCursorCSS = """
        a, button, [role="button"], input[type="submit"], input[type="button"], input[type="reset"], select, summary, [onclick], .btn {
            cursor: pointer !important;
        }
        """
        let script = WKUserScript(
            source: """
            (function() {
                const style = document.createElement('style');
                style.id = 'macseal-click-cursor';
                style.textContent = `\(clickCursorCSS)`;
                if (document.head) {
                    document.head.appendChild(style);
                } else {
                    document.addEventListener('DOMContentLoaded', () => document.head.appendChild(style));
                }
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)

        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = context.coordinator
        context.coordinator.attach(to: browser)
        browser.load(URLRequest(url: url))
        return browser
    }

    func updateNSView(_ browser: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        var controller: WebBrowserController
        var initialURL: URL
        private var observations: [NSKeyValueObservation] = []

        init(controller: WebBrowserController, initialURL: URL) {
            self.controller = controller
            self.initialURL = initialURL
            super.init()
        }

        func attach(to webView: WKWebView) {
            controller.webView = webView
            observations.removeAll()

            observations.append(webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.controller.canGoBack = wv.canGoBack }
            })
            observations.append(webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.controller.canGoForward = wv.canGoForward }
            })
            observations.append(webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.controller.isLoading = wv.isLoading }
            })
            observations.append(webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.controller.progress = wv.estimatedProgress }
            })
            observations.append(webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.controller.currentTitle = wv.title ?? "" }
            })
            observations.append(webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in
                    if let str = wv.url?.absoluteString {
                        self?.controller.currentURLString = str
                    }
                }
            })
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let targetURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let restrictDomain = UserDefaults.standard.bool(forKey: "macseal.restrictDomain")
            if restrictDomain, let host = targetURL.host?.lowercased(), !host.isEmpty {
                let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let baseHost = (initialURL.host?.lowercased() ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let isStartupDomain = normalizedHost == baseHost ||
                    normalizedHost.hasSuffix("." + baseHost)
                if !baseHost.isEmpty && !isStartupDomain {
                    Task { @MainActor in
                        self.controller.isDomainBlocked = true
                        self.controller.blockedDomain = host
                    }
                    decisionHandler(.cancel)
                    return
                }
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            print("MacSeal navigation error: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            print("MacSeal loading error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Sealed Mode View

struct SealedModeView: View {
    let url: URL
    let shortcut: String
    let sealedModeState: SealedModeState
    var onUnsealRequested: (() -> Void)? = nil

    @State private var controller = WebBrowserController()
    @State private var addressText = ""
    @State private var isEditingAddress = false
    @State private var isBarPinned = true
    @State private var isHoveringTop = false

    @AppStorage("macseal.showWebsiteToolbar")
    private var showWebsiteToolbar = true

    private var showTopBar: Bool {
        showWebsiteToolbar && (isBarPinned || isHoveringTop || isEditingAddress)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            SealedWebBrowser(url: url, controller: controller)
                .ignoresSafeArea()

            if controller.isLoading && controller.progress < 1.0 {
                ProgressView(value: controller.progress)
                    .progressViewStyle(.linear)
                    .tint(.cyan)
                    .frame(height: 3)
                    .offset(y: showTopBar ? 52 : 0)
                    .animation(.easeInOut(duration: 0.2), value: showTopBar)
            }

            if showWebsiteToolbar {
                Color.clear
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHoveringTop = hovering
                        }
                    }
 
                if showTopBar {
                    topControlBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isBarPinned = true
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .padding(.top, 4)
                    .transition(.opacity)
                }
            }

            if controller.isDomainBlocked {
                domainBlockedOverlay
            }

            if let transition = sealedModeState.transition {
                SealTransitionOverlay(
                    transition: transition,
                    shortcut: shortcut
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .onAppear {
            addressText = url.absoluteString
        }
        .onChange(of: controller.currentURLString) { _, newURL in
            if !isEditingAddress && !newURL.isEmpty {
                addressText = newURL
            }
        }
        .alert(
            "Unable to authenticate",
            isPresented: Binding(
                get: { sealedModeState.authenticationMessage != nil },
                set: { if !$0 { sealedModeState.authenticationMessage = nil } }
            )
        ) {
            Button("OK") {
                sealedModeState.authenticationMessage = nil
            }
        } message: {
            Text(sealedModeState.authenticationMessage ?? "MacSeal remains sealed.")
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        HStack(spacing: 10) {
            // Status & Session Timer
            HStack(spacing: 6) {
                Image(systemName: "shield.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13))

                Text("Sealed")
                    .font(.caption.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.08), in: Capsule())

            Divider().frame(height: 18)

            // Navigation Controls
            HStack(spacing: 4) {
                Button { controller.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!controller.canGoBack)
                .opacity(controller.canGoBack ? 1.0 : 0.4)
                .pointingHandCursor()

                Button { controller.goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!controller.canGoForward)
                .opacity(controller.canGoForward ? 1.0 : 0.4)
                .pointingHandCursor()

                Button {
                    if controller.isLoading {
                        controller.stop()
                    } else {
                        controller.reload()
                    }
                } label: {
                    Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button { controller.loadHome(url: url) } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 12))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            // Interactive Address Bar & Search Field
            HStack(spacing: 6) {
                Image(systemName: controller.currentURLString.hasPrefix("https") ? "lock.fill" : "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(controller.currentURLString.hasPrefix("https") ? .green : .secondary)

                TextField("Search Google or enter web address...", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        isEditingAddress = false
                        controller.load(urlString: addressText)
                    }

                if !addressText.isEmpty {
                    Button {
                        addressText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                Button {
                    isEditingAddress = false
                    controller.load(urlString: addressText)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            // Zoom Controls
            HStack(spacing: 2) {
                Button { controller.zoomOut() } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button { controller.resetZoom() } label: {
                    Text("\(Int(controller.pageZoom * 100))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .frame(width: 36, height: 22)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button { controller.zoomIn() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Divider().frame(height: 18)

            // Pin / Auto-hide Toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isBarPinned.toggle()
                }
            } label: {
                Image(systemName: isBarPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(isBarPinned ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            // Quick Unseal Button
            Button {
                onUnsealRequested?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 11))
                    Text("Unseal")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        .padding(.top, 56)
        .padding(.horizontal, 20)
    }

    // MARK: - Domain Blocked Overlay

    private var domainBlockedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("External Website Restricted")
                .font(.title3.bold())

            Text("Navigation to \"\(controller.blockedDomain)\" is restricted by MacSeal domain security rules.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 12) {
                Button("Return to Home") {
                    controller.loadHome(url: url)
                }
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()

                Button("Dismiss") {
                    controller.isDomainBlocked = false
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
            }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 20)
        .padding(.top, 100)
    }
}
