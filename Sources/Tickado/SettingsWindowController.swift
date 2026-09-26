import AppKit

/// Daten für die Vorschau: dieselben Kurse und Werte wie in der echten Menüleiste.
struct TickerPreviewState {
    let renderer: TickerRenderer
    let barCoins: [Coin]      // wie in der Menüleiste (beim Rotieren nur der aktuelle Wert)
    let menuCoins: [Coin]     // sortiert wie im Menü
    let tickerIDs: Set<String>
}

/// Settings-Fenster: oben die Vorschau, darunter Tabs "Display", "Assets" und "General".
@MainActor
final class SettingsWindowController: NSWindowController {
    enum Tab: Int {
        case display, assets, general
    }

    private unowned let status: StatusController
    private let preview = TickerPreviewView()
    private let tabs = NSTabViewController()
    private let displayPane: DisplaySettingsViewController
    private let generalPane: GeneralSettingsViewController

    init(status: StatusController) {
        self.status = status
        let onChange: (StatusController.SettingsChange) -> Void = { [weak status] in status?.settingsDidChange($0) }
        displayPane = DisplaySettingsViewController(onChange: onChange)
        generalPane = GeneralSettingsViewController(onChange: onChange)
        let picker = CoinPickerViewController { onChange(.selection) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("Tickado Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        tabs.tabStyle = .segmentedControlOnTop
        for (pane, label) in [(displayPane, L("Display")), (picker, L("Assets")), (generalPane, L("General"))] as [(NSViewController, String)] {
            let item = NSTabViewItem(viewController: pane)
            item.label = label
            tabs.addTabViewItem(item)
        }

        let content = SettingsContentViewController(preview: preview, tabs: tabs)
        window.contentViewController = content
        let size = NSSize(width: 560, height: 720)
        window.setContentSize(size)
        if window.setFrameUsingName("TickadoSettings") {
            // Frühere Versionen waren in der Größe veränderbar: nur die Position übernehmen.
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(size)
            window.setFrameTopLeftPoint(topLeft)
        } else {
            window.center()
        }
        window.setFrameAutosaveName("TickadoSettings")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ tab: Tab) {
        displayPane.reload()
        generalPane.reload()
        tabs.selectedTabViewItemIndex = tab.rawValue
        update(status.previewState)
        window?.bringToFront()
    }

    /// Wird bei jeder Änderung der Menüleiste aufgerufen (neue Kurse, Rotation, geänderte Einstellungen).
    func updatePreview() {
        guard window?.isVisible == true else { return }
        update(status.previewState)
    }

    private func update(_ state: TickerPreviewState) {
        preview.update(state)
        displayPane.showTickerChoices(state.menuCoins, checked: state.tickerIDs)
    }
}

extension NSWindow {
    /// Fenster sicher nach vorn holen. `NSApp.activate()` ist seit macOS 14 nur eine Bitte und wird bei
    /// Menüleisten-Apps manchmal ignoriert; ohne `orderFrontRegardless` bliebe das Fenster dann hinter anderen Apps.
    func bringToFront() {
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

/// Inhalt des Fensters: Vorschau fest oben, Tabs füllen den Rest.
private final class SettingsContentViewController: NSViewController {
    private let preview: TickerPreviewView
    private let tabs: NSTabViewController

    init(preview: TickerPreviewView, tabs: NSTabViewController) {
        self.preview = preview
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 720))
        addChild(tabs)
        for view in [preview, tabs.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            tabs.view.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            tabs.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabs.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}

// MARK: - Vorschau

/// Nachgebaute Menüleiste mit aufgeklapptem Menü, gezeichnet mit demselben Renderer wie die echte.
private final class TickerPreviewView: NSView {
    private static let maxRows = 5

    private let screen = FillView(fill: .underPageBackgroundColor, cornerRadius: 8, border: .separatorColor)
    private let bar = FillView(fill: .windowBackgroundColor)
    private let tickerLabel = NSTextField(labelWithString: "")
    private let tickerImage = NSImageView()
    private let clock = NSTextField(labelWithString: "")
    private let menuBox = FillView(fill: .windowBackgroundColor, cornerRadius: 6, border: .separatorColor)
    private let rows = NSStackView()
    private let note = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        tickerLabel.lineBreakMode = .byTruncatingHead
        tickerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tickerImage.imageScaling = .scaleNone
        tickerImage.imageAlignment = .alignRight
        tickerImage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let ticker = NSStackView(views: [tickerLabel, tickerImage])
        ticker.orientation = .horizontal
        ticker.setHuggingPriority(.defaultHigh, for: .horizontal)

        let wifi = NSImageView(image: NSImage(systemSymbolName: "wifi", accessibilityDescription: nil) ?? NSImage())
        wifi.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        wifi.contentTintColor = .labelColor
        clock.font = .menuBarFont(ofSize: 0)
        let extras = NSStackView(views: [wifi, clock])
        extras.orientation = .horizontal
        extras.spacing = 12

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 14)
        rows.setHuggingPriority(.defaultHigh, for: .horizontal)
        rows.setHuggingPriority(.defaultHigh, for: .vertical)

        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [screen, note] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [bar, menuBox] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(view)
        }
        for view in [ticker, extras] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        rows.translatesAutoresizingMaskIntoConstraints = false
        menuBox.addSubview(rows)

        let barHeight = max(NSStatusBar.system.thickness, 22)
        // Platz für maxRows Zeilen in Menlo 12 (ca. 15 pt Text + 4 pt Abstand, etwas Reserve)
        let menuHeight = CGFloat(Self.maxRows) * 20 + 10
        let menuUnderTicker = menuBox.leadingAnchor.constraint(equalTo: ticker.leadingAnchor, constant: -10)
        menuUnderTicker.priority = .defaultLow

        NSLayoutConstraint.activate([
            screen.topAnchor.constraint(equalTo: topAnchor),
            screen.leadingAnchor.constraint(equalTo: leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: trailingAnchor),
            screen.heightAnchor.constraint(equalToConstant: barHeight + 4 + menuHeight + 10),

            bar.topAnchor.constraint(equalTo: screen.topAnchor),
            bar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: barHeight),

            extras.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            extras.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            ticker.trailingAnchor.constraint(equalTo: extras.leadingAnchor, constant: -16),
            ticker.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 12),
            ticker.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tickerImage.heightAnchor.constraint(lessThanOrEqualToConstant: barHeight),

            // Das Menü hängt wie echt unter dem Ticker, bleibt aber im Bild.
            menuBox.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            menuUnderTicker,
            menuBox.leadingAnchor.constraint(greaterThanOrEqualTo: screen.leadingAnchor, constant: 8),
            menuBox.trailingAnchor.constraint(lessThanOrEqualTo: screen.trailingAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: menuBox.topAnchor),
            rows.leadingAnchor.constraint(equalTo: menuBox.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: menuBox.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: menuBox.bottomAnchor),

            note.topAnchor.constraint(equalTo: screen.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            note.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: TickerPreviewState) {
        let prefs = Prefs.shared
        let renderer = state.renderer
        var notes: [String] = []

        // Ohne Häkchen zeigt die Menüleiste nur das Symbol, deshalb hier ein Beispiel aus der Auswahl.
        var barCoins = state.barCoins
        if barCoins.isEmpty, !state.menuCoins.isEmpty {
            barCoins = Array(state.menuCoins.prefix(prefs.tickerMode == .rotate ? 1 : 2))
            notes.append(L("Sample: check values under Display › Menu bar to show them."))
        } else if prefs.tickerMode == .rotate, state.menuCoins.filter({ state.tickerIDs.contains($0.id) }).count > 1 {
            notes.append(L("Rotates through the checked values every 5 seconds."))
        }

        if barCoins.isEmpty {
            tickerImage.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis.circle", accessibilityDescription: "Tickado")
        } else if prefs.tickerMode == .stacked {
            tickerImage.image = renderer.stackedImage(for: barCoins)
        } else {
            tickerLabel.attributedStringValue = renderer.tickerTitle(for: barCoins)
        }
        let showsLabel = !barCoins.isEmpty && prefs.tickerMode != .stacked
        tickerLabel.isHidden = !showsLabel
        tickerImage.isHidden = showsLabel
        clock.stringValue = Date().formatted(date: .omitted, time: .shortened)

        for view in rows.arrangedSubviews { view.removeFromSuperview() }
        if state.menuCoins.isEmpty {
            let empty = NSTextField(labelWithString: L("No coins selected"))
            empty.font = .menuFont(ofSize: 0)
            empty.textColor = .disabledControlTextColor
            rows.addArrangedSubview(menuRow(checked: false, content: empty))
        }
        for coin in state.menuCoins.prefix(Self.maxRows) {
            let label = NSTextField(labelWithAttributedString: renderer.rowTitle(for: coin))
            label.lineBreakMode = .byClipping
            rows.addArrangedSubview(menuRow(checked: state.tickerIDs.contains(coin.id), content: label))
        }
        let hidden = state.menuCoins.count - Self.maxRows
        if hidden > 0 { notes.append(L("More in the menu: %d", hidden)) }

        note.stringValue = notes.joined(separator: " ")
    }

    /// Menüzeile mit Häkchen-Spalte wie im echten Menü.
    private func menuRow(checked: Bool, content: NSView) -> NSView {
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage())
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        check.contentTintColor = .labelColor
        check.alphaValue = checked ? 1 : 0
        check.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let row = NSStackView(views: [check, content])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }
}

/// Fläche mit dynamischer Hintergrundfarbe (passt sich hellem/dunklem Modus an).
private final class FillView: NSView {
    private let fill: NSColor
    private let cornerRadius: CGFloat
    private let border: NSColor?

    init(fill: NSColor, cornerRadius: CGFloat = 0, border: NSColor? = nil) {
        self.fill = fill
        self.cornerRadius = cornerRadius
        self.border = border
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill.cgColor
            layer.borderColor = border?.cgColor
        }
        layer.borderWidth = border == nil ? 0 : 1
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
    }
}

// MARK: - Tabs

/// Basis für die Formular-Tabs: Beschriftung rechtsbündig, Steuerelemente links daneben.
@MainActor
class SettingsPane: NSViewController {
    let prefs = Prefs.shared
    let onChange: (StatusController.SettingsChange) -> Void

    init(onChange: @escaping (StatusController.SettingsChange) -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Steuerelemente an die gespeicherten Einstellungen anpassen.
    func reload() {}

    /// `rows`: Beschriftung (nil = keine) und Steuerelement; `groups`: Zeilen mit zusätzlichem Abstand davor;
    /// `tall`: Zeilen ohne Grundlinie (z. B. Listen), Beschriftung oben.
    func makeForm(_ rows: [(String?, NSView)], groups: Set<Int> = [], tall: Set<Int> = []) -> NSView {
        var views: [[NSView]] = []
        for (title, control) in rows {
            let label: NSView = title.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView
            views.append([label, control])
        }
        let grid = NSGridView(views: views)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        for index in groups { grid.row(at: index).topPadding = 12 }
        for index in tall {
            grid.row(at: index).rowAlignment = .none
            grid.cell(atColumnIndex: 0, rowIndex: index).yPlacement = .top
        }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])
        return root
    }

    func checkbox(_ title: String) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxChanged(_:)))
    }

    /// Eintrag eines Auswahlmenüs; `tag` identifiziert den Wert.
    struct PopUpItem {
        let title: NSAttributedString
        let tag: Int

        init(_ title: String, _ tag: Int) {
            self.init(NSAttributedString(string: title), tag)
        }

        init(_ title: NSAttributedString, _ tag: Int) {
            self.title = title
            self.tag = tag
        }
    }

    func popUp(_ items: [PopUpItem]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for item in items {
            let menuItem = NSMenuItem(title: item.title.string, action: nil, keyEquivalent: "")
            menuItem.attributedTitle = item.title
            menuItem.tag = item.tag
            popup.menu?.addItem(menuItem)
        }
        popup.target = self
        popup.action = #selector(popUpChanged(_:))
        return popup
    }

    @objc func checkboxChanged(_ sender: NSButton) {}
    @objc func popUpChanged(_ sender: NSPopUpButton) {}
}

/// Tab "Display": Menüleiste, Farben, Stellen.
private final class DisplaySettingsViewController: SettingsPane {
    private lazy var modePopUp = popUp([
        PopUpItem(L("Show all checked values"), 0),
        PopUpItem(L("Rotate checked values (every 5 s)"), 1),
        PopUpItem(L("Compact: two rows with ▲▼"), 2),
    ])
    private let modes: [TickerMode] = [.all, .rotate, .stacked]
    private lazy var coinSigns = checkbox(L("Show coin signs instead of symbols (₿, Ξ, Au)"))
    private lazy var currencySign = checkbox(L("Show currency sign"))
    private lazy var changeInBar = checkbox(L("Show 24h change"))
    private lazy var changeOnly = checkbox(L("Only 24h change, no price"))
    private lazy var abbreviate = checkbox(L("Abbreviate large prices (84.2K, 2.6K)"))
    private lazy var themePopUp = popUp(ColorTheme.allCases.enumerated().map { item -> PopUpItem in
        // ▲ ▼ in den Farben des Themes
        let theme = item.element
        // Gleiche Größe wie der Text der Auswahlbox
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = NSMutableAttributedString(string: theme.title + "   ", attributes: [.font: font])
        title.append(NSAttributedString(string: "▲", attributes: [.font: font, .foregroundColor: theme.color(for: 1)]))
        title.append(NSAttributedString(string: " ▼", attributes: [.font: font, .foregroundColor: theme.color(for: -1)]))
        return PopUpItem(title, item.offset)
    })
    private lazy var precisionPopUp = popUp((2...6).map { digits -> PopUpItem in
        // Beispiele wie 84.213 · 1,53 · 0,0398
        let examples = [84_213.47, 1.534_812, 0.039_812_7]
            .map { PriceFormat.price($0, currency: "usd", digits: digits, currencySign: false) }
            .joined(separator: "  ·  ")
        // Gleiche Größe wie der Text der Auswahlbox
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = NSMutableAttributedString(string: L("%d digits", digits) + "    ", attributes: [.font: font])
        title.append(NSAttributedString(string: examples, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return PopUpItem(title, digits)
    })
    private lazy var showChange = checkbox(L("Show 24h price change"))
    private lazy var tickerList = TickerChoiceList { [weak self] id, on in self?.setTicker(id, on) }

    private var toggles: [(NSButton, ReferenceWritableKeyPath<Prefs, Bool>)] {
        [(coinSigns, \.coinSigns), (currencySign, \.currencySign), (changeInBar, \.changeInBar),
         (changeOnly, \.changeOnly), (abbreviate, \.abbreviate), (showChange, \.showChange)]
    }

    override func loadView() {
        view = makeForm([
            (L("Menu bar:"), tickerList),
            (nil, modePopUp),
            (nil, coinSigns),
            (nil, currencySign),
            (nil, changeInBar),
            (nil, changeOnly),
            (nil, abbreviate),
            (L("Colors:"), themePopUp),
            (L("Precision:"), precisionPopUp),
            (L("Menu:"), showChange),
        ], groups: [7, 9], tall: [0])
        reload()
    }

    /// Liste der ausgewählten Werte mit Häkchen für die Menüleiste (wie ein Klick im Menü).
    func showTickerChoices(_ coins: [Coin], checked: Set<String>) {
        tickerList.update(coins, checked: checked)
    }

    private func setTicker(_ id: String, _ on: Bool) {
        var ids = prefs.tickerIDs
        ids.removeAll { $0 == id }
        if on { ids.append(id) }
        prefs.tickerIDs = ids
        onChange(.ticker)
    }

    override func reload() {
        modePopUp.selectItem(withTag: modes.firstIndex(of: prefs.tickerMode) ?? 0)
        themePopUp.selectItem(withTag: ColorTheme.allCases.firstIndex(of: prefs.colorTheme) ?? 0)
        precisionPopUp.selectItem(withTag: prefs.precisionDigits)
        for (button, keyPath) in toggles { button.state = prefs[keyPath: keyPath] ? .on : .off }
        updateEnabled()
    }

    /// Ohne Kurs sind Währungszeichen, Kürzen und "24h-Änderung zeigen" ohne Wirkung.
    private func updateEnabled() {
        for button in [currencySign, changeInBar, abbreviate] { button.isEnabled = !prefs.changeOnly }
    }

    override func checkboxChanged(_ sender: NSButton) {
        guard let keyPath = toggles.first(where: { $0.0 === sender })?.1 else { return }
        prefs[keyPath: keyPath] = sender.state == .on
        updateEnabled()
        onChange(.display)
    }

    override func popUpChanged(_ sender: NSPopUpButton) {
        let tag = sender.selectedTag()
        if sender === modePopUp {
            prefs.tickerMode = modes[tag]
            onChange(.tickerMode)
        } else if sender === themePopUp {
            prefs.colorTheme = ColorTheme.allCases[tag]
            onChange(.display)
        } else if sender === precisionPopUp {
            prefs.precisionDigits = tag
            onChange(.display)
        }
    }
}

/// Ausgewählte Werte (Reihenfolge wie im Menü) mit Checkbox "in der Menüleiste zeigen".
private final class TickerChoiceList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let column = NSUserInterfaceItemIdentifier("choice")

    private let onToggle: (String, Bool) -> Void
    private let tableView = NSTableView()
    private let empty = NSTextField(labelWithString: L("Nothing selected yet. Pick values in the Assets tab."))
    private var coins: [Coin] = []
    private var checked: Set<String> = []

    init(onToggle: @escaping (String, Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)

        tableView.headerView = nil
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = 22
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.addTableColumn(NSTableColumn(identifier: Self.column))
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder

        empty.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        empty.textColor = .secondaryLabelColor

        for view in [scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Feste Größe: 6 Zeilen sichtbar, mehr per Scrollen.
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 6 * 22 + 2),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ coins: [Coin], checked: Set<String>) {
        // Wird auch bei jeder Rotation aufgerufen, deshalb nur bei Änderungen neu laden.
        guard coins != self.coins || checked != self.checked else { return }
        self.coins = coins
        self.checked = checked
        empty.isHidden = !coins.isEmpty
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { coins.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let coin = coins[row]
        let cell = tableView.makeView(withIdentifier: Self.column, owner: nil) as? ChoiceCell
            ?? ChoiceCell(identifier: Self.column, target: self, action: #selector(toggled(_:)))
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = NSMutableAttributedString(string: coin.displaySymbol + "   ", attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium),
        ])
        title.append(NSAttributedString(string: coin.displayName, attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        cell.checkbox.attributedTitle = title
        cell.checkbox.state = checked.contains(coin.id) ? .on : .off
        return cell
    }

    @objc private func toggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 else { return }
        onToggle(coins[row].id, sender.state == .on)
    }
}

private final class ChoiceCell: NSView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.target = target
        checkbox.action = action
        checkbox.lineBreakMode = .byTruncatingTail
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Tab "General": Sprache, Währung, Einheit, Intervall, Autostart, API-Key.
private final class GeneralSettingsViewController: SettingsPane {
    // Tag 0 = Systemsprache, sonst Index in L10n.languages + 1.
    private lazy var languagePopUp = popUp(
        [PopUpItem(L("System (%@)", L10n.name(of: L10n.systemLanguage)), 0)]
            + L10n.languages.enumerated().map { PopUpItem(L10n.name(of: $1), $0 + 1) }
    )
    private lazy var currencyPopUp = popUp(BaseCurrency.all.enumerated().map { item -> PopUpItem in
        PopUpItem("\(item.element.code.uppercased()) – \(item.element.displayName)", item.offset)
    })
    private lazy var metalUnitPopUp = popUp(MetalUnit.allCases.enumerated().map { item -> PopUpItem in
        PopUpItem(item.element.title, item.offset)
    })
    private lazy var intervalPopUp = popUp([30, 60, 120, 300, 600, 1800].map { seconds -> PopUpItem in
        // Systemformatierung in der gewählten Sprache, mit korrekten Pluralformen.
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        return PopUpItem(formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s", seconds)
    })
    private lazy var launchAtLogin = checkbox(L("Launch at login"))
    private let apiKeyStatus = NSTextField(labelWithString: "")

    override func loadView() {
        let configure = NSButton(title: L("Configure…"), target: self, action: #selector(configureAPIKey))
        view = makeForm([
            (L("Language:"), languagePopUp),
            (L("Base currency:"), currencyPopUp),
            (L("Metal unit:"), metalUnitPopUp),
            (L("Update every:"), intervalPopUp),
            (L("Startup:"), launchAtLogin),
            (L("CoinGecko API key:"), apiKeyStatus),
            (nil, configure),
        ], groups: [1, 4, 5])
        reload()
    }

    override func reload() {
        languagePopUp.selectItem(withTag: prefs.language.flatMap { L10n.languages.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        currencyPopUp.selectItem(withTag: BaseCurrency.all.firstIndex { $0.code == prefs.baseCurrency } ?? 0)
        metalUnitPopUp.selectItem(withTag: MetalUnit.allCases.firstIndex(of: prefs.metalUnit) ?? 0)
        // Eigene Intervalle (z. B. per `defaults write`) sind nicht in der Liste; dann nichts auswählen.
        if !intervalPopUp.selectItem(withTag: prefs.refreshInterval) { intervalPopUp.select(nil) }
        launchAtLogin.state = LaunchAtLogin.isEnabled ? .on : .off
        apiKeyStatus.stringValue = Keychain.apiKey == nil
            ? L("None (public API, rate-limited)")
            : prefs.apiKeyKind == .pro ? L("Pro key saved") : L("Demo key saved")
    }

    override func checkboxChanged(_ sender: NSButton) {
        guard sender === launchAtLogin else { return }
        do {
            try LaunchAtLogin.set(sender.state == .on)
            if LaunchAtLogin.requiresApproval { LaunchAtLogin.openSystemSettings() }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = L("Launch at Login could not be changed")
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
        reload()
    }

    override func popUpChanged(_ sender: NSPopUpButton) {
        let tag = sender.selectedTag()
        if sender === languagePopUp {
            let language = tag == 0 ? nil : L10n.languages[tag - 1]
            guard prefs.language != language else { return }
            prefs.language = language
            onChange(.language)
        } else if sender === currencyPopUp {
            let code = BaseCurrency.all[tag].code
            guard prefs.baseCurrency != code else { return }
            prefs.baseCurrency = code
            onChange(.currency)
        } else if sender === metalUnitPopUp {
            let unit = MetalUnit.allCases[tag]
            guard prefs.metalUnit != unit else { return }
            prefs.metalUnit = unit
            onChange(.metalUnit)
        } else if sender === intervalPopUp {
            prefs.refreshInterval = tag
            onChange(.interval)
        }
    }

    @objc private func configureAPIKey() {
        APIKeyPrompt.run { [weak self] in self?.onChange(.apiKey) }
        reload()
    }
}
