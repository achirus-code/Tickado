import AppKit

/// Tab "Trade Republic": Login mit Handynummer + PIN, Bestätigung per Push oder Authenticator-Code, Logout.
final class TradeRepublicSettingsViewController: SettingsPane {
    private let tr = TradeRepublic.shared

    private let statusLabel = NSTextField(labelWithString: "")
    private let phoneField = NSTextField()
    private let pinField = NSSecureTextField()
    private let codeField = NSTextField()
    private lazy var loginButton = NSButton(title: L("Log In"), target: self, action: #selector(logIn))
    private lazy var logoutButton = NSButton(title: L("Log Out"), target: self, action: #selector(logOut))
    private lazy var codeButton = NSButton(title: L("Confirm"), target: self, action: #selector(submitCode))
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var grid: NSGridView?

    private var process: TradeRepublic.LoginProcess?
    private var loginTask: Task<Void, Never>?
    private var countdown: Timer?

    // Zeilen im Formular
    private let phoneRow = 1, pinRow = 2, codeRow = 5

    override func loadView() {
        phoneField.placeholderString = "+49 170 1234567"
        phoneField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        pinField.placeholderString = "••••"
        pinField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        codeField.placeholderString = "123456"
        codeField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        for field in [phoneField, pinField, codeField] {
            field.target = self
            field.action = #selector(fieldReturn(_:))
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 300
        message.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let buttons = NSStackView(views: [loginButton, logoutButton, spinner])
        buttons.spacing = 8
        let code = NSStackView(views: [codeField, codeButton])
        code.spacing = 8

        let root = makeForm([
            (L("Status:"), statusLabel),
            (L("Phone number:"), phoneField),
            (L("PIN:"), pinField),
            (nil, buttons),
            (nil, message),
            (L("Authenticator code:"), code),
        ], groups: [1, 3])
        grid = root.subviews.first as? NSGridView

        let disclaimer = NSTextField(wrappingLabelWithString: L(
            "Uses the unofficial Trade Republic web interface, which can change at any time. Tickado is not affiliated with Trade Republic. Your PIN is only sent to Trade Republic to log in and is not stored."))
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
        if phoneField.stringValue.isEmpty { phoneField.stringValue = prefs.trPhone ?? "" }
        updateState()
    }

    private var isLoggingIn: Bool { loginTask != nil || process != nil }

    private func updateState() {
        let connected = tr.state == .connected
        statusLabel.stringValue = switch tr.state {
        case .connected: L("Connected")
        case .expired: L("Session expired. Please log in again.")
        case .loggedOut: L("Not connected")
        }
        grid?.row(at: phoneRow).isHidden = connected
        grid?.row(at: pinRow).isHidden = connected
        grid?.row(at: codeRow).isHidden = !(process?.needsCode ?? false)
        loginButton.isHidden = connected
        logoutButton.isHidden = tr.state == .loggedOut
        for control in [phoneField, pinField, loginButton] as [NSControl] { control.isEnabled = !isLoggingIn }
        isLoggingIn ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    // MARK: - Aktionen

    @objc private func fieldReturn(_ sender: NSTextField) {
        sender === codeField ? submitCode() : logIn()
    }

    @objc private func logIn() {
        guard !isLoggingIn else { return }
        // Leerzeichen, Bindestriche und Klammern entfernen; "0170…" als deutsche Nummer deuten.
        var phone = phoneField.stringValue.filter { $0.isNumber || $0 == "+" }
        if phone.hasPrefix("00") { phone = "+" + phone.dropFirst(2) }
        if phone.hasPrefix("0") { phone = "+49" + phone.dropFirst() }
        let pin = pinField.stringValue
        guard phone.hasPrefix("+"), phone.count >= 9, pin.count == 4, pin.allSatisfy(\.isNumber) else {
            message.stringValue = L("Enter your phone number (e.g. +49 170 1234567) and your 4-digit PIN.")
            return
        }
        prefs.trPhone = phone
        phoneField.stringValue = phone
        pinField.stringValue = ""
        message.stringValue = L("Logging in…")
        run {
            let process = try await $0.tr.startLogin(phone: phone, pin: pin)
            $0.process = process
            $0.startCountdown()
            // Mit Authenticator wartet der Login auf den Code (submitCode).
            guard !process.needsCode else { return false }
            try await $0.tr.awaitConfirmation(process)
            return true
        }
    }

    @objc private func submitCode() {
        guard let process, process.needsCode, loginTask == nil else { return }
        let code = codeField.stringValue.filter(\.isNumber)
        guard !code.isEmpty else { return }
        codeField.stringValue = ""
        run {
            try await $0.tr.submitCode(code, for: process)
            try await $0.tr.awaitConfirmation(process)
            return true
        }
    }

    @objc private func logOut() {
        cancelLogin()
        tr.logOut()
        message.stringValue = ""
        onChange(.broker)
        updateState()
    }

    /// Führt einen Login-Schritt aus; `true` = Login abgeschlossen, `false` = wartet auf Eingabe.
    private func run(_ step: @escaping @MainActor (TradeRepublicSettingsViewController) async throws -> Bool) {
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let done = try await step(self)
                self.loginTask = nil
                if done { self.finish(error: nil) } else { self.updateState() }
            } catch {
                self.loginTask = nil
                if !(error is CancellationError) { self.finish(error: error) }
            }
        }
        updateState()
    }

    private func finish(error: Error?) {
        countdown?.invalidate()
        countdown = nil
        process = nil
        if let error {
            message.stringValue = L("Login failed: %@", error.localizedDescription)
        } else {
            message.stringValue = ""
            onChange(.broker)
        }
        updateState()
    }

    private func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        countdown?.invalidate()
        countdown = nil
        process = nil
    }

    /// Hinweis mit Restzeit, solange auf die Bestätigung gewartet wird.
    private func startCountdown() {
        countdown?.invalidate()
        let tick = { [weak self] in
            guard let self, let process = self.process else { return }
            let left = max(Int(process.deadline.timeIntervalSinceNow), 0)
            let time = String(format: "%d:%02d", left / 60, left % 60)
            self.message.stringValue = process.needsCode
                ? L("Enter the code from your authenticator app (%@).", time)
                : L("Confirm the login in your Trade Republic app (%@).", time)
        }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        countdown = timer
    }
}
