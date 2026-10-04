import AppKit
import WebKit

/// Die echte Trade-Republic-Website in einem eigenen Fenster, nur für eine Synchronisierung. Abfragen laufen per
/// JavaScript in der eingeloggten Seite, damit Cookies, Herkunft und Bot-Schutz genau wie bei der Web-App sind.
/// Nichts wird gespeichert: Jede Synchronisierung beginnt mit einer frischen Anmeldung.
/// Ein externer Browser ginge nicht: Apps kommen nicht an dessen Anmeldung heran.
@MainActor
final class TRWebSession: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let startURL = URL(string: "https://app.traderepublic.com/login")!

    private let webView: WKWebView
    private let window: NSWindow
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let onPage: (_ onLoginPage: Bool) -> Void
    private let onClose: () -> Void
    private var urlObservation: NSKeyValueObservation?
    private var pollTimer: Timer?
    private var closing = false
    private(set) var isLoading = false

    init(onPage: @escaping (_ onLoginPage: Bool) -> Void, onClose: @escaping () -> Void) {
        self.onPage = onPage
        self.onClose = onClose
        let config = WKWebViewConfiguration()
        // Nichts dauerhaft speichern; nach dem Schließen ist die Sitzung weg.
        config.websiteDataStore = .nonPersistent()
        // Wie Safari auftreten; ohne "Safari/…" im User-Agent lehnen manche Websites den Browser ab.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: config)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Trade Republic"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 380, height: 520)
        super.init()

        hint.stringValue = L(
            "Log in with your phone number and PIN and confirm in the Trade Republic app. This window closes automatically once your portfolio is synchronized.")
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

        // Die Web-App wechselt nach dem Login die Adresse oft ohne Neuladen; das meldet nur die url-Eigenschaft.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reportPage("Adresse") }
        }
    }

    var onLoginPage: Bool { webView.url?.path.lowercased().contains("login") ?? true }

    func showLogin() {
        if webView.url == nil {
            isLoading = true
            webView.load(URLRequest(url: Self.startURL))
        }
        window.bringToFront()
        // Zusätzlich regelmäßig nachsehen, falls die Seite den Wechsel nicht über die Adresse meldet.
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onPage(self?.onLoginPage ?? true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Hinweis oben im Fenster ersetzen (z. B. "Synchronisiere …").
    func showStatus(_ text: String) {
        hint.stringValue = text
    }

    /// Fenster schließen, ohne `onClose` auszulösen (nach erfolgreicher Synchronisierung).
    func close() {
        closing = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        urlObservation = nil
        webView.stopLoading()
        if !closing { onClose() }
    }

    // MARK: - Laden

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading("geladen")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading("Fehler: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading("Fehler: \(error.localizedDescription)")
    }

    private func finishLoading(_ what: String) {
        isLoading = false
        reportPage(what)
    }

    private func reportPage(_ what: String) {
        TRLog.write("Seite \(what): \(webView.url?.path ?? "–")")
        onPage(onLoginPage)
    }

    // MARK: - Abfragen aus der Seite heraus

    /// GET an die API mit den Cookies der Seite. Liefert HTTP-Status und JSON.
    func fetchJSON(_ path: String) async throws -> (status: Int, json: Any?) {
        let script = """
            const response = await fetch("https://api.traderepublic.com" + path, {
                credentials: "include", headers: { "Accept": "application/json" } });
            return JSON.stringify({ status: response.status, body: await response.text() });
            """
        let result = try await run(script, ["path": path])
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? Int else { throw TradeRepublic.Failure.invalidResponse }
        return (status, (object["body"] as? String).flatMap(TRProtocol.json))
    }

    /// Öffnet aus der Seite eine WebSocket-Verbindung, abonniert alle Themen und liefert je Thema die erste
    /// Antwort als (Code, Payload): A = Daten, E = Fehler.
    func subscribe(_ payloads: [[String: Any]], locale: String) async throws -> [(Character, String)] {
        let script = """
            const topics = JSON.parse(payloadsJSON);
            return await new Promise((resolve, reject) => {
                const socket = new WebSocket("wss://api.traderepublic.com");
                const results = {};
                let count = 0;
                const timer = setTimeout(() => { socket.close(); reject(new Error("timeout")); }, 20000);
                socket.onopen = () => socket.send("connect 31 " + JSON.stringify({
                    locale: locale, platformId: "webtrading", platformVersion: "safari - 18.0.0",
                    clientId: "app.traderepublic.com", clientVersion: "5582" }));
                socket.onmessage = (event) => {
                    const text = String(event.data);
                    if (text.startsWith("connected")) {
                        topics.forEach((topic, index) => socket.send("sub " + (index + 1) + " " + JSON.stringify(topic)));
                        return;
                    }
                    const match = text.match(/^(\\d+) ([ACDE]) ?([\\s\\S]*)$/);
                    if (!match || results[match[1]]) return;
                    results[match[1]] = { code: match[2], payload: match[3] };
                    socket.send("unsub " + match[1]);
                    if (++count === topics.length) {
                        clearTimeout(timer);
                        socket.close();
                        resolve(JSON.stringify(topics.map((_, index) => results[index + 1])));
                    }
                };
                socket.onerror = () => { clearTimeout(timer); reject(new Error("websocket")); };
                socket.onclose = (event) => {
                    if (count < topics.length) { clearTimeout(timer); reject(new Error("closed " + event.code)); }
                };
            });
            """
        let json = (try? JSONSerialization.data(withJSONObject: payloads)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let result = try await run(script, ["payloadsJSON": json, "locale": locale])
        guard let data = result.data(using: .utf8),
              let answers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              answers.count == payloads.count else { throw TradeRepublic.Failure.invalidResponse }
        return answers.map { (($0["code"] as? String)?.first ?? "?", $0["payload"] as? String ?? "") }
    }

    private func run(_ script: String, _ arguments: [String: Any]) async throws -> String {
        do {
            let value = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
            guard let text = value as? String else { throw TradeRepublic.Failure.invalidResponse }
            return text
        } catch let error as TradeRepublic.Failure {
            throw error
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            TRLog.write("JavaScript: \(message)")
            throw message.contains("timeout") ? TradeRepublic.Failure.timeout : TradeRepublic.Failure.invalidResponse
        }
    }
}
