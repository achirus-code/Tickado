import Foundation
import WebKit

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

    /// Gewinn heute in Euro.
    var todayGain: Double? {
        guard let price, let previousClose else { return nil }
        return (price - previousClose) * quantity
    }

    /// Gewinn seit Kauf in Euro und Prozent (aus dem Ø-Kaufkurs).
    var totalGain: (amount: Double, percent: Double)? {
        guard let price, let averageBuyIn, averageBuyIn > 0 else { return nil }
        return ((price - averageBuyIn) * quantity, (price / averageBuyIn - 1) * 100)
    }
}

struct TRPortfolio {
    let positions: [TRPosition]
    let cash: Double?
    let updated: Date

    /// Depotwert ohne Guthaben (das Guthaben steht im Menü extra).
    var value: Double { positions.compactMap(\.value).reduce(0, +) }

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

    /// Kurzer Name in der Menüleiste: Δ = Veränderung heute, Σ = Summe seit Kauf (sprachunabhängig, kurz).
    var label: String {
        switch self {
        case .value: "TR"
        case .today: "TRΔ"
        case .total: "TRΣ"
        }
    }

    /// Als Pseudo-Wert, damit Ticker, Rotation und Vorschau ihn wie einen Kurs behandeln.
    var coin: Coin { Coin(id: rawValue, symbol: label, name: title, rank: nil, kind: .stock) }

    /// (Betrag, Prozent für Farbe und Anzeige, mit Vorzeichen?)
    func figures(in portfolio: TRPortfolio) -> (amount: Double?, percent: Double?, signed: Bool) {
        switch self {
        case .value: (portfolio.value, portfolio.change, false)
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

/// Gespeicherte Depotposition aus der letzten Synchronisierung. Kurse kommen laufend von Yahoo Finance (`symbol`).
struct TRHolding: Codable, Equatable {
    let isin: String
    var name: String
    let quantity: Double
    let averageBuyIn: Double?
    var symbol: String?
}

/// Depot bei Trade Republic. "Synchronisieren" meldet frisch auf der echten TR-Website an (`TRWebSession`),
/// holt die Positionen einmal aus der eingeloggten Seite und speichert sie; danach wird die Sitzung verworfen.
/// Die laufenden Kurse kommen von Yahoo Finance über die ISIN.
@MainActor
final class TradeRepublic {
    static let shared = TradeRepublic()

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

    private var web: TRWebSession?
    private var onFinished: ((Error?) -> Void)?
    private var fetching = false

    private init() {
        // Die Vorversion hielt die TR-Sitzung dauerhaft im WebKit-Speicher; diese Reste einmalig löschen.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "trLinked") != nil {
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                    modifiedSince: .distantPast) {}
            defaults.removeObject(forKey: "trLinked")
            defaults.removeObject(forKey: "trAccount")
            defaults.removeObject(forKey: "trUserAgent")
        }
    }

    var holdings: [TRHolding] { Prefs.shared.trHoldings }
    var lastSync: Date? { Prefs.shared.trSyncDate }
    var hasData: Bool { lastSync != nil }
    var isSyncing: Bool { web != nil }

    private var locale: String {
        Locale.preferredLanguages.first.flatMap { Locale.Language(identifier: $0).languageCode?.identifier } ?? "de"
    }

    /// Yahoo-Werte für die Kursabfrage (Kurse in Euro).
    var quoteCoins: [Coin] {
        Array(Set(holdings.compactMap(\.symbol))).sorted().map { Coin(stock: $0, name: $0) }
    }

    /// Depot aus den gespeicherten Positionen und den aktuellen Yahoo-Kursen.
    func portfolio(quotes: [String: Quote]) -> TRPortfolio? {
        guard hasData else { return nil }
        let priced = holdings.map { holding in (holding, holding.symbol.flatMap { quotes["stock:" + $0] }) }
        let positions = priced.map { holding, quote in
            TRPosition(isin: holding.isin, name: holding.name, quantity: holding.quantity, averageBuyIn: holding.averageBuyIn,
                       price: quote?.price,
                       previousClose: quote.flatMap { q in q.change24h.map { q.price / (1 + $0 / 100) } })
        }
        // Grau, sobald einer der Kurse veraltet ist; ohne Kurse gilt das Depot als veraltet.
        let updated = priced.compactMap { $0.1?.updated }.min() ?? .distantPast
        return TRPortfolio(positions: positions, cash: Prefs.shared.trCash, updated: updated)
    }

    // MARK: - Synchronisieren

    /// Öffnet die Anmeldeseite (immer frisch, nichts gespeichert). `onFinished` läuft nach dem Speichern,
    /// bei einem Fehler oder wenn das Fenster ohne Anmeldung geschlossen wird (dann ohne Fehler).
    func synchronize(onFinished: @escaping (Error?) -> Void) {
        self.onFinished = onFinished
        if web == nil {
            web = TRWebSession(
                onPage: { [weak self] onLoginPage in self?.pageChanged(onLoginPage: onLoginPage) },
                onClose: { [weak self] in self?.finish(nil, closeWindow: false) })
        }
        TRLog.write("Synchronisierung gestartet")
        web?.showLogin()
    }

    private func pageChanged(onLoginPage: Bool) {
        guard let web, !onLoginPage, !web.isLoading else { return }
        Task { await fetchAfterLogin(web) }
    }

    private func fetchAfterLogin(_ web: TRWebSession) async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        // Erst weiter, wenn die Seite angemeldet ist (Depotnummer abrufbar).
        guard let (status, json) = try? await web.fetchJSON("/api/v2/auth/account") else { return }
        TRLog.write("Prüfung /api/v2/auth/account → HTTP \(status)")
        guard status == 200 else { return }
        let account = (json as? [String: Any])?["securitiesAccountNumber"] as? String
        web.showStatus(L("Synchronizing…"))
        do {
            let (positions, cash) = try await loadPositions(from: web, account: account)
            // Yahoo-Symbole übernehmen, neue über die ISIN suchen.
            let known = Dictionary(holdings.map { ($0.isin, $0.symbol) }, uniquingKeysWith: { first, _ in first })
            var result = positions.map {
                TRHolding(isin: $0.isin, name: $0.name, quantity: $0.quantity, averageBuyIn: $0.averageBuyIn,
                          symbol: known[$0.isin] ?? nil)
            }
            let missing = result.indices.filter { result[$0].symbol == nil }
            await withTaskGroup(of: (Int, String?).self) { group in
                for index in missing {
                    let isin = result[index].isin
                    group.addTask { (index, await YahooFinance.symbol(forISIN: isin)) }
                }
                for await (index, symbol) in group { result[index].symbol = symbol }
            }
            Prefs.shared.trHoldings = result
            Prefs.shared.trCash = cash
            Prefs.shared.trSyncDate = Date()
            TRLog.write("Synchronisiert: \(result.count) Positionen, \(result.filter { $0.symbol == nil }.count) ohne Yahoo-Kurs")
            finish(nil, closeWindow: true)
        } catch {
            TRLog.write("Synchronisierung fehlgeschlagen: \(error.localizedDescription)")
            finish(error, closeWindow: true)
        }
    }

    private func finish(_ error: Error?, closeWindow: Bool) {
        guard let web else { return }
        self.web = nil
        if closeWindow { web.close() }
        onFinished?(error)
        onFinished = nil
    }

    /// Gespeicherte Positionen löschen.
    func removeData() {
        TRLog.write("Daten gelöscht")
        Prefs.shared.trHoldings = []
        Prefs.shared.trCash = nil
        Prefs.shared.trSyncDate = nil
    }

    // MARK: - Abruf aus der eingeloggten Seite

    private func loadPositions(from web: TRWebSession, account: String?) async throws
        -> (positions: [TRPosition], cash: Double?) {
        let portfolioRequest: [String: Any] = account.map { ["type": "compactPortfolioByType", "secAccNo": $0] }
            ?? ["type": "compactPortfolio"]
        guard case .success(let portfolio) = try await request(web, [portfolioRequest])[0] else {
            throw Failure.invalidResponse
        }
        var positions = TRProtocol.positions(from: portfolio)
        // Namen aus den Stammdaten, dazu das Guthaben
        let answers = try await request(web, positions.map { ["type": "instrument", "id": $0.isin] } + [["type": "cash"]])
        for index in positions.indices {
            if case .success(let json) = answers[index], let instrument = TRProtocol.instrument(from: json) {
                positions[index].name = instrument.name
            }
        }
        var cash: Double?
        if case .success(let json) = answers[positions.count] { cash = TRProtocol.cash(from: json) }
        return (positions, cash)
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
