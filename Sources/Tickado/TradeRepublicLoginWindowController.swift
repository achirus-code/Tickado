import AppKit
import WebKit

/// Fenster mit der echten Trade-Republic-Website. Angemeldet wird dort (Handynummer, PIN, Bestätigung in der App);
/// sobald die Website eine gültige Session hat, übernimmt Tickado deren Cookies und schließt das Fenster.
/// Die Cookies eines normalen Browsers wären für Tickado nicht erreichbar, deshalb die eingebettete Seite.
@MainActor
final class TradeRepublicLoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate,
    WKHTTPCookieStoreObserver {
    private static var current: TradeRepublicLoginWindowController?

    private let webView: WKWebView
    private let onConnected: () -> Void
    private var pendingCheck: Task<Void, Never>?
    private var checking = false

    /// Öffnet das Fenster (oder holt ein offenes nach vorn).
    static func show(onConnected: @escaping () -> Void) {
        let controller = current ?? TradeRepublicLoginWindowController(onConnected: onConnected)
        current = controller
        controller.window?.bringToFront()
    }

    private init(onConnected: @escaping () -> Void) {
        self.onConnected = onConnected
        let config = WKWebViewConfiguration()
        // Nichts dauerhaft im WebKit-Speicher ablegen; die Session liegt nur im Schlüsselbund.
        config.websiteDataStore = .nonPersistent()
        // Wie Safari auftreten; ohne "Safari/…" im User-Agent lehnen manche Websites den Browser ab.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: config)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Trade Republic"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 380, height: 520)
        super.init(window: window)

        let hint = NSTextField(wrappingLabelWithString: L(
            "Log in with your phone number and PIN and confirm in the Trade Republic app. This window closes automatically once you are connected."))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let content = NSView()
        for view in [hint, webView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            webView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
        window.delegate = self

        webView.navigationDelegate = self
        config.websiteDataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: URL(string: "https://app.traderepublic.com/login")!))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        pendingCheck?.cancel()
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        Self.current = nil
    }

    // MARK: - Erkennen, dass die Anmeldung fertig ist

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        scheduleCheck()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleCheck()
    }

    /// Kurz warten, weil beim Login mehrere Cookies nacheinander gesetzt werden.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    private func check() async {
        guard !checking else { return }
        let all = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let cookies = all.filter { $0.domain.hasSuffix("traderepublic.com") }
        // Nur prüfen, wenn es nach einer Session aussieht; sonst keine Anfragen während der Eingabe.
        let onLoginPage = webView.url?.path.contains("login") ?? true
        guard !cookies.isEmpty, !onLoginPage || cookies.contains(where: { $0.name.lowercased().contains("session") })
        else { return }

        checking = true
        let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        let connected = await TradeRepublic.shared.adopt(cookies, userAgent: userAgent)
        checking = false
        guard connected else { return }
        onConnected()
        close()
    }
}
