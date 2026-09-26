# Tickado – Anleitung

Tickado ist eine macOS-Menüleisten-App (ab macOS 14), die Kurse von Kryptowährungen, Aktien, ETFs und Edelmetallen direkt in der Menüleiste anzeigt.

---

## 1. Was die App kann

### Menüleiste (Ticker)
- Zeigt die angehakten Werte, z. B. `₿ 84.213   Ξ 2.676`. Anhaken unter Settings… → Display → *Menu bar* oder per Klick im Menü.
- Farbe nach 24h-Änderung: Grün `#74C73D` = steigend, Rot `#C04828` = fallend (Display P3, exakt vom Vorbild übernommen).
- Drei Anzeigemodi (Settings… → Display → *Menu bar*):
  - **Show All Checked Coins** – alle angehakten Werte nebeneinander
  - **Rotate Checked Coins (5 s)** – immer ein Wert, wechselt alle 5 Sekunden
  - **Compact: Two Rows with ▲▼** – je zwei Werte untereinander mit Pfeil, weitere Paare als Spalten daneben
- Weitere Ticker-Optionen: Zeichen statt Kürzel (₿, Ξ, Au, Ag …), Währungszeichen, 24h-Änderung, nur 24h-Änderung ohne Kurs (z. B. `₿ −0.3%`), Kürzen großer Preise (84,2K / 2,6K), Update-Intervall (30 s – 30 min).
- Hat der Ticker länger keine neuen Kurse bekommen (z. B. offline), werden die Preise grau. Nach dem Aufwachen aus dem Ruhezustand wird automatisch neu geladen.

### Settings-Fenster
Öffnet sich über **Settings…** im Menü. Oben steht immer eine **Vorschau**: eine nachgebaute Menüleiste mit dem Ticker und darunter das aufgeklappte Menü (bis zu 5 Zeilen), gezeichnet mit echten Kursen und exakt demselben Code wie die echte Menüleiste. Jede Änderung ist sofort in Vorschau und Menüleiste sichtbar, ein „Speichern“ gibt es nicht. Ist noch nichts für die Menüleiste angehakt, zeigt die Vorschau ein Beispiel aus der Auswahl.

- **Display**
  - Menu bar: Liste aller ausgewählten Werte mit Checkbox „in der Menüleiste zeigen“ (wie ein Klick im Menü), darunter die Auswahlbox für den Anzeigemodus (siehe oben)
  - Checkboxen: Coin-Zeichen (₿, Ξ, Au), Währungszeichen, 24h-Änderung, nur 24h-Änderung ohne Kurs (dann sind Währungszeichen, 24h-Änderung und Kürzen ausgegraut), große Preise kürzen
  - Colors: Farbschema (Grün/Rot, Rot/Grün, Blau/Orange für Farbenblinde, Monochrom)
  - Precision: 2–6 signifikante Stellen, mit Beispielen
  - Menu: 24h-Änderung in der Kursliste
- **Assets** – Auswahl mit Tabs *Crypto | Stocks | ETFs | Metals*, Filterfeld und „hide unselected“
  - Crypto: Top 500 nach Marktkapitalisierung + Suche in allen CoinGecko-Coins
  - Stocks: beliebte US- und DAX-Aktien + Indizes, Suche nach Name/Ticker
  - ETFs: beliebte ETFs (XETRA + US), Suche nach Name, Ticker oder ISIN
  - Metals: Gold, Silber, Platin, Palladium
- **General**
  - Language: 25 Sprachen. Standard ist „System“: Tickado nimmt die erste bevorzugte Sprache aus den macOS-Einstellungen, die es kann, sonst Englisch. Ein Wechsel wirkt sofort.
  - Base currency (USD, EUR, CHF, GBP, … sowie BTC, ETH, sats)
  - Metal unit (Feinunze, Gramm, Kilogramm)
  - Update every (30 s – 30 min)
  - Launch at login
  - CoinGecko API key: Status und „Configure…“ (optional; Demo- oder Pro-Key, gespeichert im Schlüsselbund)

Das Fenster hat eine feste Größe, merkt sich seine Position und lässt sich mit ⌘W schließen.

### Menü
- **Settings…** – öffnet das Settings-Fenster (Tab *Display*)
- **Kursliste** – Symbol, Name, Preis, 24h-Änderung in Spalten; gruppiert nach Krypto / Metalle / Aktien / ETFs
  - Klick = in der Menüleiste an-/abwählen (Häkchen)
  - ⌥ + Klick = Wert auf CoinGecko bzw. Yahoo Finance öffnen
- About…, Quit

### Datenquellen
- **Krypto:** CoinGecko API (ohne Key nutzbar, mit Key zuverlässiger)
- **Aktien, ETFs, Edelmetalle, Wechselkurse:** Yahoo Finance (inoffizielle API, kein Key). Edelmetalle sind COMEX-Future-Kurse.

---

## 2. Lokal bauen und installieren (auf dem Mac)

```bash
cd ~/Kunden/Privat/Tickado
./build.sh            # baut Tickado.app im Projektordner
./build.sh install    # baut, installiert nach /Applications und startet neu
```

Voraussetzung: Xcode Command Line Tools (`swift`). Ein volles Xcode ist nicht nötig.

---

## 3. In der Cloud weitermachen (mit Claude auf GitHub)

Claude in der Cloud (claude.ai/code) arbeitet direkt auf deinem GitHub-Repository. Dafür muss das Projekt einmalig auf GitHub liegen.

### Schritt 1 + 2 – Repository und erster Push ✅ erledigt
Das Projekt liegt privat auf GitHub: **https://github.com/achirus-code/Tickado** (Branch `main`).
Auf diesem Mac ist die GitHub-CLI `gh` installiert und als `achirus-code` angemeldet, `git push`/`git pull` funktionieren ohne weitere Anmeldung.

Eigene lokale Änderungen hochladen:

```bash
cd ~/Kunden/Privat/Tickado
git add -A
git commit -m "Kurze Beschreibung der Änderung"
git push
```

### Schritt 3 – Claude in der Cloud verbinden
1. **claude.ai/code** öffnen (oder im Claude-Desktop-Programm eine Cloud-Sitzung starten)
2. GitHub verbinden (Konto `achirus-code`) und Claude Zugriff auf das Repository `Tickado` geben
3. Repository auswählen und die Aufgabe beschreiben, z. B.
   *„Füge im Ticker-Menü eine Option für 3 Zeilen in der kompakten Ansicht hinzu.“*
4. Claude liest automatisch `CLAUDE.md` und kennt damit Aufbau, Designentscheidungen und Stolpersteine der App.
5. Claude arbeitet auf einem eigenen Branch und kann einen Pull Request erstellen.

### Schritt 4 – Änderungen auf den Mac holen und testen
Die Cloud-Umgebung ist **Linux**. Dort kann Claude den Code bearbeiten, eine macOS-App (AppKit) aber **weder bauen noch starten**. Getestet wird deshalb immer lokal:

```bash
cd ~/Kunden/Privat/Tickado
git fetch
git switch <branch-von-claude>   # oder nach dem Mergen des Pull Requests: git switch main
git pull
./build.sh install
```

Passt alles, den Pull Request auf GitHub mergen.

### Optional – automatischer Build-Check auf GitHub
Damit Fehler in Cloud-Änderungen sofort auffallen, kann ein GitHub-Actions-Workflow die App bei jedem Push auf einem macOS-Runner kompilieren (`swift build -c release`). Claude kann diesen Workflow auf Wunsch anlegen („Lege einen GitHub-Actions-Build für macOS an“).

---

## 4. Projektstruktur

| Datei | Inhalt |
|---|---|
| `Sources/Tickado/TickadoApp.swift` | Einstiegspunkt, AppDelegate, unsichtbares Edit-Menü (für ⌘C/⌘V) |
| `Sources/Tickado/StatusController.swift` | Menüleisten-Ticker, Menü, Abfrage-Timer |
| `Sources/Tickado/TickerRenderer.swift` | Zeichnet Ticker und Menüzeilen (Menüleiste und Vorschau) |
| `Sources/Tickado/SettingsWindowController.swift` | Settings-Fenster mit Vorschau und Tabs Display / Assets / General |
| `Sources/Tickado/CoinPickerViewController.swift` | Tab *Assets* (Arten, Filter, Tabelle) |
| `Sources/Tickado/Localization.swift` | Sprachwahl, Systemsprache, `L("…")` für übersetzte Texte |
| `Sources/Tickado/Translations/Strings+<Sprache>.swift` | Übersetzungen, eine Datei je Sprache |
| `Sources/Tickado/Models.swift` | Datenmodell (`Coin`, `AssetKind`, Metalle, Währungen, Farben) |
| `Sources/Tickado/Prefs.swift` | Einstellungen (UserDefaults) |
| `Sources/Tickado/PriceFormat.swift` | Preis- und Prozentformatierung |
| `Sources/Tickado/CoinGecko.swift` | CoinGecko-Client + Coin-Katalog-Cache |
| `Sources/Tickado/YahooFinance.swift` | Aktien/ETFs/Metalle, Suche, Wechselkurse |
| `Sources/Tickado/APIKeyPrompt.swift` | Dialog für den CoinGecko-Key |
| `Sources/Tickado/Keychain.swift` | API-Key im Schlüsselbund |
| `Sources/Tickado/LaunchAtLogin.swift` | Autostart (SMAppService) |
| `Scripts/make-icon.swift` | Zeichnet das App-Icon → `Resources/AppIcon.icns` |
| `build.sh` | Build, App-Bundle, Signatur, Installation |
| `CLAUDE.md` | Projektwissen für Claude |
