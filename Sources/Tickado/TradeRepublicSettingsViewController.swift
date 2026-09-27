import AppKit

/// Tab "Trade Republic": Status, "Verbinden" (Anmeldung auf der TR-Website im eigenen Fenster) und Abmelden.
final class TradeRepublicSettingsViewController: SettingsPane {
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var connectButton = NSButton(title: L("Connect…"), target: self, action: #selector(connect))
    private lazy var logoutButton = NSButton(title: L("Log Out"), target: self, action: #selector(logOut))

    override func loadView() {
        let buttons = NSStackView(views: [connectButton, logoutButton])
        buttons.spacing = 8
        let root = makeForm([
            (L("Status:"), statusLabel),
            (nil, buttons),
        ], groups: [1])

        let disclaimer = NSTextField(wrappingLabelWithString: L(
            "Uses the unofficial Trade Republic web interface, which can change at any time. Tickado is not affiliated with Trade Republic. You log in on the Trade Republic website; Tickado only keeps the session, in the keychain."))
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
        let state = TradeRepublic.shared.state
        statusLabel.stringValue = switch state {
        case .connected: L("Connected")
        case .expired: L("Session expired. Please log in again.")
        case .loggedOut: L("Not connected")
        }
        connectButton.isHidden = state == .connected
        logoutButton.isHidden = state == .loggedOut
    }

    @objc private func connect() {
        TradeRepublicLoginWindowController.show { [weak self] in self?.onChange(.broker) }
    }

    @objc private func logOut() {
        TradeRepublic.shared.logOut()
        onChange(.broker)
    }
}
