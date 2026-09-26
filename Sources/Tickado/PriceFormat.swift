import Foundation

@MainActor
enum PriceFormat {
    private static var decimalFormatters: [Int: NumberFormatter] = [:]
    private static var affixCache: [String: (prefix: String, suffix: String)] = [:]
    private static let cryptoSigns = ["btc": "₿", "eth": "Ξ"]

    /// Formatiert mit `digits` signifikanten Stellen, ohne Ganzzahlen abzuschneiden:
    /// 84150 → "84.150", 1.5312 → "1,53", 0.039812 → "0,0398" (bei 3 Stellen, deutsches Locale).
    static func price(_ value: Double, currency: String, digits: Int,
                      currencySign: Bool = true, abbreviate: Bool = false, fixedDecimals: Int? = nil) -> String {
        let text: String
        if abbreviate, abs(value) >= 1_000,
           let (factor, unit) = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")].first(where: { abs(value) >= $0.0 }) {
            // Kurz: höchstens eine Nachkommastelle, abgeschnitten (2.663 → 2,6K, 84.213 → 84,2K, 123.456 → 123K).
            let number = value / factor
            text = (abbreviationFormatter(decimals: abs(number) < 100 ? 1 : 0)
                .string(from: NSNumber(value: number)) ?? "\(number)") + unit
        } else {
            text = formatter(decimals: fixedDecimals ?? decimals(for: value, digits: digits))
                .string(from: NSNumber(value: value)) ?? "\(value)"
        }
        guard currencySign else { return text }
        let affix = affixes(for: currency)
        return affix.prefix + text + affix.suffix
    }

    /// "+0.2%" / "−0.8%"
    static func change(_ percent: Double) -> String {
        String(format: "%+.1f%%", percent).replacingOccurrences(of: "-", with: "−")
    }

    static func decimals(for value: Double, digits: Int) -> Int {
        guard value != 0, value.isFinite else { return 0 }
        let integerDigits = Int(floor(log10(abs(value)))) + 1
        return min(max(digits - integerDigits, 0), 12)
    }

    private static var abbreviationFormatters: [Int: NumberFormatter] = [:]

    private static func abbreviationFormatter(decimals: Int) -> NumberFormatter {
        if let f = abbreviationFormatters[decimals] { return f }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        f.roundingMode = .down
        abbreviationFormatters[decimals] = f
        return f
    }

    private static func formatter(decimals: Int) -> NumberFormatter {
        if let f = decimalFormatters[decimals] { return f }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        decimalFormatters[decimals] = f
        return f
    }

    /// Währungszeichen passend zum Locale platzieren ("84.150 $" vs. "$84,150").
    private static func affixes(for currency: String) -> (prefix: String, suffix: String) {
        if let cached = affixCache[currency] { return cached }
        let result: (prefix: String, suffix: String)
        if currency == "sats" {
            result = ("", "\u{00A0}sats")
        } else {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.locale = .current
            f.currencyCode = currency.uppercased()
            if let sign = cryptoSigns[currency] { f.currencySymbol = sign }
            result = (f.positivePrefix ?? "", f.positiveSuffix ?? "")
        }
        affixCache[currency] = result
        return result
    }
}
