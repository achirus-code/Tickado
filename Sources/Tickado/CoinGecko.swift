import Foundation

enum APIKeyKind: String {
    case demo, pro
}

enum CoinGeckoError: LocalizedError {
    case rateLimited, unauthorized, http(Int), invalidResponse

    var errorDescription: String? {
        switch self {
        case .rateLimited: L("CoinGecko rate limit reached. Add a free API key in Settings › General.")
        case .unauthorized: L("CoinGecko rejected the API key.")
        case .http(let code): L("CoinGecko returned HTTP %d.", code)
        case .invalidResponse: L("Unexpected response from CoinGecko.")
        }
    }
}

/// Minimaler Client für die CoinGecko API v3.
/// Ohne Key: öffentliche API. Demo-Key: gleiche URL + Header. Pro-Key: pro-api.coingecko.com.
struct CoinGecko {
    let apiKey: String?
    let keyKind: APIKeyKind

    @MainActor static var current: CoinGecko {
        CoinGecko(apiKey: Keychain.apiKey, keyKind: Prefs.shared.apiKeyKind)
    }

    struct Market: Decodable {
        let id: String
        let symbol: String
        let name: String
        let currentPrice: Double?
        let marketCapRank: Int?
        let priceChangePercentage24h: Double?

        // convertFromSnakeCase macht aus "price_change_percentage_24h" "priceChangePercentage24H".
        private enum CodingKeys: String, CodingKey {
            case id, symbol, name, currentPrice, marketCapRank
            case priceChangePercentage24h = "priceChangePercentage24H"
        }
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let symbol: String
            let name: String
            let marketCapRank: Int?
        }
        let coins: [Item]
    }

    private var baseURL: String {
        apiKey != nil && keyKind == .pro
            ? "https://pro-api.coingecko.com/api/v3"
            : "https://api.coingecko.com/api/v3"
    }

    /// Kurse für bestimmte Coins (ids) oder – ohne ids – die Top-Coins nach Market Cap.
    func markets(ids: [String]?, currency: String, page: Int = 1) async throws -> [Market] {
        var query = [
            URLQueryItem(name: "vs_currency", value: currency),
            URLQueryItem(name: "order", value: "market_cap_desc"),
            URLQueryItem(name: "per_page", value: "250"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sparkline", value: "false"),
            URLQueryItem(name: "precision", value: "full"),
        ]
        if let ids { query.append(URLQueryItem(name: "ids", value: ids.joined(separator: ","))) }
        return try await get("/coins/markets", query)
    }

    func search(_ text: String) async throws -> [Coin] {
        let response: SearchResponse = try await get("/search", [URLQueryItem(name: "query", value: text)])
        return response.coins.map { Coin(id: $0.id, symbol: $0.symbol, name: $0.name, rank: $0.marketCapRank) }
    }

    /// Prüft Erreichbarkeit und API-Key.
    func ping() async throws {
        struct Pong: Decodable {}
        let _: Pong = try await get("/ping", [])
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(string: baseURL + path)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: keyKind == .pro ? "x-cg-pro-api-key" : "x-cg-demo-api-key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoinGeckoError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 429: throw CoinGeckoError.rateLimited
        case 401, 403: throw CoinGeckoError.unauthorized
        default: throw CoinGeckoError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

/// Top-Coins für den Tab "Assets", einen Tag lang in Application Support gecacht.
@MainActor
enum CatalogStore {
    struct Cache: Codable {
        var date: Date
        var coins: [Coin]
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tickado", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.json")
    }

    static func load() -> Cache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    static func save(_ coins: [Coin]) {
        guard let data = try? JSONEncoder().encode(Cache(date: .now, coins: coins)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func fetch(_ client: CoinGecko, pages: Int = 2) async throws -> [Coin] {
        var coins: [Coin] = []
        for page in 1...pages {
            coins += try await client.markets(ids: nil, currency: "usd", page: page)
                .map { Coin(id: $0.id, symbol: $0.symbol, name: $0.name, rank: $0.marketCapRank) }
        }
        return coins
    }
}
