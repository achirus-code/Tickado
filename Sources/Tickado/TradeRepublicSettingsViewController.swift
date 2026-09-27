import AppKit

/// Tab "Trade Republic": Synchronisieren (Anmeldung auf der TR-Website, Positionen werden gespeichert),
/// darunter Datum der letzten Synchronisierung, und Löschen der gespeicherten Daten.
final class TradeRepublicSettingsViewController: SettingsPane {
    private lazy var syncButton = NSButton(title: L("Synchronize…"), target: self, action: #selector(synchronize))
    private lazy var removeButton = NSButton(title: L("Remove Data"), target: self, action: #selector(removeData))
    private let lastSyncLabel = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let buttons = NSStackView(views: [syncButton, removeButton])
        buttons.spacing = 8
        lastSyncLabel.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 320
        message.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        let root = makeForm([
            ("Trade Republic:", buttons),
            (nil, lastSyncLabel),
            (nil, message),
        ])

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
