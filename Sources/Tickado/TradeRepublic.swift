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

    /// Tagesänderung des ganzen Depots, gewichtet über die Positionen mit Vortageskurs.
    var change: Double? {
        let priced = positions.filter { $0.price != nil && ($0.previousClose ?? 0) > 0 }
        let before = priced.reduce(0) { $0 + $1.previousClose! * $1.quantity }
        guard before > 0 else { return nil }
        let now = priced.reduce(0) { $0 + $1.price! * $1.quantity }
        return (now / before - 1) * 100
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
/// Login mit Handynummer + PIN, bestätigt per Push in der TR-App oder per Code aus einer Authenticator-App.
/// Danach reichen die Session-Cookies; sie liegen im Schlüsselbund. Die PIN wird nicht gespeichert.
@MainActor
final class TradeRepublic {
    static let shared = TradeRepublic()

    enum State {
        case loggedOut, connected, expired
    }

    enum Failure: LocalizedError {
        case sessionExpired, timeout, invalidResponse, loginTimeout
        case server(String)

        var errorDescription: String? {
            switch self {
            case .sessionExpired: L("Session expired. Please log in again.")
            case .timeout: L("Trade Republic did not respond.")
            case .invalidResponse: L("Unexpected response from Trade Republic.")
            case .loginTimeout: L("Login timed out. Please try again.")
            case .server(let message): message
            }
        }
    }

    struct LoginProcess {
        let id: String
        let deadline: Date
        let needsCode: Bool
    }

    private static let host = "https://api.traderepublic.com"
    private static let appVersion = "2.2631.13"
    private static let browserVersion = "146.0.0.0"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/\(browserVersion) Safari/537.36"
    private static let keychainAccount = "traderepublic-session"

    private let session: URLSession
    private let cookies: HTTPCookieStorage
    private(set) var state: State = .loggedOut
    private var sessionRefreshed = Date.distantPast
    private var instruments: [String: TRProtocol.Instrument] = [:]

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        config.timeoutIntervalForRequest = 20
        cookies = config.httpCookieStorage ?? HTTPCookieStorage.shared
        session = URLSession(configuration: config)
        if restoreCookies() { state = .connected }
    }

    private var locale: String {
        Locale.preferredLanguages.first.flatMap { Locale.Language(identifier: $0).languageCode?.identifier } ?? "de"
    }

    // MARK: - Login

    func startLogin(phone: String, pin: String) async throws -> LoginProcess {
        let body = try JSONSerialization.data(withJSONObject: ["phoneNumber": phone, "pin": pin])
        let started = try await request("POST", "/api/v2/auth/web/login", body: body, login: true)
        guard let id = started["processId"] as? String else { throw Failure.invalidResponse }
        let countdown = TRProtocol.number(started["countdownInSeconds"]) ?? 120
        let process = try await request("GET", "/api/v2/auth/web/login/processes/\(id)", login: true)
        return LoginProcess(id: id, deadline: Date(timeIntervalSinceNow: countdown + 1),
                            needsCode: process["requiredAction"] as? String == "AUTHENTICATOR_VERIFICATION")
    }

    func submitCode(_ code: String, for process: LoginProcess) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        _ = try await request("POST", "/api/v2/auth/web/login/processes/\(process.id)/authenticator-verification",
                              body: body, login: true)
    }

    /// Wartet, bis der Login in der App bestätigt ist; danach gelten die Session-Cookies.
    func awaitConfirmation(_ process: LoginProcess) async throws {
        while true {
            let status = try await request("GET", "/api/v2/auth/web/login/processes/\(process.id)", login: true)["status"]
            switch status as? String {
            case "CONFIRMED", "COMPLETED":
                try await finishLogin()
                return
            case "PENDING", nil:
                guard Date() < process.deadline else { throw Failure.loginTimeout }
                try await Task.sleep(for: .seconds(2))
            case let other?:
                throw Failure.server(L("Login failed: %@", other))
            }
        }
    }

    private func finishLogin() async throws {
        sessionRefreshed = Date()
        // Depotnummer für compactPortfolioByType; ohne sie bleibt das ältere compactPortfolio.
        let account = try? await request("GET", "/api/v2/auth/account")
        Prefs.shared.trAccount = account?["securitiesAccountNumber"] as? String
        instruments = [:]
        state = .connected
        saveCookies()
    }

    func logOut() {
        for cookie in cookies.cookies ?? [] { cookies.deleteCookie(cookie) }
        Keychain.setData(nil, for: Self.keychainAccount)
        Prefs.shared.trAccount = nil
        state = .loggedOut
    }

    private func expire() {
        for cookie in cookies.cookies ?? [] { cookies.deleteCookie(cookie) }
        Keychain.setData(nil, for: Self.keychainAccount)
        state = .expired
    }

    // MARK: - Depot

    func fetchPortfolio() async throws -> TRPortfolio {
        guard state == .connected else { throw Failure.sessionExpired }
        do {
            try await refreshSessionIfNeeded()
            let socket = TRSocket(session: session, cookies: cookies.cookies(for: URL(string: Self.host)!) ?? [])
            // Hängt die Verbindung, beendet der Wächter sie; receive() wirft dann.
            let watchdog = Task { [socket] in
                try await Task.sleep(for: .seconds(25))
                socket.cancel(timedOut: true)
            }
            defer {
                watchdog.cancel()
                socket.cancel(timedOut: false)
            }
            do {
                return try await load(from: socket)
            } catch where socket.timedOut {
                throw Failure.timeout
            }
        } catch Failure.sessionExpired {
            expire()
            throw Failure.sessionExpired
        }
    }

    private func load(from socket: TRSocket) async throws -> TRPortfolio {
        try await socket.connect(locale: locale)
        let portfolioRequest: [String: Any] = Prefs.shared.trAccount.map { ["type": "compactPortfolioByType", "secAccNo": $0] }
            ?? ["type": "compactPortfolio"]
        guard case .success(let portfolio) = try await socket.request([portfolioRequest])[0] else {
            throw Failure.invalidResponse
        }
        var positions = TRProtocol.positions(from: portfolio)

        // Stammdaten (Name, Börse) nur einmal je Wertpapier holen.
        let missing = Array(Set(positions.map(\.isin)).filter { instruments[$0] == nil })
        let details = try await socket.request(missing.map { ["type": "instrument", "id": $0] })
        for (isin, result) in zip(missing, details) {
            if case .success(let json) = result, let instrument = TRProtocol.instrument(from: json) {
                instruments[isin] = instrument
            }
        }

        let tickers = positions.map { ["type": "ticker", "id": "\($0.isin).\(instruments[$0.isin]?.exchange ?? "LSX")"] }
        let answers = try await socket.request(tickers + [["type": "cash"]])
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
        return TRPortfolio(positions: positions, cash: cash, updated: Date())
    }

    // MARK: - HTTP

    /// Die Web-Session läuft nach wenigen Minuten ab und wird vorher erneuert (wie pytr: nach knapp 5 Minuten).
    private func refreshSessionIfNeeded() async throws {
        guard Date().timeIntervalSince(sessionRefreshed) > 240 else { return }
        _ = try await request("GET", "/api/v1/auth/web/session")
        sessionRefreshed = Date()
        saveCookies()
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, login: Bool = false) async throws
        -> [String: Any] {
        guard let url = URL(string: Self.host + path) else { throw Failure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(locale, forHTTPHeaderField: "Accept-Language")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if login {
            request.setValue(deviceInfo, forHTTPHeaderField: "X-TR-Device-Info")
            request.setValue(Self.appVersion, forHTTPHeaderField: "X-TR-App-Version")
            request.setValue("web-pro", forHTTPHeaderField: "X-Tr-Platform")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        let json = try? JSONSerialization.jsonObject(with: data)
        switch http.statusCode {
        case 200..<300:
            return json as? [String: Any] ?? [:]
        case 401 where !login, 403 where !login:
            throw Failure.sessionExpired
        case 426:
            throw Failure.server(L("Trade Republic has changed its login. Tickado needs an update."))
        default:
            let error = TRProtocol.errorMessage(json)
            throw Failure.server(error.message ?? error.code ?? L("Trade Republic returned HTTP %d.", http.statusCode))
        }
    }

    /// Geräteangaben wie im Browser; die Geräte-ID bleibt pro Installation gleich.
    private var deviceInfo: String {
        let prefs = Prefs.shared
        let deviceID = prefs.trDeviceID ?? {
            let id = (0..<64).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            prefs.trDeviceID = id
            return id
        }()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info: [String: Any] = [
            "stableDeviceId": deviceID,
            "browser": "Chrome",
            "browserVersion": Self.browserVersion,
            "os": "Mac OS",
            "osVersion": "\(os.majorVersion).\(os.minorVersion)",
            "timezone": TimeZone.current.identifier,
            "timezoneOffset": -TimeZone.current.secondsFromGMT() / 60,
            "screen": "1920x1080x24",
            "preferredLanguages": [locale],
            "numberOfCores": ProcessInfo.processInfo.activeProcessorCount,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
        return data.base64EncodedString()
    }

    // MARK: - Cookies im Schlüsselbund

    private func saveCookies() {
        let list = (cookies.cookies ?? []).map { cookie in
            Dictionary(uniqueKeysWithValues: (cookie.properties ?? [:]).map { ($0.key.rawValue, $0.value) })
        }
        let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        Keychain.setData(list.isEmpty ? nil : data, for: Self.keychainAccount)
    }

    private func restoreCookies() -> Bool {
        guard let data = Keychain.data(for: Self.keychainAccount),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return false }
        let restored = list.compactMap { properties in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
        for cookie in restored { cookies.setCookie(cookie) }
        return !restored.isEmpty
    }
}

/// Eine WebSocket-Verbindung für eine Abfrage: verbinden, Themen abonnieren, erste Antworten einsammeln.
@MainActor
private final class TRSocket {
    private let task: URLSessionWebSocketTask
    private var nextID = 1
    private var previous: [Int: String] = [:]
    private(set) var timedOut = false

    init(session: URLSession, cookies: [HTTPCookie]) {
        var request = URLRequest(url: URL(string: "wss://api.traderepublic.com")!)
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func cancel(timedOut: Bool) {
        if timedOut { self.timedOut = true }
        task.cancel(with: .normalClosure, reason: nil)
    }

    func connect(locale: String) async throws {
        let info: [String: Any] = [
            "locale": locale, "platformId": "webtrading", "platformVersion": "chrome - 146.0.0",
            "clientId": "app.traderepublic.com", "clientVersion": "5582",
        ]
        try await send("connect 31 " + Self.json(info))
        guard try await receive().hasPrefix("connected") else { throw TradeRepublic.Failure.invalidResponse }
    }

    /// Abonniert alle Themen und liefert je Thema die erste Antwort (danach wird wieder abbestellt).
    /// Ein Authentifizierungsfehler bricht alles ab, andere Fehler betreffen nur ihr Thema.
    func request(_ payloads: [[String: Any]]) async throws -> [Result<Any, TradeRepublic.Failure>] {
        guard !payloads.isEmpty else { return [] }
        var ids: [Int] = []
        for payload in payloads {
            let id = nextID
            nextID += 1
            ids.append(id)
            try await send("sub \(id) " + Self.json(payload))
        }
        var results: [Int: Result<Any, TradeRepublic.Failure>] = [:]
        while results.count < ids.count {
            guard let message = TRProtocol.parse(try await receive()), ids.contains(message.id),
                  results[message.id] == nil else { continue }
            switch message.code {
            case "A":
                previous[message.id] = message.payload
                results[message.id] = TRProtocol.json(message.payload).map { .success($0) } ?? .failure(.invalidResponse)
            case "D":
                let full = TRProtocol.applyDelta(message.payload, to: previous[message.id] ?? "")
                previous[message.id] = full
                results[message.id] = TRProtocol.json(full).map { .success($0) } ?? .failure(.invalidResponse)
            case "E":
                let error = TRProtocol.errorMessage(TRProtocol.json(message.payload))
                if error.code == "AUTHENTICATION_ERROR" || error.code == "UNAUTHORIZED" {
                    throw TradeRepublic.Failure.sessionExpired
                }
                results[message.id] = .failure(.server(error.message ?? error.code ?? message.payload))
            default:
                results[message.id] = .failure(.invalidResponse)
            }
        }
        for id in ids { try? await send("unsub \(id)") }
        return ids.map { results[$0]! }
    }

    private func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    private func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
