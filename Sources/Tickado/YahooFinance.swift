import Foundation

/// Kurse für Aktien und Edelmetalle über die (inoffizielle, schlüsselfreie) Yahoo-Finance-API.
enum YahooFinance {
    private static let base = "https://query1.finance.yahoo.com"
    // Nur unreservierte ASCII-Zeichen unkodiert lassen; `.urlQueryAllowed` lässt "&" und "+" durch ("S&P 500" → Suche nach "S").
    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    struct RawQuote {
        let price: Double
        let previousClose: Double?
        let currency: String
    }

    private struct ChartResponse: Decodable {
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable { let meta: Meta }
        struct Meta: Decodable {
            let regularMarketPrice: Double?
            let chartPreviousClose: Double?
            let previousClose: Double?
            let currency: String?
        }
        let chart: Chart
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let symbol: String
            let shortname: String?
            let longname: String?
            let quoteType: String?
        }
        let quotes: [Item]?
    }

    static func quote(_ symbol: String) async throws -> RawQuote {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["=", "^"])) ?? symbol
        let response: ChartResponse = try await get("/v8/finance/chart/\(encoded)?range=1d&interval=1d")
        guard let meta = response.chart.result?.first?.meta, let price = meta.regularMarketPrice else {
            throw CoinGeckoError.invalidResponse
        }
        return RawQuote(price: price, previousClose: meta.chartPreviousClose ?? meta.previousClose,
                        currency: meta.currency ?? "USD")
    }

    /// Aktien/Indizes bzw. ETFs nach Name, Tickersymbol oder ISIN suchen.
    static func search(_ text: String, kind: AssetKind) async throws -> [Coin] {
        let query = text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? text
        let response: SearchResponse = try await get("/v1/finance/search?q=\(query)&quotesCount=15&newsCount=0")
        let allowed: Set<String> = kind == .etf ? ["ETF"] : ["EQUITY", "INDEX", "MUTUALFUND"]
        return (response.quotes ?? []).compactMap { item in
            guard allowed.contains(item.quoteType ?? "") else { return nil }
            let name = (item.longname ?? item.shortname ?? item.symbol).trimmingCharacters(in: .whitespaces)
            return kind == .etf ? Coin(etf: item.symbol, name: name) : Coin(stock: item.symbol, name: name)
        }
    }

    /// Yahoo-Symbol zu einer ISIN. Mehrere Treffer: Euro-Börsenplätze zuerst (XETRA, Frankfurt …), damit die Kurse
    /// zu Trade Republic passen; sonst die Heimatbörse (wird in Euro umgerechnet).
    static func symbol(forISIN isin: String) async -> String? {
        let query = isin.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? isin
        guard let response: SearchResponse = try? await get("/v1/finance/search?q=\(query)&quotesCount=15&newsCount=0")
        else { return nil }
        let symbols = (response.quotes ?? []).map(\.symbol)
        for suffix in [".DE", ".F", ".SG", ".MU", ".DU", ".BE", ".HM", ".HA", ".VI", ".AS", ".PA", ".MI", ".MC", ".BR"] {
            if let symbol = symbols.first(where: { $0.hasSuffix(suffix) }) { return symbol }
        }
        return symbols.first
    }

    /// Kurse für Aktien/Edelmetalle holen und in die Basiswährung umrechnen.
    static func quotes(for assets: [Coin], currency: String, metalUnit: MetalUnit) async -> (quotes: [String: Quote], error: String?) {
        guard !assets.isEmpty else { return ([:], nil) }

        var raw: [String: RawQuote] = [:]
        var failed = 0
        await withTaskGroup(of: (String, RawQuote?).self) { group in
            for asset in assets {
                guard let symbol = asset.yahooSymbol else { continue }
                group.addTask { (asset.id, try? await quote(symbol)) }
            }
            for await (id, quote) in group {
                if let quote { raw[id] = quote } else { failed += 1 }
            }
        }

        let rates = await exchangeRates(from: Set(raw.values.map { normalized($0.currency).code }), to: currency)

        var result: [String: Quote] = [:]
        for asset in assets {
            guard let q = raw[asset.id] else { continue }
            let (code, divisor) = normalized(q.currency)
            guard let rate = rates[code] else { failed += 1; continue }
            let factor = rate / divisor * (asset.kind == .metal ? metalUnit.factor : 1)
            let change = q.previousClose.flatMap { $0 != 0 ? (q.price - $0) / $0 * 100 : nil }
            result[asset.id] = Quote(price: q.price * factor, change24h: change)
        }
        return (result, failed > 0 ? L("Yahoo Finance: prices unavailable: %d", failed) : nil)
    }

    /// Pence-Kurse (London "GBp", Tel Aviv "ILA", Johannesburg "ZAc") in die Hauptwährung umrechnen.
    private static func normalized(_ currency: String) -> (code: String, divisor: Double) {
        switch currency {
        case "GBp", "GBX": ("GBP", 100)
        case "ILA": ("ILS", 100)
        case "ZAc": ("ZAR", 100)
        default: (currency.uppercased(), 1)
        }
    }

    /// Wechselkurse Fiat → Basiswährung, alle gleichzeitig abgefragt. BTC/ETH/sats laufen über USD,
    /// BTC-USD bzw. ETH-USD wird dabei nur einmal geholt. Fehlt ein Kurs, fehlt die Quellwährung im Ergebnis.
    private static func exchangeRates(from sources: Set<String>, to target: String) async -> [String: Double] {
        guard !sources.isEmpty else { return [:] }
        let crypto: [String: (symbol: String, multiplier: Double)] = [
            "btc": ("BTC-USD", 1), "eth": ("ETH-USD", 1), "sats": ("BTC-USD", 100_000_000),
        ]
        let viaCrypto = crypto[target]
        let fiat = viaCrypto == nil ? target.uppercased() : "USD"

        var symbols = Set(sources.filter { $0 != fiat }.map { "\($0)\(fiat)=X" })
        if let viaCrypto { symbols.insert(viaCrypto.symbol) }
        var prices: [String: Double] = [:]
        await withTaskGroup(of: (String, Double?).self) { group in
            for symbol in symbols {
                group.addTask { (symbol, try? await quote(symbol).price) }
            }
            for await (symbol, price) in group {
                if let price { prices[symbol] = price }
            }
        }

        var rates: [String: Double] = [:]
        for source in sources {
            let toFiat: Double? = source == fiat ? 1 : prices["\(source)\(fiat)=X"]
            guard let toFiat else { continue }
            if let viaCrypto {
                guard let cryptoUSD = prices[viaCrypto.symbol], cryptoUSD > 0 else { continue }
                rates[source] = toFiat / cryptoUSD * viaCrypto.multiplier
            } else {
                rates[source] = toFiat
            }
        }
        return rates
    }

    private static func get<T: Decodable>(_ pathAndQuery: String) async throws -> T {
        guard let url = URL(string: base + pathAndQuery) else { throw CoinGeckoError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        // Ohne (einfachen) User-Agent blockt Yahoo die Anfrage.
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoinGeckoError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 429 ? CoinGeckoError.rateLimited : CoinGeckoError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
