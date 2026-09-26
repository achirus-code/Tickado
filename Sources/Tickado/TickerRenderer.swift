import AppKit

/// Zeichnet Ticker und Menüzeilen. Wird von der Menüleiste und von der Vorschau im Settings-Fenster genutzt.
@MainActor
struct TickerRenderer {
    let quotes: [String: Quote]
    let isStale: Bool

    private var prefs: Prefs { .shared }

    /// Aktien und ETFs mit festen 2 Nachkommastellen, sonst signifikante Stellen.
    func formattedPrice(_ quote: Quote, of coin: Coin, currencySign: Bool = true, abbreviate: Bool = false) -> String {
        let fixed = coin.kind.isListed && abs(quote.price) >= 1 ? 2 : nil
        return PriceFormat.price(quote.price, currency: prefs.baseCurrency, digits: prefs.precisionDigits,
                                 currencySign: currencySign, abbreviate: abbreviate, fixedDecimals: fixed)
    }

    func tickerTitle(for coins: [Coin]) -> NSAttributedString {
        // Etwas kleiner als die Menüleistenschrift (13 → 12,3 pt), pixelgenau wie das Vorbild.
        let size = NSFont.menuBarFont(ofSize: 0).pointSize - 0.7
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let green = NSFont.monospacedDigitSystemFont(ofSize: size - 0.5, weight: .regular)
        let small = NSFont.monospacedDigitSystemFont(ofSize: size - 2, weight: .regular)
        let stale = isStale

        let title = NSMutableAttributedString()
        for (index, coin) in coins.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "   ", attributes: [.font: font])) }

            let symbol = coin.displaySymbol
            let label = prefs.coinSigns ? (CoinSigns.sign(for: coin.id) ?? symbol) : symbol
            title.append(NSAttributedString(string: label + " ", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))

            guard let quote = quotes[coin.id] else {
                title.append(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                continue
            }
            let color = stale ? NSColor.secondaryLabelColor : prefs.colorTheme.color(for: quote.change24h)
            let priceFont = !stale && prefs.colorTheme.isGreen(for: quote.change24h) ? green : font
            // Nur Änderung: steht in voller Größe an der Stelle des Kurses
            let price = prefs.changeOnly
                ? quote.change24h.map(PriceFormat.change) ?? "—"
                : formattedPrice(quote, of: coin, currencySign: prefs.currencySign, abbreviate: prefs.abbreviate)
            title.append(NSAttributedString(string: price, attributes: [.font: priceFont, .foregroundColor: color]))

            if prefs.changeInBar, !prefs.changeOnly, let change = quote.change24h {
                title.append(NSAttributedString(string: " " + PriceFormat.change(change),
                                                attributes: [.font: small, .foregroundColor: color]))
            }
        }
        // Ganzen Ticker 1 px (0,5 pt @2x) tiefer setzen.
        title.addAttribute(.baselineOffset, value: -0.5, range: NSRange(location: 0, length: title.length))
        return title
    }

    /// Kompakte Ansicht: je zwei Werte untereinander, dahinter ▲/▼.
    /// Als Bild gezeichnet, weil ein Status-Button nur einzeilige Titel sauber darstellt.
    func stackedImage(for coins: [Coin]) -> NSImage {
        struct Line {
            let label: String
            let value: String
            let change: Double?
            let color: NSColor
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender)
        let height = max(NSStatusBar.system.thickness, lineHeight * 2)
        let stale = isStale

        let lines = coins.map { coin -> Line in
            let symbol = coin.displaySymbol
            let label = prefs.coinSigns ? (CoinSigns.sign(for: coin.id) ?? symbol) : symbol
            guard let quote = quotes[coin.id] else {
                return Line(label: label, value: "…", change: nil, color: .secondaryLabelColor)
            }
            var value: String
            if prefs.changeOnly {
                value = quote.change24h.map(PriceFormat.change) ?? "—"
            } else {
                value = formattedPrice(quote, of: coin, currencySign: prefs.currencySign, abbreviate: prefs.abbreviate)
                if prefs.changeInBar, let change = quote.change24h { value += " " + PriceFormat.change(change) }
            }
            let color = stale ? NSColor.secondaryLabelColor : prefs.colorTheme.color(for: quote.change24h)
            return Line(label: label, value: value, change: stale ? nil : quote.change24h, color: color)
        }
        let columns = stride(from: 0, to: lines.count, by: 2).map { Array(lines[$0..<min($0 + 2, lines.count)]) }

        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let labelGap: CGFloat = 3, arrowGap: CGFloat = 2, arrowWidth: CGFloat = 6, columnGap: CGFloat = 9
        let layouts = columns.map { column in
            (label: column.map { width($0.label) }.max() ?? 0, value: column.map { width($0.value) }.max() ?? 0)
        }
        let columnWidths = layouts.map { $0.label + labelGap + $0.value + arrowGap + arrowWidth }
        let totalWidth = columnWidths.reduce(0, +) + columnGap * CGFloat(max(columns.count - 1, 0))

        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: height), flipped: true) { _ in
            var x: CGFloat = 0
            let top = floor((height - lineHeight * 2) / 2)
            for (index, column) in columns.enumerated() {
                let layout = layouts[index]
                for (row, line) in column.enumerated() {
                    // Einzelner Wert in der letzten Spalte: vertikal zentriert
                    let y = column.count == 1 ? floor((height - lineHeight) / 2) : top + CGFloat(row) * lineHeight
                    (line.label as NSString).draw(at: NSPoint(x: x, y: y),
                                                  withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
                    let valueX = x + layout.label + labelGap + layout.value - width(line.value)
                    (line.value as NSString).draw(at: NSPoint(x: valueX, y: y),
                                                  withAttributes: [.font: font, .foregroundColor: line.color])

                    // Pfeil als Dreieck, mittig auf Höhe der Ziffern
                    guard let change = line.change, change != 0 else { continue }
                    let ax = x + layout.label + labelGap + layout.value + arrowGap
                    let midY = y + font.ascender - font.capHeight / 2
                    let arrow = NSBezierPath()
                    if change > 0 {
                        arrow.move(to: NSPoint(x: ax, y: midY + 2.5))
                        arrow.line(to: NSPoint(x: ax + arrowWidth, y: midY + 2.5))
                        arrow.line(to: NSPoint(x: ax + arrowWidth / 2, y: midY - 2.5))
                    } else {
                        arrow.move(to: NSPoint(x: ax, y: midY - 2.5))
                        arrow.line(to: NSPoint(x: ax + arrowWidth, y: midY - 2.5))
                        arrow.line(to: NSPoint(x: ax + arrowWidth / 2, y: midY + 2.5))
                    }
                    arrow.close()
                    line.color.setFill()
                    arrow.fill()
                }
                x += columnWidths[index] + columnGap
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = lines.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
        return image
    }

    /// "BTC   Bitcoin      84.150 $   +0.2%" in Monospace mit Tab-Spalten.
    func rowTitle(for coin: Coin) -> NSAttributedString {
        // Menlo 12 pt, kompakte Spalten: Name ab Zeichen 7, Preis rechtsbündig bis 28, Änderung bis 36.
        let font = NSFont(name: "Menlo-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let w = ("0" as NSString).size(withAttributes: [.font: font]).width
        let nameX = 7 * w
        let priceRight = 28 * w
        let changeRight = 36 * w

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .left, location: nameX),
            NSTextTab(textAlignment: .right, location: priceRight),
            NSTextTab(textAlignment: .right, location: changeRight),
        ]
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]

        let name = coin.kind == .metal ? "\(coin.displayName)/\(prefs.metalUnit.shortTitle)" : coin.displayName
        let price = quotes[coin.id].map { formattedPrice($0, of: coin) }
        // Name nur so lang, dass er nicht in die Preisspalte läuft.
        let nameLength = max(20 - (price?.count ?? 1), 6)
        let title = NSMutableAttributedString(
            string: "\(truncate(coin.displaySymbol, 6))\t\(truncate(name, nameLength))\t", attributes: base)

        guard let quote = quotes[coin.id], let price else {
            var dim = base
            dim[.foregroundColor] = NSColor.secondaryLabelColor
            title.append(NSAttributedString(string: "—", attributes: dim))
            return title
        }

        var colored = base
        colored[.foregroundColor] = isStale ? NSColor.secondaryLabelColor : prefs.colorTheme.color(for: quote.change24h)
        if !isStale, prefs.colorTheme.isGreen(for: quote.change24h) {
            colored[.font] = NSFont(name: "Menlo-Regular", size: 11.5) ?? font
        }
        title.append(NSAttributedString(string: price, attributes: colored))
        if prefs.showChange, let change = quote.change24h {
            title.append(NSAttributedString(string: "\t" + PriceFormat.change(change), attributes: colored))
        }
        return title
    }

    private func truncate(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }
}
