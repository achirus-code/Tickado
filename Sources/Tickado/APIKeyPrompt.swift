import AppKit

/// Dialog "Configure CoinGecko API Key…".
@MainActor
enum APIKeyPrompt {
    static func run(onChange: @escaping () -> Void) {
        let prefs = Prefs.shared
        let existing = Keychain.apiKey

        let alert = NSAlert()
        alert.messageText = L("CoinGecko API Key")
        alert.informativeText = L("Tickado works without a key using CoinGecko's public API, which is rate-limited. A free Demo key from coingecko.com/en/api gives more reliable updates.")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let kind = NSPopUpButton(frame: NSRect(x: -3, y: 32, width: 306, height: 26), pullsDown: false)
        kind.addItems(withTitles: [L("Demo API Key (free)"), L("Pro API Key (paid plan)")])
        kind.selectItem(at: prefs.apiKeyKind == .pro ? 1 : 0)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = existing ?? ""
        field.placeholderString = "CG-…"
        accessory.addSubview(kind)
        accessory.addSubview(field)
        alert.accessoryView = accessory

        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        if existing != nil { alert.addButton(withTitle: L("Remove Key")) }
        alert.window.initialFirstResponder = field

        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            prefs.apiKeyKind = kind.indexOfSelectedItem == 1 ? .pro : .demo
            Keychain.apiKey = key.isEmpty ? nil : key
            onChange()
            if !key.isEmpty { verify() }
        case .alertThirdButtonReturn:
            Keychain.apiKey = nil
            onChange()
        default:
            break
        }
    }

    /// Key direkt testen und nur bei einem Fehler melden.
    private static func verify() {
        let client = CoinGecko.current
        Task {
            do {
                try await client.ping()
            } catch {
                NSApp.activate()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("The API key could not be verified")
                alert.informativeText = error.localizedDescription + "\n\n" + L("Check the key and whether it is a Demo or Pro key.")
                alert.runModal()
            }
        }
    }
}
