import Foundation

/// Kurse für Aktien und Edelmetalle über die (inoffizielle, schlüsselfreie) Yahoo-Finance-API.
enum YahooFinance {
    private static let base = "https://query1.finance.yahoo.com"

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
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let response: SearchResponse = try await get("/v1/finance/search?q=\(query)&quotesCount=15&newsCount=0")
        let allowed: Set<String> = kind == .etf ? ["ETF"] : ["EQUITY", "INDEX", "MUTUALFUND"]
        return (response.quotes ?? []).compactMap { item in
            guard allowed.contains(item.quoteType ?? "") else { return nil }
            let name = (item.longname ?? item.shortname ?? item.symbol).trimmingCharacters(in: .whitespaces)
            return kind == .etf ? Coin(etf: item.symbol, name: name) : Coin(stock: item.symbol, name: name)
        }
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

        // Benötigte Wechselkurse einmal pro Quellwährung abfragen.
        var rates: [String: Double] = [:]
        for source in Set(raw.values.map { normalized($0.currency).code }) {
            rates[source] = await rate(from: source, to: currency)
        }

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

    /// Wechselkurs Fiat → Basiswährung (auch BTC/ETH/sats).
    private static func rate(from source: String, to target: String) async -> Double? {
        let crypto: [String: (symbol: String, multiplier: Double)] = [
            "btc": ("BTC-USD", 1), "eth": ("ETH-USD", 1), "sats": ("BTC-USD", 100_000_000),
        ]
        if let (symbol, multiplier) = crypto[target] {
            guard let toUSD = await rate(from: source, to: "usd"),
                  let cryptoUSD = try? await quote(symbol).price, cryptoUSD > 0 else { return nil }
            return toUSD / cryptoUSD * multiplier
        }
        let targetCode = target.uppercased()
        if source == targetCode { return 1 }
        return try? await quote("\(source)\(targetCode)=X").price
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
