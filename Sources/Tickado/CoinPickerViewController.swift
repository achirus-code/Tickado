import AppKit

/// Tab "Assets" im Settings-Fenster: Filterfeld, "hide unselected" und Liste mit Checkboxen.
@MainActor
final class CoinPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static let checkColumn = NSUserInterfaceItemIdentifier("check")
    private static let symbolColumn = NSUserInterfaceItemIdentifier("symbol")
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")

    private let prefs = Prefs.shared
    private let onChange: () -> Void

    private var catalog: [String: Coin] = [:]
    private var rows: [Coin] = []
    private var selectedIDs: Set<String>

    private var kind: AssetKind = .crypto
    private let kindControl = NSSegmentedControl(labels: AssetKind.allCases.map(\.title), trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let searchField = NSSearchField()
    private let hideUnselected = NSButton(checkboxWithTitle: L("hide unselected"), target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let footer = NSTextField(labelWithString: "")
    private let tableView = NSTableView()

    private var loadingCount = 0 { didSet { loadingCount > 0 ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) } }
    private var catalogError: String?
    private var searchTask: Task<Void, Never>?
    // Treffer der Online-Suche (z. B. per ISIN) auch zeigen, wenn Name/Symbol den Suchtext nicht enthalten.
    private var remoteQuery = ""
    private var remoteMatches: Set<String> = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.selectedIDs = Set(Prefs.shared.selectedCoins.map(\.id))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 530))

        kindControl.selectedSegment = 0
        kindControl.target = self
        kindControl.action = #selector(kindChanged)
        kindControl.segmentDistribution = .fillEqually

        searchField.placeholderString = L("Filter")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize + 2)

        hideUnselected.target = self
        hideUnselected.action = #selector(filterChanged)
        hideUnselected.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        hideUnselected.setContentHuggingPriority(.required, for: .horizontal)
        hideUnselected.setContentCompressionResistancePriority(.required, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail

        configureTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder

        for view in [kindControl, searchField, spinner, hideUnselected, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            kindControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            kindControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            kindControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            searchField.topAnchor.constraint(equalTo: kindControl.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            spinner.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 6),
            spinner.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),

            hideUnselected.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            hideUnselected.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hideUnselected.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        view = root
    }

    private func configureTable() {
        tableView.headerView = nil
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        for (id, width) in [(Self.checkColumn, 56.0), (Self.symbolColumn, 110.0), (Self.nameColumn, 160.0)] {
            let column = NSTableColumn(identifier: id)
            column.width = width
            column.resizingMask = id == Self.nameColumn ? .autoresizingMask : []
            tableView.addTableColumn(column)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let cache = CatalogStore.load()
        for coin in cache?.coins ?? [] { catalog[coin.id] = coin }
        for coin in Coin.popularStocks + Coin.popularETFs + Metal.all.map(\.coin) { catalog[coin.id] = coin }
        for coin in prefs.selectedCoins where catalog[coin.id] == nil { catalog[coin.id] = coin }
        applyFilter()

        if cache == nil || cache!.date.timeIntervalSinceNow < -86_400 { loadCatalog() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Die Metall-Einheit kann sich im Tab "General" geändert haben.
        updateFooter()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Laden

    private func loadCatalog() {
        loadingCount += 1
        catalogError = nil
        updateFooter()
        let client = CoinGecko.current
        Task { [weak self] in
            do {
                let coins = try await CatalogStore.fetch(client)
                CatalogStore.save(coins)
                guard let self else { return }
                for coin in coins { self.catalog[coin.id] = coin }
                self.loadingCount -= 1
                self.applyFilter()
            } catch {
                guard let self else { return }
                self.loadingCount -= 1
                self.catalogError = L("Couldn't load coin list: %@", error.localizedDescription)
                self.updateFooter()
            }
        }
    }

    /// Krypto: findet der lokale Filter kaum etwas, in allen CoinGecko-Coins suchen.
    /// Aktien: immer bei Yahoo Finance suchen.
    private func scheduleRemoteSearch() {
        searchTask?.cancel()
        let text = query
        let kind = kind
        switch kind {
        case .crypto: guard text.count >= 2, rows.count < 10 else { return }
        case .stock, .etf: guard !text.isEmpty else { return }
        case .metal: return
        }
        let client = CoinGecko.current
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(kind.isListed ? 350 : 600))
            guard !Task.isCancelled, let self else { return }
            self.loadingCount += 1
            let found = kind.isListed
                ? ((try? await YahooFinance.search(text, kind: kind)) ?? [])
                : ((try? await client.search(text)) ?? [])
            self.loadingCount -= 1
            guard !Task.isCancelled else { return }
            for coin in found where self.catalog[coin.id] == nil { self.catalog[coin.id] = coin }
            self.remoteQuery = text
            self.remoteMatches = Set(found.map(\.id))
            self.applyFilter()
        }
    }

    // MARK: - Filter

    private var query: String {
        searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    }

    func controlTextDidChange(_ obj: Notification) { filterChanged() }

    @objc private func kindChanged() {
        kind = AssetKind.allCases[kindControl.selectedSegment]
        searchField.placeholderString = switch kind {
        case .stock: L("Filter or search company / ticker")
        case .etf: L("Filter or search name / ticker / ISIN")
        default: L("Filter")
        }
        filterChanged()
        tableView.scrollRowToVisible(0)
    }

    @objc private func filterChanged() {
        applyFilter()
        scheduleRemoteSearch()
    }

    private func applyFilter() {
        let text = query
        let hide = hideUnselected.state == .on
        rows = catalog.values
            .filter { coin in
                if coin.kind != kind { return false }
                if hide && !selectedIDs.contains(coin.id) { return false }
                guard !text.isEmpty else { return true }
                if text == remoteQuery && remoteMatches.contains(coin.id) { return true }
                return coin.symbol.lowercased().hasPrefix(text) || coin.displaySymbol.lowercased().hasPrefix(text)
                    || coin.name.lowercased().contains(text) || coin.displayName.lowercased().contains(text)
                    || coin.id.contains(text)
            }
            .sorted { ($0.rank ?? .max, $0.name.lowercased()) < ($1.rank ?? .max, $1.name.lowercased()) }
        tableView.reloadData()
        updateFooter()
    }

    private func updateFooter() {
        if kind == .crypto, let catalogError {
            footer.stringValue = catalogError
        } else if kind == .crypto && loadingCount > 0 && rows.count < 20 {
            footer.stringValue = L("Loading coin list…")
        } else {
            let count = catalog.values.filter { $0.kind == kind && selectedIDs.contains($0.id) }.count
            let hint = switch kind {
            case .crypto: L("type to search all coins on CoinGecko")
            case .stock: L("type a company or ticker to search Yahoo Finance")
            case .etf: L("type a name, ticker or ISIN to search Yahoo Finance")
            case .metal: L("Unit: %@ (set in General)", prefs.metalUnit.title)
            }
            footer.stringValue = L("Selected: %d", count) + " · " + hint
        }
    }

    // MARK: - Auswahl

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 else { return }
        setSelected(rows[row], sender.state == .on)
    }

    /// Klick auf Symbol oder Name schaltet die Checkbox ebenfalls um.
    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, tableView.clickedColumn != 0 else { return }
        let coin = rows[row]
        setSelected(coin, !selectedIDs.contains(coin.id))
        tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }

    private func setSelected(_ coin: Coin, _ selected: Bool) {
        var coins = prefs.selectedCoins
        if selected {
            guard selectedIDs.insert(coin.id).inserted else { return }
            coins.append(coin)
        } else {
            guard selectedIDs.remove(coin.id) != nil else { return }
            coins.removeAll { $0.id == coin.id }
        }
        prefs.selectedCoins = coins
        updateFooter()
        onChange()
    }

    // MARK: - Tabelle

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let coin = rows[row]

        if id == Self.checkColumn {
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CheckboxCell
                ?? CheckboxCell(identifier: id, target: self, action: #selector(checkboxToggled(_:)))
            cell.checkbox.state = selectedIDs.contains(coin.id) ? .on : .off
            return cell
        }

        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCell ?? TextCell(identifier: id)
        cell.label.stringValue = id == Self.symbolColumn ? coin.displaySymbol : coin.displayName
        cell.toolTip = "\(coin.displayName) (\(coin.symbol))" + (coin.kind == .crypto ? coin.rank.map { " · " + L("Rank #%d", $0) } ?? "" : "")
        return cell
    }
}

private final class CheckboxCell: NSView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.target = target
        checkbox.action = action
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class TextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
