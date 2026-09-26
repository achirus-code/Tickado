import AppKit

/// Menüleisten-Ticker, Menü und periodische Kursabfrage.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let prefs = Prefs.shared

    private var quotes: [String: Quote] = [:]
    private var lastUpdate: Date?
    private var lastError: String?

    private var refreshTimer: Timer?
    private var rotationTimer: Timer?
    private var rotationIndex = 0
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?

    private var coinRows: [String: NSMenuItem] = [:]
    private var settings: SettingsWindowController?

    override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.autosaveName = "Tickado"
        statusItem.button?.imagePosition = .imageLeading

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        restartTimers()
        updateTitle()
        refresh()
    }

    // MARK: - Daten

    private var sortedSelection: [Coin] {
        let order: [AssetKind: Int] = [.crypto: 0, .metal: 1, .stock: 2, .etf: 3]
        return prefs.selectedCoins.sorted {
            (order[$0.kind]!, $0.rank ?? .max, $0.name.lowercased()) < (order[$1.kind]!, $1.rank ?? .max, $1.name.lowercased())
        }
    }

    private var tickerCoins: [Coin] {
        let ids = Set(prefs.tickerIDs)
        return sortedSelection.filter { ids.contains($0.id) }
    }

    /// Was gerade in der Menüleiste steht (beim Rotieren nur der aktuelle Wert).
    private var visibleTickerCoins: [Coin] {
        let coins = tickerCoins
        guard prefs.tickerMode == .rotate, !coins.isEmpty else { return coins }
        return [coins[rotationIndex % coins.count]]
    }

    /// Letzte erfolgreiche Abfrage ist deutlich älter als das Intervall.
    private var isStale: Bool {
        guard let lastUpdate else { return false }
        return Date().timeIntervalSince(lastUpdate) > Double(prefs.refreshInterval * 3 + 60)
    }

    @objc private func didWake() {
        // Nach dem Aufwachen kurz warten, bis das Netzwerk wieder da ist.
        scheduleRefresh(after: 5)
    }

    @objc private func refresh() {
        pendingRefresh?.cancel()
        refreshTask?.cancel()

        let selection = prefs.selectedCoins
        guard !selection.isEmpty else {
            quotes = [:]
            lastError = nil
            updateUI()
            return
        }

        let cryptoIDs = selection.filter { $0.kind == .crypto }.map(\.id)
        let others = selection.filter { $0.kind != .crypto }
        let client = CoinGecko.current
        let currency = prefs.baseCurrency
        let metalUnit = prefs.metalUnit
        refreshTask = Task { [weak self] in
            let crypto = Task { () async throws -> [CoinGecko.Market] in
                cryptoIDs.isEmpty ? [] : try await client.markets(ids: cryptoIDs, currency: currency)
            }
            let yahoo = await YahooFinance.quotes(for: others, currency: currency, metalUnit: metalUnit)
            let markets = await crypto.result
            guard !Task.isCancelled, let self else { return }
            self.apply(markets, yahoo: yahoo.quotes, yahooError: yahoo.error)
        }
    }

    private func scheduleRefresh(after seconds: Double) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func apply(_ result: Result<[CoinGecko.Market], Error>, yahoo: [String: Quote], yahooError: String?) {
        // Bei Fehlern die alten Kurse behalten und nur Erfolgreiches überschreiben.
        var newQuotes = quotes
        var errors: [String] = []
        var coins = prefs.selectedCoins
        let markets: [CoinGecko.Market]
        switch result {
        case .success(let value): markets = value
        case .failure(let error):
            markets = []
            if (error as? URLError)?.code != .cancelled { errors.append(error.localizedDescription) }
        }
        if let yahooError { errors.append(yahooError) }
        newQuotes.merge(yahoo) { $1 }

        for market in markets {
            if let price = market.currentPrice {
                newQuotes[market.id] = Quote(price: price, change24h: market.priceChangePercentage24h)
            }
            // Name, Symbol und Rang aktuell halten (Sortierung im Menü).
            if let i = coins.firstIndex(where: { $0.id == market.id }) {
                coins[i].symbol = market.symbol
                coins[i].name = market.name
                coins[i].rank = market.marketCapRank
            }
        }
        if coins != prefs.selectedCoins { prefs.selectedCoins = coins }

        let selectedIDs = Set(coins.map(\.id))
        quotes = newQuotes.filter { selectedIDs.contains($0.key) }
        if !markets.isEmpty || !yahoo.isEmpty { lastUpdate = Date() }
        lastError = errors.isEmpty ? nil : errors.joined(separator: " ")
        updateUI()
    }

    private func restartTimers() {
        refreshTimer?.invalidate()
        refreshTimer = repeatingTimer(TimeInterval(prefs.refreshInterval)) { [weak self] in self?.refresh() }

        rotationTimer?.invalidate()
        rotationTimer = nil
        if prefs.tickerMode == .rotate {
            rotationTimer = repeatingTimer(5) { [weak self] in
                guard let self else { return }
                self.rotationIndex += 1
                self.updateTitle()
            }
        }
    }

    /// Timer im Common-Mode, damit er auch bei geöffnetem Menü weiterläuft.
    private func repeatingTimer(_ interval: TimeInterval, _ block: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { block() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - Menüleiste

    private var renderer: TickerRenderer { TickerRenderer(quotes: quotes, isStale: isStale) }

    private func updateUI() {
        updateTitle()
        for (id, item) in coinRows {
            if let coin = prefs.selectedCoins.first(where: { $0.id == id }) {
                item.attributedTitle = renderer.rowTitle(for: coin)
            }
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let coins = visibleTickerCoins
        if coins.isEmpty {
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageLeading
            button.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis.circle", accessibilityDescription: "Tickado")
        } else if prefs.tickerMode == .stacked {
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            button.image = renderer.stackedImage(for: coins)
        } else {
            button.image = nil
            button.attributedTitle = renderer.tickerTitle(for: coins)
        }
        button.toolTip = statusText
        settings?.updatePreview()
    }

    private var statusText: String {
        var lines = ["Tickado"]
        if let lastUpdate {
            lines.append(L("Updated %@", lastUpdate.formatted(date: .omitted, time: .standard)))
        } else if lastError == nil {
            lines.append(L("Loading prices…"))
        }
        if let lastError { lines.append(lastError) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        coinRows = [:]

        // Fenster erst nach dem Schließen des Menüs öffnen.
        menu.addItem(ClosureMenuItem(L("Settings…")) { [weak self] in
            DispatchQueue.main.async { self?.showSettings(.display) }
        })
        menu.addItem(.separator())

        let coins = sortedSelection
        if coins.isEmpty {
            let empty = NSMenuItem(title: L("No coins selected"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let tickerIDs = Set(prefs.tickerIDs)
        for (index, coin) in coins.enumerated() {
            if index > 0, coins[index - 1].kind != coin.kind { menu.addItem(.separator()) }
            let item = ClosureMenuItem("", state: tickerIDs.contains(coin.id)) { [weak self] in
                self?.toggleTicker(coin.id)
            }
            item.attributedTitle = renderer.rowTitle(for: coin)
            item.toolTip = L("Click to show %@ in the menu bar. Hold ⌥ to open it on %@.", coin.displayName, coin.sourceName)
            menu.addItem(item)
            coinRows[coin.id] = item

            let open = ClosureMenuItem(L("Open %@ on %@", coin.displayName, coin.sourceName)) {
                if let url = coin.webURL { NSWorkspace.shared.open(url) }
            }
            open.isAlternate = true
            open.keyEquivalentModifierMask = .option
            menu.addItem(open)
        }

        if let lastError {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: "⚠︎ " + lastError, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("About…")) { Self.showAbout() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit")) { NSApp.terminate(nil) })
    }

    private func toggleTicker(_ id: String) {
        var ids = prefs.tickerIDs
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        prefs.tickerIDs = ids
        settingsDidChange(.ticker)
    }

    // MARK: - Settings

    /// Was im Settings-Fenster geändert wurde; bestimmt die nötigen Folgeschritte.
    enum SettingsChange {
        case display, tickerMode, ticker, interval, currency, metalUnit, apiKey, selection, language
    }

    /// Daten für die Vorschau im Settings-Fenster.
    var previewState: TickerPreviewState {
        TickerPreviewState(renderer: renderer, barCoins: visibleTickerCoins,
                           menuCoins: sortedSelection, tickerIDs: Set(prefs.tickerIDs))
    }

    func settingsDidChange(_ change: SettingsChange) {
        switch change {
        case .display:
            break
        case .tickerMode:
            rotationIndex = 0
            restartTimers()
        case .ticker:
            rotationIndex = 0
        case .interval:
            restartTimers()
        case .currency:
            quotes = [:]
            lastUpdate = nil
            refresh()
        case .metalUnit:
            quotes = quotes.filter { id, _ in !id.hasPrefix("metal:") }
            refresh()
        case .apiKey:
            refresh()
        case .language:
            // Fehlermeldungen stammen noch aus der alten Sprache.
            refresh()
            // Fenster neu aufbauen, damit alle Texte in der neuen Sprache erscheinen.
            // Asynchron, weil der Aufruf aus einem Steuerelement des alten Fensters kommt.
            DispatchQueue.main.async { [weak self] in self?.rebuildSettings() }
        case .selection:
            let ids = Set(prefs.selectedCoins.map(\.id))
            prefs.tickerIDs = prefs.tickerIDs.filter(ids.contains)
            // Mehrere Klicks in der Auswahl zu einer Abfrage zusammenfassen.
            scheduleRefresh(after: 1.5)
        }
        updateTitle()
    }

    private func showSettings(_ tab: SettingsWindowController.Tab) {
        if settings == nil { settings = SettingsWindowController(status: self) }
        settings?.show(tab)
    }

    private func rebuildSettings() {
        guard let old = settings?.window else { return }
        let topLeft = NSPoint(x: old.frame.minX, y: old.frame.maxY)
        // Den Autosave-Namen freigeben, sonst kann das neue Fenster ihn nicht übernehmen.
        old.setFrameAutosaveName("")
        old.orderOut(nil)
        settings = SettingsWindowController(status: self)
        settings?.window?.setFrameTopLeftPoint(topLeft)
        settings?.show(.general)
    }

    // MARK: - Aktionen

    private static func showAbout() {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: L("Prices for crypto, stocks, ETFs and metals in your menu bar.") + "\n" + L("Price data:") + " ",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "CoinGecko", attributes: [
            .font: font, .link: URL(string: "https://www.coingecko.com")!,
        ]))
        credits.append(NSAttributedString(string: ", ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        credits.append(NSAttributedString(string: "Yahoo Finance", attributes: [
            .font: font, .link: URL(string: "https://finance.yahoo.com")!,
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// NSMenuItem mit Closure statt Target/Action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", state: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        self.state = state ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
