# Porridge · Design-Migration — Spec & Richtungskarten

## Spec
- **Was**: Porridge, lokale KI-Transkription für Meetings & Notizen (iPhone/iPad/Mac, SwiftUI). Alles bleibt auf dem Gerät.
- **Auftrag**: komplette UI auf ein neues, einziges Design migrieren. Design-Umschaltung (playful/classic) entfällt.
- **Bestehende Marke (fix)**: App-Icon Porridge-Schale, BrandSky `#24B4E9`, BrandNavy `#1F3667`, Bowl-Asset.
- **Kernscreens**: Timeline (Notizen + Meetings, gepinnt, nach Datum), Notiz-Detail (Markdown + Inline-Diktat), Meeting-Detail (Sprecher, Transkript, Zusammenfassung, Player), Aufnahme (Live-Transkript), Chat über Notizen, Einstellungen.
- **Constraint (User-Präferenz, 2026-10-27)**: möglichst native SwiftUI-Elemente (List, Menu, TabView, Toolbar, Picker) — Richtung wird über Tokens/Styles auf native Controls gelegt, kein Custom-Drawing.
- **Format der Entwürfe**: HTML-Prototyp, iPhone 17 Pro, 4 Screens pro Richtung, klickbar.
- **Ton**: ruhig, privat, alltäglich (Porridge = einfaches Frühstück), aber mit Charakter.

## Sechs Kandidaten

1. **Bester Designer · Kenya Hara (still)** — Reisweiß `#F7F6F2`, Navy nur als Tinte, Sky als einziger Akzent (Aufnahme, Auswahl). Haarlinien statt Karten, kleine Schrift, viel Luft. Hauptdarsteller: der Text selbst. Mut: fast keine Farbe. Form: Porridge ist schlichtes Essen.
2. **Bester Designer · Collins (laut)** — Sky vollflächig, Navy-Schrift groß & rund, Schale als Figur mit dicker Kontur. Weiterentwicklung des „playful". Mut: Sky als Bühne. Form: das Icon wird zur Welt.
3. **Realreferenz · Things 3 (ADA)** — Weiß, Haarlinien ab Checkbox eingerückt, große Titel, schwebende Detailkarte, runder Sky-Plus. Mut: Detail als schwebende Karte. Form: Notizen sind Alltagswerkzeug. *(Referenz nicht per Screenshot gesehen — Playwright-Python fehlt; aus Kenntnis.)*
4. **Realreferenz · Bear (ADA 2017)** — warmes Papier, Serif-Titel (New York), Notizliste nur Text + Zwei-Zeilen-Auszug, Akzent Sky statt Bear-Rot. Mut: Typografie trägt. Form: Markdown-Notizen. *(nicht per Screenshot gesehen.)*
5. **Rad App #11 · Gentle Encouragement (dunkel)** — Nachtblau-Verlauf aus BrandNavy, 28-pt-Karten, SF Rounded, Sky + Minze + Pfirsich als Pastell-Sprecherfarben, Aufnahme als weiche Wellenlinie. Mut: dunkel als Standard. Form: Navy ist schon die Markenfarbe.
6. **Rad East #11 · Sato Minimal Symbol** — die Schale als Symbol nimmt die halbe Fläche (Sky, flach), andere Hälfte weiß, Navy fett, max. 3 Farben, Datenzeilen mit dicken Oberlinien. Mut: Symbol halbseitig. Form: eine Marke, ein Zeichen.
