import Foundation

/// Einstellungen in UserDefaults.
@MainActor
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "baseCurrency": "usd",
            "colorTheme": ColorTheme.greenRed.rawValue,
            "showChange": true,
            "precisionDigits": 3,
            "tickerMode": TickerMode.all.rawValue,
            "coinSigns": true,
            "currencySign": false,
            "changeInBar": false,
            "changeOnly": false,
            "abbreviate": false,
            "refreshInterval": 60,
            "apiKeyKind": APIKeyKind.demo.rawValue,
            "tickerIDs": ["bitcoin", "ethereum"],
        ])
        L10n.apply(language)
    }

    /// Sprache der Oberfläche; nil = wie das System.
    var language: String? {
        get { d.string(forKey: "language") }
        set {
            d.set(newValue, forKey: "language")
            L10n.apply(newValue)
        }
    }

    /// Im Menü angezeigte Coins (Tab "Assets").
    var selectedCoins: [Coin] {
        get {
            guard let data = d.data(forKey: "selectedCoins"),
                  let coins = try? JSONDecoder().decode([Coin].self, from: data) else { return Coin.defaults }
            return coins
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "selectedCoins") }
    }

    /// In der Menüleiste angezeigte Coins (Häkchen im Menü).
    var tickerIDs: [String] {
        get { d.stringArray(forKey: "tickerIDs") ?? [] }
        set { d.set(newValue, forKey: "tickerIDs") }
    }

    var baseCurrency: String {
        get { d.string(forKey: "baseCurrency") ?? "usd" }
        set { d.set(newValue, forKey: "baseCurrency") }
    }

    var colorTheme: ColorTheme {
        get { ColorTheme(rawValue: d.string(forKey: "colorTheme") ?? "") ?? .greenRed }
        set { d.set(newValue.rawValue, forKey: "colorTheme") }
    }

    var showChange: Bool {
        get { d.bool(forKey: "showChange") }
        set { d.set(newValue, forKey: "showChange") }
    }

    /// Signifikante Stellen (84.150 · 1,53 · 0,0398 bei 3).
    var precisionDigits: Int {
        get { d.integer(forKey: "precisionDigits") }
        set { d.set(newValue, forKey: "precisionDigits") }
    }

    var tickerMode: TickerMode {
        get { TickerMode(rawValue: d.string(forKey: "tickerMode") ?? "") ?? .all }
        set { d.set(newValue.rawValue, forKey: "tickerMode") }
    }

    var coinSigns: Bool {
        get { d.bool(forKey: "coinSigns") }
        set { d.set(newValue, forKey: "coinSigns") }
    }

    var currencySign: Bool {
        get { d.bool(forKey: "currencySign") }
        set { d.set(newValue, forKey: "currencySign") }
    }

    var changeInBar: Bool {
        get { d.bool(forKey: "changeInBar") }
        set { d.set(newValue, forKey: "changeInBar") }
    }

    /// Menüleiste zeigt nur die 24h-Änderung, keinen Kurs.
    var changeOnly: Bool {
        get { d.bool(forKey: "changeOnly") }
        set { d.set(newValue, forKey: "changeOnly") }
    }

    var abbreviate: Bool {
        get { d.bool(forKey: "abbreviate") }
        set { d.set(newValue, forKey: "abbreviate") }
    }

    /// Sekunden zwischen zwei Abfragen.
    var refreshInterval: Int {
        get { max(d.integer(forKey: "refreshInterval"), 15) }
        set { d.set(newValue, forKey: "refreshInterval") }
    }

    var metalUnit: MetalUnit {
        get { MetalUnit(rawValue: d.string(forKey: "metalUnit") ?? "") ?? .troyOunce }
        set { d.set(newValue.rawValue, forKey: "metalUnit") }
    }

    var apiKeyKind: APIKeyKind {
        get { APIKeyKind(rawValue: d.string(forKey: "apiKeyKind") ?? "") ?? .demo }
        set { d.set(newValue.rawValue, forKey: "apiKeyKind") }
    }
}
