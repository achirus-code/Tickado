import AppKit

enum AssetKind: String, Codable, CaseIterable {
    case crypto, stock, etf, metal

    var title: String {
        switch self {
        case .crypto: L("Crypto")
        case .stock: L("Stocks")
        case .etf: L("ETFs")
        case .metal: L("Metals")
        }
    }

    /// Yahoo-Finance-Werte mit "prefix:SYMBOL"-IDs.
    var isListed: Bool { self == .stock || self == .etf }
}

/// Ein Kurs-Wert: Kryptowährung, Aktie oder Edelmetall.
struct Coin: Codable, Hashable {
    let id: String          // CoinGecko-ID ("bitcoin"), "stock:SAP.DE", "etf:EUNL.DE" oder "metal:gold"
    var symbol: String      // z. B. "btc", "SAP.DE", "XAU"
    var name: String
    var rank: Int?          // Market-Cap-Rang bzw. Reihenfolge
    var kind: AssetKind = .crypto

    init(id: String, symbol: String, name: String, rank: Int?, kind: AssetKind = .crypto) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.rank = rank
        self.kind = kind
    }

    init(stock symbol: String, name: String, rank: Int? = nil) {
        self.init(id: "stock:" + symbol, symbol: symbol, name: name, rank: rank, kind: .stock)
    }

    init(etf symbol: String, name: String, rank: Int? = nil) {
        self.init(id: "etf:" + symbol, symbol: symbol, name: name, rank: rank, kind: .etf)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        symbol = try c.decode(String.self, forKey: .symbol)
        name = try c.decode(String.self, forKey: .name)
        rank = try c.decodeIfPresent(Int.self, forKey: .rank)
        // Ältere Einstellungen kennen nur Kryptowährungen.
        kind = try c.decodeIfPresent(AssetKind.self, forKey: .kind) ?? .crypto
    }

    /// Symbol für Yahoo Finance (Aktien und Edelmetall-Futures).
    var yahooSymbol: String? {
        switch kind {
        case .crypto: nil
        case .stock, .etf: id.split(separator: ":", maxSplits: 1).last.map(String.init)
        case .metal: Metal.all.first { $0.coin.id == id }?.yahooSymbol
        }
    }

    var webURL: URL? {
        switch kind {
        case .crypto: URL(string: "https://www.coingecko.com/en/coins/\(id)")
        case .stock, .etf, .metal: yahooSymbol.flatMap { URL(string: "https://finance.yahoo.com/quote/\($0)") }
        }
    }

    /// Anzeige-Symbol: "BTC", "SAP.DE", "GDAXI"
    var displaySymbol: String {
        kind.isListed ? (symbol.hasPrefix("^") ? String(symbol.dropFirst()) : symbol) : symbol.uppercased()
    }

    var sourceName: String { kind == .crypto ? "CoinGecko" : "Yahoo Finance" }

    /// Name für die Oberfläche; nur Edelmetalle werden übersetzt.
    var displayName: String { kind == .metal ? L(name) : name }

    static let popularStocks: [Coin] = [
        ("AAPL", "Apple"), ("MSFT", "Microsoft"), ("NVDA", "NVIDIA"), ("GOOGL", "Alphabet"),
        ("AMZN", "Amazon"), ("META", "Meta Platforms"), ("TSLA", "Tesla"), ("BRK-B", "Berkshire Hathaway"),
        ("JPM", "JPMorgan Chase"), ("V", "Visa"), ("NFLX", "Netflix"), ("AMD", "AMD"),
        ("SAP.DE", "SAP"), ("SIE.DE", "Siemens"), ("ALV.DE", "Allianz"), ("DTE.DE", "Deutsche Telekom"),
        ("RHM.DE", "Rheinmetall"), ("AIR.DE", "Airbus"), ("MBG.DE", "Mercedes-Benz Group"), ("BMW.DE", "BMW"),
        ("VOW3.DE", "Volkswagen"), ("BAS.DE", "BASF"), ("IFX.DE", "Infineon"), ("DBK.DE", "Deutsche Bank"),
        ("ADS.DE", "Adidas"), ("^GDAXI", "DAX"), ("^GSPC", "S&P 500"), ("^NDX", "Nasdaq 100"),
    ].enumerated().map { Coin(stock: $1.0, name: $1.1, rank: $0 + 1) }

    static let popularETFs: [Coin] = [
        ("EUNL.DE", "iShares Core MSCI World"), ("VWCE.DE", "Vanguard FTSE All-World"),
        ("XDWD.DE", "Xtrackers MSCI World"), ("SXR8.DE", "iShares Core S&P 500"),
        ("VUSA.DE", "Vanguard S&P 500"), ("EQQQ.DE", "Invesco Nasdaq-100"),
        ("EXS1.DE", "iShares Core DAX"), ("IS3N.DE", "iShares Core MSCI EM IMI"),
        ("SPY", "SPDR S&P 500"), ("VOO", "Vanguard S&P 500 (US)"), ("QQQ", "Invesco QQQ"),
        ("VTI", "Vanguard Total Stock Market"), ("VT", "Vanguard Total World"), ("GLD", "SPDR Gold Shares"),
    ].enumerated().map { Coin(etf: $1.0, name: $1.1, rank: $0 + 1) }

    static let defaults: [Coin] = [
        Coin(id: "bitcoin", symbol: "btc", name: "Bitcoin", rank: 1),
        Coin(id: "ethereum", symbol: "eth", name: "Ethereum", rank: 2),
        Coin(id: "ripple", symbol: "xrp", name: "XRP", rank: 4),
        Coin(id: "solana", symbol: "sol", name: "Solana", rank: 6),
        Coin(id: "chainlink", symbol: "link", name: "Chainlink", rank: 14),
        Coin(id: "sui", symbol: "sui", name: "Sui", rank: 25),
        Coin(id: "kaspa", symbol: "kas", name: "Kaspa", rank: 40),
    ]
}

struct Metal {
    let coin: Coin
    let sign: String          // Elementsymbol für die Menüleiste
    let yahooSymbol: String   // COMEX/NYMEX-Future (Preis je Feinunze)

    static let all: [Metal] = [
        Metal(coin: Coin(id: "metal:gold", symbol: "XAU", name: "Gold", rank: 1, kind: .metal), sign: "Au", yahooSymbol: "GC=F"),
        Metal(coin: Coin(id: "metal:silver", symbol: "XAG", name: "Silver", rank: 2, kind: .metal), sign: "Ag", yahooSymbol: "SI=F"),
        Metal(coin: Coin(id: "metal:platinum", symbol: "XPT", name: "Platinum", rank: 3, kind: .metal), sign: "Pt", yahooSymbol: "PL=F"),
        Metal(coin: Coin(id: "metal:palladium", symbol: "XPD", name: "Palladium", rank: 4, kind: .metal), sign: "Pd", yahooSymbol: "PA=F"),
    ]
}

enum MetalUnit: String, CaseIterable {
    case troyOunce, gram, kilogram

    var title: String {
        switch self {
        case .troyOunce: L("Troy Ounce (oz t)")
        case .gram: L("Gram (g)")
        case .kilogram: L("Kilogram (kg)")
        }
    }

    var shortTitle: String {
        switch self {
        case .troyOunce: "oz"
        case .gram: "g"
        case .kilogram: "kg"
        }
    }

    /// Umrechnung vom Preis je Feinunze.
    var factor: Double {
        switch self {
        case .troyOunce: 1
        case .gram: 1 / 31.1034768
        case .kilogram: 1000 / 31.1034768
        }
    }
}

struct Quote {
    let price: Double
    let change24h: Double?
}

/// Währungszeichen für die Menüleiste (₿ 84.213  Ξ 2.676).
enum CoinSigns {
    private static let byID = [
        "bitcoin": "₿", "ethereum": "Ξ", "litecoin": "Ł", "dogecoin": "Ð",
        "cardano": "₳", "tether": "₮", "monero": "ɱ", "tezos": "ꜩ",
    ]

    static func sign(for id: String) -> String? {
        byID[id] ?? Metal.all.first { $0.coin.id == id }?.sign
    }
}

struct BaseCurrency {
    let code: String
    let name: String

    /// Währungsname in der Sprache der Oberfläche (Krypto-Einheiten bleiben wie sie sind).
    var displayName: String {
        guard !["btc", "eth", "sats"].contains(code),
              let localized = L10n.locale.localizedString(forCurrencyCode: code.uppercased()) else { return name }
        return localized.prefix(1).uppercased(with: L10n.locale) + localized.dropFirst()
    }

    static let all: [BaseCurrency] = [
        .init(code: "usd", name: "US Dollar"),
        .init(code: "eur", name: "Euro"),
        .init(code: "gbp", name: "British Pound"),
        .init(code: "chf", name: "Swiss Franc"),
        .init(code: "jpy", name: "Japanese Yen"),
        .init(code: "cad", name: "Canadian Dollar"),
        .init(code: "aud", name: "Australian Dollar"),
        .init(code: "cny", name: "Chinese Yuan"),
        .init(code: "inr", name: "Indian Rupee"),
        .init(code: "krw", name: "South Korean Won"),
        .init(code: "brl", name: "Brazilian Real"),
        .init(code: "sek", name: "Swedish Krona"),
        .init(code: "nok", name: "Norwegian Krone"),
        .init(code: "pln", name: "Polish Złoty"),
        .init(code: "try", name: "Turkish Lira"),
        .init(code: "btc", name: "Bitcoin"),
        .init(code: "eth", name: "Ether"),
        .init(code: "sats", name: "Satoshis"),
    ]
}

enum TickerMode: String {
    case all, rotate
    /// Je zwei Werte untereinander mit ▲/▼, weitere Paare als Spalten daneben.
    case stacked
}

enum ColorTheme: String, CaseIterable {
    case greenRed, redGreen, blueOrange, monochrome

    var title: String {
        switch self {
        case .greenRed: L("Green Up / Red Down")
        case .redGreen: L("Red Up / Green Down")
        case .blueOrange: L("Blue Up / Orange Down (Color Blind)")
        case .monochrome: L("Monochrome")
        }
    }

    /// Grün wirkt heller und damit größer als Rot; grüne Kurse werden daher etwas kleiner gesetzt.
    func isGreen(for change: Double?) -> Bool {
        guard let change, change != 0 else { return false }
        switch self {
        case .greenRed: return change > 0
        case .redGreen: return change < 0
        case .blueOrange, .monochrome: return false
        }
    }

    func color(for change: Double?) -> NSColor {
        guard let change, change != 0 else { return .labelColor }
        let up = change > 0
        switch self {
        case .greenRed: return up ? .tickerGreen : .tickerRed
        case .redGreen: return up ? .tickerRed : .tickerGreen
        case .blueOrange: return up ? .systemBlue : .systemOrange
        case .monochrome: return .labelColor
        }
    }
}

extension NSColor {
    /// Display P3 #74C73D (dunkel); im hellen Modus dunkler für Kontrast.
    static var tickerGreen: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(displayP3Red: 0x74 / 255, green: 0xC7 / 255, blue: 0x3D / 255, alpha: 1)
                : NSColor(displayP3Red: 0x3A / 255, green: 0x8A / 255, blue: 0x1C / 255, alpha: 1)
        }
    }

    /// Display P3 #C04828 (dunkel); im hellen Modus etwas dunkler für Kontrast.
    static var tickerRed: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(displayP3Red: 0xC0 / 255, green: 0x48 / 255, blue: 0x28 / 255, alpha: 1)
                : NSColor(displayP3Red: 0xB0 / 255, green: 0x36 / 255, blue: 0x18 / 255, alpha: 1)
        }
    }
}
