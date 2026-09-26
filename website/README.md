# Tickado – Präsentationsseite / Landing page

Statische Landingpage, die Tickado vorstellt. Eine einzelne Datei ohne externe Abhängigkeiten,
dazu nur das Favicon (`favicon-32.png`, `apple-touch-icon.png`, aus `Resources/AppIcon.icns` ohne den macOS-Rand).
Static landing page presenting Tickado. A single file with no external dependencies, plus the favicon images.

## Ansehen / Preview
`website/index.html` im Browser öffnen, oder lokal servieren / open in a browser, or serve locally:

```bash
cd website
python3 -m http.server 8000   # http://localhost:8000
```

## Merkmale / Highlights
- **Zweisprachig DE/EN** – Umschalter oben rechts, merkt die Wahl und folgt sonst der Browsersprache.
- **Hell/Dunkel** folgt dem System, per Schalter umstellbar.
- **Echte Mockups** von Menü und Settings-Fenster, nachgebaut nach den App-Screenshots.
- Das App-Icon ist als Inline-SVG nachgebaut (dunkle Kachel, grün-rote Kerzen, Goldmünze), passend zu `Scripts/make-icon.swift`.
- **Nur Download**: Der Button verweist auf die fertige App unter GitHub Releases – keine Bau-Anleitung.

## Download-Link / Download link
Der Button zeigt auf `https://github.com/achirus-code/Tickado/releases/latest`.
Dort muss ein Release mit der gebauten `Tickado.app` (z. B. als `.zip` oder `.dmg`) hinterlegt sein.

## Veröffentlichen (GitHub Pages)
**Settings → Pages** → Branch wählen und als Ordner `/website` angeben
(oder den Inhalt nach `/docs` bzw. in einen `gh-pages`-Branch legen).
