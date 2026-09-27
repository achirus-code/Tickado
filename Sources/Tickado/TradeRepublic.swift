import Foundation

/// Eine Depotposition bei Trade Republic (Kurse in Euro).
struct TRPosition {
    let isin: String
    var name: String
    let quantity: Double
    let averageBuyIn: Double?
    var price: Double?
    var previousClose: Double?

    var value: Double? { price.map { $0 * quantity } }

    /// Tagesänderung in Prozent (letzter Kurs gegen Schlusskurs des Vortags).
    var change: Double? {
        guard let price, let previousClose, previousClose > 0 else { return nil }
        return (price / previousClose - 1) * 100
    }
}

struct TRPortfolio {
    let positions: [TRPosition]
    let cash: Double?
    let updated: Date

    var value: Double { positions.compactMap(\.value).reduce(0, +) }

    /// Depotwert einschließlich Guthaben.
    var total: Double { value + (cash ?? 0) }

    /// Gewinn heute in Euro (gegen die Schlusskurse vom Vortag).
    var todayGain: Double? {
        let priced = positions.filter { $0.price != nil && $0.previousClose != nil }
        guard !priced.isEmpty else { return nil }
        return priced.reduce(0) { $0 + ($1.price! - $1.previousClose!) * $1.quantity }
    }

    /// Gewinn seit Kauf in Euro und Prozent (aus dem Ø-Kaufkurs).
    var totalGain: (amount: Double, percent: Double?)? {
        let priced = positions.filter { $0.price != nil && ($0.averageBuyIn ?? 0) > 0 }
        guard !priced.isEmpty else { return nil }
        let cost = priced.reduce(0) { $0 + $1.averageBuyIn! * $1.quantity }
        let now = priced.reduce(0) { $0 + $1.price! * $1.quantity }
        return (now - cost, cost > 0 ? (now / cost - 1) * 100 : nil)
    }

    /// Tagesänderung des ganzen Depots, gewichtet über die Positionen mit Vortageskurs.
    var change: Double? {
        let priced = positions.filter { $0.price != nil && ($0.previousClose ?? 0) > 0 }
        let before = priced.reduce(0) { $0 + $1.previousClose! * $1.quantity }
        guard before > 0 else { return nil }
        let now = priced.reduce(0) { $0 + $1.price! * $1.quantity }
        return (now / before - 1) * 100
    }
}

/// Depotkennzahlen, die sich wie ein Kurs in der Menüleiste anzeigen lassen (Häkchen im Untermenü).
enum DepotTicker: String, CaseIterable {
    case value = "tr:value", today = "tr:today", total = "tr:total"

    /// Titel im Untermenü
    var title: String {
        switch self {
        case .value: L("Portfolio value")
        case .today: L("Gain today")
        case .total: L("Total gain")
        }
    }

    /// Kurzer Name in der Menüleiste
    var label: String {
        switch self {
        case .value: "TR"
        case .today: L("TR today")
        case .total: L("TR total")
        }
    }

    /// Als Pseudo-Wert, damit Ticker, Rotation und Vorschau ihn wie einen Kurs behandeln.
    var coin: Coin { Coin(id: rawValue, symbol: label, name: title, rank: nil, kind: .stock) }

    /// (Betrag, Prozent für Farbe und Anzeige, mit Vorzeichen?)
    func figures(in portfolio: TRPortfolio) -> (amount: Double?, percent: Double?, signed: Bool) {
        switch self {
        case .value: (portfolio.total, portfolio.change, false)
        case .today: (portfolio.todayGain, portfolio.change, true)
        case .total: (portfolio.totalGain?.amount, portfolio.totalGain?.percent, true)
        }
    }
}

/// Nachrichtenformat der Trade-Republic-WebSocket-Schnittstelle, ohne Netzwerk (testbar).
enum TRProtocol {
    struct Message {
        let id: Int
        let code: Character   // A = vollständig, D = Delta, C = beendet, E = Fehler
        let payload: String
    }

    /// "12 A {...}" → Message; alles andere (z. B. "connected") → nil.
    static func parse(_ text: String) -> Message? {
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let id = Int(parts[0]), parts[1].count == 1, let code = parts[1].first else { return nil }
        return Message(id: id, code: code, payload: parts.count > 2 ? String(parts[2]) : "")
    }

    /// Delta gegen die vorige Antwort: tab-getrennt "+text" (neu, URL-kodiert), "=n" (n Zeichen übernehmen),
    /// "-n" (n Zeichen überspringen). Wie pytr: "+" wird zu Leerzeichen, Ränder werden getrimmt.
    static func applyDelta(_ delta: String, to previous: String) -> String {
        let old = Array(previous)
        var index = 0
        var result = ""
        for diff in delta.split(separator: "\t", omittingEmptySubsequences: true) {
            let sign = diff.first
            let rest = diff.dropFirst()
            switch sign {
            case "+":
                let decoded = (" " + rest.replacingOccurrences(of: "+", with: " ")).removingPercentEncoding ?? String(rest)
                result += decoded.trimmingCharacters(in: .whitespaces)
            case "=", "-":
                let count = Int(rest) ?? 0
                if sign == "=" {
                    let end = min(index + count, old.count)
                    if index < end { result += String(old[index..<end]) }
                }
                index += count
            default:
                break
            }
        }
        return result
    }

    static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// Zahl aus JSON; Trade Republic liefert Beträge teils als String ("72.15").
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    /// Positionen aus `compactPortfolioByType` (categories[].positions[]) oder `compactPortfolio` (positions[]).
    static func positions(from json: Any?) -> [TRPosition] {
        guard let root = json as? [String: Any] else { return [] }
        var raw = root["positions"] as? [[String: Any]] ?? []
        for category in root["categories"] as? [[String: Any]] ?? [] {
            raw += category["positions"] as? [[String: Any]] ?? []
        }
        return raw.compactMap { item in
            guard let isin = (item["instrumentId"] ?? item["isin"]) as? String,
                  let quantity = number(item["netSize"]), quantity > 0 else { return nil }
            return TRPosition(isin: isin, name: item["name"] as? String ?? isin, quantity: quantity,
                              averageBuyIn: number(item["averageBuyIn"]), price: nil, previousClose: nil)
        }
    }

    struct Instrument {
        let name: String
        let exchange: String
        let isBond: Bool
    }

    static func instrument(from json: Any?) -> Instrument? {
        guard let root = json as? [String: Any] else { return nil }
        let name = root["shortName"] as? String ?? root["name"] as? String
        guard let name else { return nil }
        let exchange = (root["exchangeIds"] as? [String])?.first ?? "LSX"
        return Instrument(name: name, exchange: exchange, isBond: root["typeId"] as? String == "bond")
    }

    /// (letzter Kurs, Schlusskurs Vortag) aus einer `ticker`-Antwort.
    static func ticker(from json: Any?) -> (price: Double?, previous: Double?) {
        guard let root = json as? [String: Any] else { return (nil, nil) }
        let price = number((root["last"] as? [String: Any])?["price"])
        let previous = number((root["pre"] as? [String: Any])?["price"])
        return (price, previous)
    }

    /// Guthaben aus der `cash`-Antwort ([{"amount": …, "currencyId": "EUR"}]).
    static func cash(from json: Any?) -> Double? {
        let accounts = json as? [[String: Any]] ?? []
        let euro = accounts.first { ($0["currencyId"] as? String ?? "EUR") == "EUR" }
        return number(euro?["amount"])
    }

    /// Fehlermeldung aus {"errors": [{"errorCode": …, "errorMessage": …}]}.
    static func errorMessage(_ json: Any?) -> (code: String?, message: String?) {
        let first = ((json as? [String: Any])?["errors"] as? [[String: Any]])?.first
        return (first?["errorCode"] as? String, first?["errorMessage"] as? String)
    }
}

/// Depot bei Trade Republic über die inoffizielle Web-Schnittstelle (dieselbe wie app.traderepublic.com).
/// Angemeldet wird auf der echten Website in `TRWebSession`. Das Fenster bleibt danach unsichtbar offen wie ein
/// Browser-Tab, und alle Abfragen laufen per JavaScript aus dieser Seite heraus: mit ihren Cookies, ihrer Herkunft
/// und ihrem Bot-Schutz. Nachgebaute Anfragen von außen lehnt Trade Republic dagegen ab.
@MainActor
final class TradeRepublic {
    static let shared = TradeRepublic()

    enum State {
        case loggedOut, connected, expired
    }

    enum Failure: LocalizedError {
        case sessionExpired, timeout, invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .sessionExpired: L("Session expired. Please log in again.")
            case .timeout: L("Trade Republic did not respond.")
            case .invalidResponse: L("Unexpected response from Trade Republic.")
            case .server(let message): message
            }
        }
    }

    private(set) var state: State = .loggedOut
    private var web: TRWebSession?
    private var instruments: [String: TRProtocol.Instrument] = [:]
    private var onConnected: (() -> Void)?
    private var verifying = false

    private init() {
        // War Tickado schon verbunden, liegt die Session im WebKit-Speicher; die Seite im Hintergrund laden.
        if Prefs.shared.trLinked {
            state = .connected
            session().load()
        }
    }

    private var locale: String {
        Locale.preferredLanguages.first.flatMap { Locale.Language(identifier: $0).languageCode?.identifier } ?? "de"
    }

    private func session() -> TRWebSession {
        if let web { return web }
        let web = TRWebSession { [weak self] onLoginPage in self?.pageChanged(onLoginPage: onLoginPage) }
        self.web = web
        return web
    }

    // MARK: - Anmelden

    /// Zeigt die Anmeldeseite; `onConnected` läuft, sobald Tickado die Session erkannt hat.
    func connect(onConnected: @escaping () -> Void) {
        self.onConnected = onConnected
        session().showLogin()
    }

    /// Die Seite hat gewechselt (auch innerhalb der Web-App ohne Neuladen) oder der Anmelde-Timer fragt nach.
    private func pageChanged(onLoginPage: Bool) {
        guard let web else { return }
        if onLoginPage {
            // Im Hintergrund auf der Anmeldeseite gelandet: Trade Republic hat die Session beendet.
            if state == .connected, !web.isWindowVisible, !web.isLoading {
                TRLog.write("Hintergrundseite zeigt Login → abgelaufen")
                state = .expired
            }
            return
        }
        // Während eine Seite lädt, ist die Prüfung sinnlos (Anfragen scheitern); didFinish meldet sich danach.
        if (state != .connected || web.isWindowVisible), !web.isLoading { Task { await verify() } }
    }

    /// Prüft aus der Seite heraus, ob sie angemeldet ist (Depotnummer abrufbar).
    private func verify() async {
        guard let web, !verifying else { return }
        verifying = true
        defer { verifying = false }
        do {
            let (status, json) = try await web.fetchJSON("/api/v2/auth/account")
            TRLog.write("Prüfung /api/v2/auth/account → HTTP \(status)")
            guard status == 200, let account = (json as? [String: Any])?["securitiesAccountNumber"] as? String else { return }
            Prefs.shared.trAccount = account
            Prefs.shared.trLinked = true
            instruments = [:]
            state = .connected
            web.hideWindow()
            TRLog.write("verbunden")
            onConnected?()
            onConnected = nil
        } catch {
            TRLog.write("Prüfung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func logOut() {
        TRLog.write("abgemeldet")
        web?.clear()
        web = nil
        instruments = [:]
        Prefs.shared.trLinked = false
        Prefs.shared.trAccount = nil
        state = .loggedOut
    }

    // MARK: - Depot

    func fetchPortfolio() async throws -> TRPortfolio {
        guard state == .connected else { throw Failure.sessionExpired }
        let web = session()
        await web.waitUntilLoaded()
        guard !web.onLoginPage else {
            state = .expired
            throw Failure.sessionExpired
        }
        do {
            return try await load(from: web)
        } catch Failure.sessionExpired {
            // Einmal die Session erneuern (wie die Web-App selbst) und erneut versuchen.
            let refreshed = try? await web.fetchJSON("/api/v1/auth/web/session")
            TRLog.write("Session erneuern → HTTP \(refreshed?.status ?? 0)")
            if refreshed?.status == 200, let portfolio = try? await load(from: web) { return portfolio }
            state = .expired
            throw Failure.sessionExpired
        } catch {
            TRLog.write("Depot: \(error.localizedDescription)")
            throw error
        }
    }

    private func load(from web: TRWebSession) async throws -> TRPortfolio {
        if Prefs.shared.trAccount == nil,
           let (status, json) = try? await web.fetchJSON("/api/v2/auth/account"), status == 200 {
            Prefs.shared.trAccount = (json as? [String: Any])?["securitiesAccountNumber"] as? String
        }
        let portfolioRequest: [String: Any] = Prefs.shared.trAccount.map { ["type": "compactPortfolioByType", "secAccNo": $0] }
            ?? ["type": "compactPortfolio"]
        guard case .success(let portfolio) = try await request(web, [portfolioRequest])[0] else {
            throw Failure.invalidResponse
        }
        var positions = TRProtocol.positions(from: portfolio)

        // Stammdaten (Name, Börse) nur einmal je Wertpapier holen.
        let missing = Array(Set(positions.map(\.isin)).filter { instruments[$0] == nil })
        let details = try await request(web, missing.map { ["type": "instrument", "id": $0] })
        for (isin, result) in zip(missing, details) {
            if case .success(let json) = result, let instrument = TRProtocol.instrument(from: json) {
                instruments[isin] = instrument
            }
        }

        let tickers = positions.map { ["type": "ticker", "id": "\($0.isin).\(instruments[$0.isin]?.exchange ?? "LSX")"] }
        let answers = try await request(web, tickers + [["type": "cash"]])
        for index in positions.indices {
            let instrument = instruments[positions[index].isin]
            if let instrument { positions[index].name = instrument.name }
            guard case .success(let json) = answers[index] else { continue }
            let ticker = TRProtocol.ticker(from: json)
            // Anleihen notieren in Prozent vom Nennwert.
            let factor = instrument?.isBond == true ? 0.01 : 1
            positions[index].price = ticker.price.map { $0 * factor }
            positions[index].previousClose = ticker.previous.map { $0 * factor }
        }
        var cash: Double?
        if case .success(let json) = answers[positions.count] { cash = TRProtocol.cash(from: json) }
        TRLog.write("Depot geladen: \(positions.count) Positionen")
        return TRPortfolio(positions: positions, cash: cash, updated: Date())
    }

    /// Erste Antwort je Thema. Ein Authentifizierungsfehler bricht alles ab, andere Fehler betreffen nur ihr Thema.
    private func request(_ web: TRWebSession, _ payloads: [[String: Any]]) async throws -> [Result<Any, Failure>] {
        guard !payloads.isEmpty else { return [] }
        return try await web.subscribe(payloads, locale: locale).map { code, payload in
            switch code {
            case "A":
                return TRProtocol.json(payload).map { .success($0) } ?? .failure(.invalidResponse)
            case "E":
                let error = TRProtocol.errorMessage(TRProtocol.json(payload))
                if error.code == "AUTHENTICATION_ERROR" || error.code == "UNAUTHORIZED" {
                    throw Failure.sessionExpired
                }
                return .failure(.server(error.message ?? error.code ?? payload))
            default:
                return .failure(.invalidResponse)
            }
        }
    }
}

/// Diagnose ohne Cookies, PIN oder Beträge: ~/Library/Logs/Tickado/TradeRepublic.log
enum TRLog {
    static func write(_ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tickado")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("TradeRepublic.log")
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            // Nicht endlos wachsen lassen.
            if (try? handle.seekToEnd()) ?? 0 > 500_000 { try? handle.truncate(atOffset: 0) }
            handle.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
}
