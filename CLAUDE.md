# Tickado – Projektwissen für Claude

macOS-Menüleisten-App (AppKit, Swift, SwiftPM, macOS 14+), die Kurse für Krypto, Aktien, ETFs und Edelmetalle anzeigt. Die Nutzerdoku steht in `ANLEITUNG.md`.

## Zusammenarbeit
- Der Nutzer schreibt Deutsch → auf Deutsch antworten.
- Die App-Oberfläche ist **mehrsprachig** (Quelltexte Englisch, siehe „Übersetzung“). Code-Kommentare sind **Deutsch**, kurz und nur dort, wo etwas nicht offensichtlich ist.
- Das Aussehen wurde nach Screenshots einer Vorlage-App **pixelgenau** nachgebaut (siehe „Designwerte“). Diese Werte nicht „aufräumen“ oder runden.

## Bauen und Testen
- `./build.sh` baut `Tickado.app` (release, ad-hoc signiert). `./build.sh install` installiert nach `/Applications` und startet die App neu.
- Es gibt nur die Command Line Tools, **kein Xcode** und keine Xcode-Projekte. Deshalb SwiftPM mit `swift-tools-version:5.10` (Swift-5-Sprachmodus).
- **Cloud-/Linux-Sitzungen:** AppKit fehlt dort, also ist weder Bauen noch Starten möglich. Änderungen sorgfältig per Code-Review prüfen, und der Nutzer testet lokal mit `git pull && ./build.sh install`. Im Pull Request klar sagen, dass nicht kompiliert wurde.
- Lokal hat Claude keine Rechte für Bildschirmaufnahme oder Bedienungshilfen, sieht also die echte Menüleiste nicht. Bewährt hat sich:
  - Logik (Formatierung, API-Decoding) in einem Harness im Scratchpad testen: Quelldateien kopieren, eine `main.swift` dazu, `swiftc`, dann mit `-AppleLocale de_DE` ausführen.
  - Zeichnungen (Ticker-Bild, Icon) offscreen in eine PNG rendern und ansehen.

## Architektur
- `TickadoApp.swift`: `@main` mit `NSApplication`, Aktivierungsmodus `.accessory` (`LSUIElement`) und einem unsichtbaren Hauptmenü. Ohne dieses Menü funktionieren ⌘C/⌘V/⌘A in Textfeldern nicht.
- `StatusController.swift`: Das Herzstück der App.
  - NSStatusItem mit NSMenu; `menuNeedsUpdate` baut das Menü jedes Mal neu.
  - Refresh-Timer und Rotations-Timer laufen im `.common`-RunLoop-Modus, damit sie auch bei offenem Menü weiterlaufen.
  - Ein Refresh fragt CoinGecko (Krypto) und Yahoo (alles andere) parallel ab (`async let`, damit ein neuer Refresh die alte Anfrage abbricht). Jeder Refresh schiebt den Refresh-Timer um ein volles Intervall nach hinten.
  - Schlägt eine Quelle fehl, bleiben ihre alten Kurse erhalten. Jeder `Quote` merkt sich `updated`. Ist er älter als 3 Intervalle + 60 s, wird er grau (`TickerRenderer.staleBefore`), und zwar pro Kurs, nicht global.
  - `ClosureMenuItem` ist ein NSMenuItem mit Closure statt Target/Action.
  - Das Menü hat keine Options-Untermenüs, nur „Settings…“. „Select Coins…“ und „Refresh Now“ wurden auf Wunsch des Nutzers entfernt (Auswahl im Tab *Assets*).
  - `settingsDidChange(_:)` erledigt die Folgeschritte einer Einstellung (Timer neu, Kurse verwerfen, Refresh). `updateTitle()` aktualisiert auch die Vorschau.
- `TickerRenderer.swift`: Zeichnet Ticker (Text oder kompaktes Bild) und Menüzeilen. Menüleiste und Vorschau nutzen denselben Code, deshalb Designänderungen nur hier.
- `SettingsWindowController.swift`:
  - Fenster mit fester Größe (nicht resizable) und fester Vorschau oben (nachgebaute Menüleiste + aufgeklapptes Menü mit bis zu 5 Zeilen) und `NSTabViewController` (Display | Assets | General | Trade Republic) darunter.
  - Formulare als `NSGridView` mit Auswahlboxen und Checkboxen. Änderungen wirken sofort, kein Speichern-Knopf.
  - Die Vorschau zeigt die echten Kurse (`StatusController.previewState`). Ist nichts angehakt, zeigt sie ein Beispiel aus der Auswahl.
  - Tab *Display* → *Menu bar*: `TickerChoiceList` mit allen ausgewählten Werten und Checkbox für `tickerIDs` (gleich wie ein Klick im Menü, beides über `SettingsChange.ticker`).
- `Localization.swift` (Übersetzung):
  - Jeder sichtbare Text läuft durch `L("English text")` bzw. `L("… %@ …", arg)`. Schlüssel ist der englische Text, fehlt eine Übersetzung, erscheint Englisch.
  - Die Übersetzungen liegen in `Translations/Strings+<code>.swift` (25 Sprachen inkl. Englisch, nur links-nach-rechts). **Neuer Text → in allen 24 Dateien ergänzen.** Platzhalter müssen übereinstimmen; bei anderer Wortstellung `%1$@`/`%2$@`.
  - `Prefs.language` (nil = System) ruft `L10n.apply`. `L10n.systemLanguage` nimmt die erste passende Sprache aus `Locale.preferredLanguages` (zh → Hans/Hant, no/nn → nb).
  - Nur die Texte folgen der Sprache. Zahlen und Preise bleiben bei der Region des Systems. Währungsnamen kommen von `Locale.localizedString(forCurrencyCode:)`, Intervalle vom `DateComponentsFormatter`, Metallnamen über `Coin.displayName`.
  - Ein Sprachwechsel baut das Settings-Fenster neu auf (`StatusController.rebuildSettings`), das Menü wird ohnehin bei jedem Öffnen neu gebaut.
- `TradeRepublic.swift` (Depot; inoffizielle Web-API wie pytr, keine offizielle API):
  - **Modell „einmal synchronisieren“ (Wunsch des Nutzers):** „Synchronize…“ öffnet `TRWebSession` (WKWebView mit **nicht persistentem** Speicher → jedes Mal frische Anmeldung auf app.traderepublic.com/login). Nach dem Login werden Positionen (ISIN, Name, Stück, Ø-Kaufkurs) und Guthaben einmal geholt und in `Prefs.trHoldings`/`trCash`/`trSyncDate` gespeichert, dann Fenster zu, Sitzung weg. Kein Hintergrundbetrieb.
  - Nutzereinstellungen je Position: `TRHolding.customName` (Umbenennen, `displayName`) und `hidden` (abgewählt: nicht im Menü, nicht in Summen, keine Kursabfrage). Settings-Liste `HoldingsList` (Klick ins Namensfeld bearbeitet sofort, `ClickToEditTableView`). Beim Synchronisieren per ISIN übernommen; `TRHolding` dekodiert beide Felder mit `decodeIfPresent`.
  - Laufende Kurse von **Yahoo** in Euro: `YahooFinance.symbol(forISIN:)` (bei der Synchronisierung, Euro-Börsen bevorzugt, sonst Heimatbörse) → `TRHolding.symbol`; `StatusController.refreshDepot()` holt `YahooFinance.quotes(currency: "eur")`, `TradeRepublic.portfolio(quotes:)` baut daraus `TRPortfolio` (Vortagesschluss aus `change24h` zurückgerechnet).
  - Abfragen laufen per `callAsyncJavaScript` **aus der eingeloggten Seite** (`fetchJSON`, `subscribe` öffnet dort einen WebSocket). Nachgebaute Anfragen von außen hatte Trade Republic abgelehnt.
  - Login-Erkennung: KVO auf `webView.url` (Web-App wechselt per `pushState` ohne Neuladen) plus Timer alle 2 s; Pfad ohne „login“ → `GET /api/v2/auth/account` aus der Seite; 200 → Abruf. Schließt der Nutzer das Fenster, endet die Synchronisierung ohne Änderung.
  - WebSocket-Protokoll: `connect 31 {…}` → `connected`; `sub N {json}` → `N A <json>` / `N E <fehler>`. Themen: `compactPortfolioByType` (secAccNo aus account, Fallback `compactPortfolio`), `instrument` (Name), `cash`. `TRProtocol` ist reine Logik und im Harness testbar.
  - Depotkennzahlen `DepotTicker` (`tr:value`, `tr:today`, `tr:total`; in der Menüleiste „TR“, „TRΔ“, „TRΣ“ – kurz auf Wunsch des Nutzers) sind Pseudo-`Coin`s: Häkchen in `Prefs.trTickerItems` (eigene Liste, weil `tickerIDs` auf die Auswahl gefiltert wird), `TickerRenderer.depotLine` zeichnet sie. Gewinn heute = Σ (Kurs − Vortag) × Stück, gesamt = Σ (Kurs − Ø-Kaufkurs) × Stück.
  - Diagnose ohne Cookies/PIN/Beträge: `TRLog` → `~/Library/Logs/Tickado/TradeRepublic.log`. Getestet gegen einen lokalen Nachbau (Auto-Modus blockt Zugriffe auf die echten TR-Server), Yahoo echt.
- `Models.swift`:
  - `Coin` steht für **jeden** Kurswert, nicht nur Coins. Die Art unterscheidet `AssetKind` (`.crypto`, `.stock`, `.etf`, `.metal`).
  - IDs: CoinGecko-ID (`bitcoin`), `stock:SAP.DE`, `etf:EUNL.DE`, `metal:gold`.
  - `kind` wird mit `decodeIfPresent` gelesen, Standard `.crypto`, weil alte Einstellungen es noch nicht kennen.
- `Prefs.swift`: UserDefaults (Bundle-ID `de.achirus.tickado`). `selectedCoins` wird als JSON gespeichert und nach dem ersten Lesen im Speicher gehalten (nur über `Prefs` ändern, `defaults write` wirkt erst nach einem Neustart). `tickerIDs` enthält die Werte mit Häkchen.
- `PriceFormat.swift`:
  - Signifikante Stellen: 84.150 · 1,53 · 0,0398 bei 3 Stellen. Ganzzahlen werden nie abgeschnitten.
  - Das Währungszeichen wird locale-gerecht gesetzt (`84.150 $` auf Deutsch, `$84,150` auf Englisch).
  - Kürzen ab 1.000 mit höchstens einer Nachkommastelle, **abgeschnitten** statt gerundet (2.663 → 2,6K).
  - Die Prozentänderung hat immer einen Punkt als Dezimalzeichen und ein echtes Minus „−“ (wie im Vorbild).
- `CoinGecko.swift`:
  - Ohne Key die öffentliche API. Demo-Key: Header `x-cg-demo-api-key`. Pro-Key: `pro-api.coingecko.com` mit Header `x-cg-pro-api-key`.
  - `CatalogStore` cacht die Top 500 für einen Tag in `~/Library/Application Support/Tickado/catalog.json`.
- `YahooFinance.swift`:
  - Kurse über `v8/finance/chart/<SYM>?range=1d&interval=1d`, genutzt werden `regularMarketPrice` und `chartPreviousClose`.
  - Suche über `v1/finance/search`, gefiltert nach `quoteType` (ETF-Tab nur `ETF`, Aktien-Tab `EQUITY`/`INDEX`/`MUTUALFUND`).
  - Umrechnung in die Basiswährung über `XXXYYY=X`. Für BTC/ETH/sats geht es über USD und `BTC-USD`/`ETH-USD`.
  - Kurse in Pence (`GBp`, `ILA`, `ZAc`) werden durch 100 geteilt.
  - Edelmetalle: Future-Kurse `GC=F`, `SI=F`, `PL=F`, `PA=F`, je Feinunze, umgerechnet mit `MetalUnit.factor`.
- `CoinPickerViewController.swift`:
  - Tab *Assets* im Settings-Fenster mit Arten-Umschalter, Filter, „hide unselected“ und einer Tabelle (Checkbox | Symbol | Name).
  - Online-Suche mit Debounce. Treffer merken sich die Suchanfrage (`remoteQuery`/`remoteMatches`), damit ISIN-Treffer nicht vom lokalen Filter ausgeblendet werden.
- `Keychain.swift`: Der Key wird einmal pro Start gelesen und dann gecacht. Sonst fragt macOS bei ad-hoc signierten Builds womöglich bei jedem Zugriff nach.

## Designwerte (pixelgenau nach Vorbild, nicht ändern ohne Auftrag)
- **Farben:** Grün `#74C73D`, Rot `#C04828`, beide als **Display P3** (`NSColor(displayP3Red:…)`). Für den hellen Modus gibt es etwas dunklere Varianten.
- **Ticker (einzeilig):** `monospacedDigitSystemFont`, Menüleistenschrift − 0,7 pt (13 → 12,3 pt). 3 Leerzeichen zwischen den Werten. Symbol in `labelColor`, Preis farbig.
- **Grüne Werte** sind 0,5 pt kleiner als rote, weil Grün optisch größer wirkt (`ColorTheme.isGreen`). Das gilt im Ticker und im Menü.
- Der ganze Ticker hat `baselineOffset −0,5` (1 px tiefer, auf Wunsch des Nutzers).
- **Kompakter Ticker:** wird als NSImage gezeichnet (Schrift 9 pt, zwei Zeilen). ▲/▼ sind gezeichnete Dreiecke, weitere Paare kommen als Spalten daneben.
- **Menüzeilen:** **Menlo 12 pt** (Grün: Menlo 11,5). Tab-Spalten in Zeichenbreiten: Name ab 7, Preis rechtsbündig bis 28, Änderung rechtsbündig bis 36. Der Name wird gekürzt, damit er nicht in die Preisspalte läuft.
- Das Menü hat **keine Tastenkürzel** (⌘R/⌘Q entfernt), weil deren Spalte das Menü rechts unnötig breit macht.
- **App-Icon:** `Scripts/make-icon.swift` zeichnet dunkle Kachel, grün-rote Kerzen und eine goldene Münze mit Aufwärtskurve. `build.sh` erzeugt das Icon nur, wenn `Resources/AppIcon.icns` fehlt.

## Stolpersteine
- Im Code erzeugte `NSTableView` in einer `NSScrollView` wächst beim ersten Layout um die Höhe des sichtbaren Bereichs (flexible Höhe, von der Tabelle selbst gesetzt, `autoresizingMask` lässt sich nicht dauerhaft ändern). Folge: eine Seite leerer Zeilen zum Weiterscrollen. Abhilfe: nach dem Layout `tableView.tile()` (siehe `layout()`/`viewDidLayout()` der drei Listen).
- `JSONDecoder.convertFromSnakeCase` macht aus `price_change_percentage_24h` den Namen `priceChangePercentage24H` (großes **H**). Deshalb braucht `CoinGecko.Market` explizite `CodingKeys`. Ohne sie ist die Änderung immer `nil` und alles bleibt weiß.
- Yahoo blockt Anfragen ohne User-Agent, aber auch mit langem Browser-UA. `Mozilla/5.0` funktioniert.
- `.urlQueryAllowed` lässt `&`, `=` und `+` unkodiert. Suchtexte für Yahoo deshalb mit `YahooFinance.queryAllowed` kodieren (sonst wird aus „S&P 500“ die Suche nach „S“).
- Die öffentliche CoinGecko-API hat ein knappes Rate-Limit (HTTP 429). Das Standardintervall ist deshalb 60 s, und der Katalog wird gecacht.
- `LaunchAtLogin` (SMAppService) sollte erst eingeschaltet werden, wenn die App in `/Applications` läuft.
- `statusItem.menu` ist gesetzt. Das Settings-Fenster wird deshalb per `DispatchQueue.main.async` erst nach dem Schließen des Menüs geöffnet.
- `NSApp.activate()` ist seit macOS 14 nur eine Bitte und wird bei Menüleisten-Apps manchmal ignoriert. Fenster deshalb mit `NSWindow.bringToFront()` öffnen (zusätzlich `orderFrontRegardless`), sonst gehen sie gelegentlich hinter anderen Apps auf.
