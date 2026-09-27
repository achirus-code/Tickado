import AppKit

/// Tab "Trade Republic": Stand der letzten Synchronisierung, die Positionen zum Abwählen,
/// darunter "Synchronisieren" (Anmeldung auf der TR-Website, Positionen werden gespeichert) und "Daten löschen".
final class TradeRepublicSettingsViewController: SettingsPane {
    private lazy var syncButton = NSButton(title: L("Synchronize…"), target: self, action: #selector(synchronize))
    private lazy var removeButton = NSButton(title: L("Remove Data"), target: self, action: #selector(removeData))
    private let lastSyncLabel = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var list = HoldingsList { [weak self] isin, on in
        TradeRepublic.shared.setHidden(!on, isin: isin)
        self?.onChange(.broker)   // andere Positionen brauchen andere Kurse; lädt auch diesen Tab neu
    }
    private let listHint = NSTextField(wrappingLabelWithString: "")
    private var grid: NSGridView?

    override func loadView() {
        // Button-Zeile in Listenbreite: Synchronisieren links, Löschen rechts
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [syncButton, spacer, removeButton])
        buttons.widthAnchor.constraint(equalToConstant: HoldingsList.width).isActive = true
        lastSyncLabel.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 320
        message.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        listHint.stringValue = L("Unchecked positions are hidden in the menu and not counted.")
        listHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        listHint.textColor = .secondaryLabelColor
        listHint.preferredMaxLayoutWidth = HoldingsList.width
        listHint.widthAnchor.constraint(lessThanOrEqualToConstant: HoldingsList.width).isActive = true
        let root = makeForm([
            (nil, lastSyncLabel),
            (nil, list),
            (nil, listHint),
            (nil, buttons),
            (nil, message),
        ], groups: [3], tall: [1])
        grid = root.subviews.first as? NSGridView

        let disclaimer = NSTextField(wrappingLabelWithString: L(
            "Synchronizing logs you in on the Trade Republic website and saves your positions (ISIN, quantity, buy-in) in Tickado. Prices are then loaded from Yahoo Finance. Uses the unofficial Trade Republic web interface; Tickado is not affiliated with Trade Republic."))
        disclaimer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        disclaimer.textColor = .tertiaryLabelColor
        disclaimer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(disclaimer)
        NSLayoutConstraint.activate([
            disclaimer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            disclaimer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            disclaimer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        view = root
        reload()
    }

    override func reload() {
        let tr = TradeRepublic.shared
        if let lastSync = tr.lastSync {
            lastSyncLabel.stringValue = StatusController.lastSyncText(lastSync) + " · " + L("Positions: %d", tr.holdings.count)
        } else {
            lastSyncLabel.stringValue = L("Not synchronized yet")
        }
        syncButton.isEnabled = !tr.isSyncing
        removeButton.isHidden = !tr.hasData
        list.update(tr.holdings)
        // Ohne Positionen Liste und Hinweis samt ihrer Rasterzeilen ausblenden, sonst bleibt eine Lücke.
        grid?.row(at: 1).isHidden = tr.holdings.isEmpty
        grid?.row(at: 2).isHidden = tr.holdings.isEmpty
        if tr.isSyncing { message.stringValue = L("Log in in the Trade Republic window.") }
    }

    @objc private func synchronize() {
        message.stringValue = ""
        TradeRepublic.shared.synchronize { [weak self] error in
            guard let self else { return }
            self.message.stringValue = error.map { L("Synchronization failed: %@", $0.localizedDescription) } ?? ""
            self.onChange(.broker)
            self.reload()
        }
        reload()
    }

    @objc private func removeData() {
        TradeRepublic.shared.removeData()
        message.stringValue = ""
        onChange(.broker)
    }
}

/// Gespeicherte Positionen: Checkbox (im Menü zeigen und mitzählen), Name, ISIN.
private final class HoldingsList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let check = NSUserInterfaceItemIdentifier("check")
    private static let name = NSUserInterfaceItemIdentifier("name")
    private static let isin = NSUserInterfaceItemIdentifier("isin")
    static let width: CGFloat = 420

    private let onToggle: (String, Bool) -> Void
    private let tableView = NSTableView()
    private var holdings: [TRHolding] = []

    init(onToggle: @escaping (String, Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)

        tableView.headerView = nil
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, width) in [(Self.check, 24.0), (Self.name, 262.0), (Self.isin, 104.0)] {
            let column = NSTableColumn(identifier: id)
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            // Feste Größe: 9 Zeilen sichtbar, mehr per Scrollen.
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: 9 * 22 + 2),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Die Tabelle wächst beim ersten Layout um die Höhe des sichtbaren Bereichs (flexible Höhe, von NSTableView
    /// selbst gesetzt); danach ließe sich eine Seite leerer Zeilen weiterscrollen. `tile()` rechnet die Höhe neu.
    override func layout() {
        super.layout()
        tableView.tile()
    }

    func update(_ holdings: [TRHolding]) {
        guard holdings != self.holdings else { return }
        self.holdings = holdings
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { holdings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let holding = holdings[row]
        switch id {
        case Self.check:
            let box = tableView.makeView(withIdentifier: id, owner: nil) as? NSButton ?? {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
                box.identifier = id
                return box
            }()
            box.state = holding.hidden ? .off : .on
            return box
        case Self.name:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CenteredCell ?? {
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingTail
                return CenteredCell(identifier: id, content: label)
            }()
            let label = cell.content as! NSTextField
            label.stringValue = holding.name
            label.textColor = holding.hidden ? .secondaryLabelColor : .labelColor
            label.toolTip = holding.name
            return cell
        default:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CenteredCell ?? {
                let label = NSTextField(labelWithString: "")
                label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                label.textColor = .secondaryLabelColor
                return CenteredCell(identifier: id, content: label)
            }()
            (cell.content as! NSTextField).stringValue = holding.isin
            return cell
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 else { return }
        onToggle(holdings[row].isin, sender.state == .on)
    }
}

/// Tabellenzelle, die ihr Textfeld vertikal mittig hält (sonst sitzt kleiner Text oben in der Zeile).
private final class CenteredCell: NSView {
    let content: NSView

    init(identifier: NSUserInterfaceItemIdentifier, content: NSView) {
        self.content = content
        super.init(frame: .zero)
        self.identifier = identifier
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
