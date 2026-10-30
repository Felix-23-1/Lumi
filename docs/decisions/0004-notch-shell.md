# 0004: Notch-Kapsel statt klassischem Fenster

**Entscheidung:** Das Hauptfenster aus BAUPLAN.md Abschnitt 11 ("links Chat,
rechts Reiter") wurde auf expliziten Wunsch des Nutzers durch eine
rahmenlose, transparente Kapsel ersetzt, die oben zentriert unter der
MacBook-Notch sitzt — eingeklappt nur ein winkendes Maskottchen, per Klick
aufklappend zu einem zweispaltigen Board (links Gesicht + Status, rechts der
Inhalt des aktiven Reiters). Vorbild: die App "Coucou"
(https://louis-cfm.github.io/coucou/), eigenständig umgesetzt (eigenes
Maskottchen, eigene Farben, keine übernommene Marke).

**Warum:** Nutzerwunsch in der laufenden Sitzung, nachdem die App bereits
funktionsfähig auf dem Mac installiert und getestet war (Abweichung vom
ursprünglichen BAUPLAN ist hier bewusst dokumentiert, nicht übersehen).

**Technische Umsetzung:**
- `src/main/index.ts`: `BrowserWindow` mit `frame:false`, `transparent:true`,
  `hasShadow:false`, `resizable:false`, `movable:false`, `alwaysOnTop` (Level
  `'floating'`), `skipTaskbar:true`, oben zentriert (`y:0`). Größe wechselt
  programmatisch zwischen eingeklappt (110×72) und erweitert (580×420) über
  `win.setBounds(..., true)` (animiert).
- Neuer IPC-Kanal `shell:resize` (bewusst außerhalb der eingefrorenen
  `IpcApi` aus `src/shared/ipc.ts` — reine Fenstergeometrie, kein
  App-Zustand), exposed als `window.shell.resize(w,h)` über das Preload.
- `src/renderer/App.tsx`: komplett neue Hülle (Icon-Navigation, linke
  Status-Spalte, rechte Inhaltsspalte); die bestehenden Tab-Komponenten
  (TasksTab, NotesTab, HabitsTab, CalendarTab, SettingsTab, Chat, TodayTab,
  DayStart) wurden **inhaltlich nicht verändert**, nur neu eingebettet. Chat
  ist jetzt ein eigener Reiter (`TestId.TabChat`), kein dauerhaft sichtbares
  Seitenpanel mehr.
- Neuer Platzhalter-Reiter "Agenten" (`AgentsTab.tsx`, `TestId.TabAgents`):
  zeigt nur einen Hinweistext. Die echte Funktion (laufende Coding-Agenten
  wie Claude Code überwachen, Allow/Deny) ist **noch nicht gebaut** — das
  bräuchte eine Anbindung an Claude Codes Hook-System (eigener lokaler
  Server in Taby, Hook-Skript, das bei jeder Aktion wartet) und ist als
  eigener, größerer Schritt vorgesehen.
- `src/renderer/components/TabyFace.tsx`: neues Maskottchen (winkt, blinzelt,
  Augen reagieren auf Chat-Eingabefokus/"Nachdenken").

**Konsequenz für Tests:** Alle E2E-Szenarien (A–E) laufen weiterhin gegen
`app.firstWindow()` — das Fenster startet bewusst im **erweiterten** Zustand
(nicht als Punkt), damit bestehende Tests ohne zusätzlichen "Aufklappen"-
Schritt funktionieren. Szenario D musste angepasst werden: Chat ist jetzt
ein Reiter, der vorher per `TestId.TabChat` ausgewählt werden muss.

**Nicht verifiziert:** Das Verhalten der Notch-Positionierung/`alwaysOnTop`
am echten Mac mit echter Notch (nur über `npm run build` + Playwright unter
Linux geprüft, siehe docs/BLOCKERS.md) — insbesondere ob `y:0` bei
unterschiedlichen MacBook-Modellen (mit/ohne Notch) richtig unter der Notch
sitzt, und ob das animierte `setBounds` auf macOS tatsächlich smooth
aussieht.

**Nachtrag (Mattglas-Look):** Ein Screenshot vom echten Mac zeigte eine
blickdichte schwarze Box statt einer durchscheinenden Kapsel wie bei Coucou
— `transparent: true` allein reicht nicht, wenn das CSS selbst eine volldeckende
Hintergrundfarbe malt. Behoben: `vibrancy: 'hud'` + `visualEffectState: 'active'`
in `src/main/index.ts` (macOS-Weichzeichner hinter dem Fenster) und
`.taby-capsule` in `styles.css` auf eine halbtransparente Farbe plus
`backdrop-filter: blur()` umgestellt. **Nicht verifiziert:** `vibrancy` ist
macOS-exklusiv und zeigt unter Linux (diese Entwicklungsumgebung) keinerlei
Effekt — nur geprüft, dass das Fenster damit nicht abstürzt. Ob der
Weichzeichner-Effekt am echten Mac tatsächlich wie bei Coucou aussieht, muss
dort bestätigt werden.

**Nachtrag (Form/Politur, 2026-10-11):** Auf Nutzerwunsch gezielt die
PNG-Referenzbilder aus dem Coucou-Repo angeschaut (`design/captures/*.png`
— reine UI-Screenshots, keine Marken-/Maskottchen-Übernahme, siehe
Lizenz-Hinweis oben) statt nur der Demo-GIF. Daraus übernommen (Form/Farbe,
kein Asset):
- **Asymmetrischer Eckenradius**: oben eckig (sitzt bündig an der
  Bildschirmkante/Notch), nur unten rund — bei Coucou eigene
  `topRadius`/`cornerRadius`-Werte in `IslandRootView.swift`, bei Taby
  `border-radius: 0 0 26px 26px` auf `.taby-capsule` (und entsprechend auf
  `.taby-collapsed`). Vorher rundum gleich rund → wirkte wie ein frei
  schwebendes Fenster statt wie eine Erweiterung der Bildschirmkante.
- **Status-Spalte**: von Punkt+Fließtext auf weiche farbige Chip-Pillen
  umgestellt (Vorbild: Coucous bunte Workspace-Pillen in
  `design/captures/03_overview.png`), Punkt bekommt einen zur Farbe
  passenden Glow (`box-shadow` in `App.tsx`).
- **Freigabe-Karte** (Agenten-Reiter): heller/weißer Haupt-Knopf
  ("Erlauben") statt akzentfarben — stärkster Kontrast im Board ist bei
  Coucous `04_approval.png` bewusst der Freigabe-Knopf, nicht irgendein
  Akzentton. Karte großzügiger gerundet/gepolstert.
- **Nav-Leiste**: aktiver Button jetzt ein fester Kreis mit Glow statt einer
  variablen Pille, Hover-Zustand ergänzt.
- Per statischem Vite-Build + Browser-Pane (Fake-API-Fallback) visuell
  gegengeprüft (Formen/Farben/Chips sichtbar korrekt) — **aber ohne
  `vibrancy`/echte Fenstertransparenz**, da das nur in echtem Electron auf
  macOS greift. Der eingeklappte Zustand ließ sich im Browser nicht sinnvoll
  prüfen, weil `window.shell.resize()` dort ein No-Op ist (das Fenster
  schrumpft nur in echtem Electron tatsächlich mit).

**Nachtrag (eine durchgehende Form statt zwei Boxen, 2026-10-11):** Der
Nutzer hat das auf dem echten Mac getestet und ein Referenzvideo gezeigt
(ein macOS-Menüleisten-Tool, das von oben herunterkommt wie ein Rollo).
Root-Ursache für das "starre" Gefühl: `.taby-collapsed` und `.taby-capsule`
waren zwei **separate** Elemente mit je eigenem Hintergrund/Rahmen/Schatten,
die beim Auf-/Zuklappen nur per Opacity ineinander überblendet haben — beim
gleichzeitigen nativen Fenster-Resize sah das wie zwei verschiedene Kästen
aus, nicht wie eine Form, die wächst.

Behoben durch Zusammenlegen zu einem gemeinsamen `.taby-shell`
(`App.tsx`/`styles.css`): **ein** Element trägt jetzt durchgehend
Hintergrund/Rahmen/Eckenradius/Schatten/Ambient-Blobs, `.taby-pill`
(Maskottchen) und `.taby-board-wrap` (Nav+Board) liegen beide absolut
*innerhalb* davon und blenden nur noch ihren eigenen Inhalt per Opacity um.
Die native Fenstergrößenänderung (`src/main/index.ts`, `shell:resize`)
bleibt unverändert bestehen — bewusst nicht durch eine rein CSS-basierte
Lösung (z. B. Höhe clippen in einem immer vollgroßen Fenster) ersetzt, weil
das unsichtbare Fensterfläche hinterlassen würde, die Mausklicks auf dem
Desktop darunter schlucken würde, solange Taby eingeklappt ist.

**Weiterhin nicht verifizierbar von hier aus:** ob sich das jetzt am echten
Mac tatsächlich wie "ein Rollo" anfühlt, hängt von macOS' eigener
`setBounds`-Animation ab, die ich nicht sehen kann. Die hier gemachte
Änderung behebt den visuell nachvollziehbaren Teil (keine zwei
überblendenden Boxen mehr) unabhängig davon.

**Nachtrag (echte Notch, Hybrid mit Swift, 2026-10-11):** Erstmals auf dem
echten Mac gebaut. Nutzerentscheidung: Electron/React bleibt, nur die
Notch-Anbindung wird nativ ("Hybrid", kein SwiftUI-Neubau).
- `native/notch-info/main.swift` (gebaut per `scripts/build-native.sh` mit
  `swiftc` aus den Command Line Tools, kein Xcode nötig; Teil von
  `npm run build`, auf Nicht-macOS übersprungen) gibt die Geometrie des
  Bildschirms mit Notch als JSON aus (`safeAreaInsets.top`,
  `auxiliaryTopLeft/RightArea`). Gemessen am MacBook des Nutzers: Notch
  209×38 pt, eingebautes Display rechts neben einem Ultrawide-Monitor —
  Taby landet trotzdem korrekt auf dem Display *mit* Notch.
- `src/main/notch.ts` liest das ein (Fallback ohne Hilfsprogramm: primärer
  Bildschirm, keine Notch). Fenster ist jetzt **fest** 760×520, liegt auf
  Ebene `screen-saver` mit `enableLargerThanScreen` **über** der Menüleiste
  (geprüft: `getBounds().y` = Oberkante des Displays), ohne `vibrancy`.
- Statt nativer `setBounds`-Animation (`shell:resize` entfernt) wächst eine
  tiefschwarze `.taby-island` per CSS-Feder von Notch+Flügeln zum Board,
  mit konkaven "Ohren" am oberen Rand. Die Reiter sitzen in der Notch-Zeile
  links/rechts der Kamera. Klicks auf transparente Fensterfläche gehen per
  `setIgnoreMouseEvents(true, {forward:true})` zum Desktop durch; der
  Renderer schaltet beim Betreten/Verlassen der Form um
  (`shell:interactive`). Damit ist das Klick-Schlucken-Argument aus dem
  vorigen Nachtrag gelöst, ohne die Fenstergröße zu animieren.
- Verlässt die Maus die offene Insel, klappt sie nach 700 ms zu (nicht im
  Testmodus, nicht bei offener Freigabe, nicht während ein Eingabefeld
  Fokus hat); `Esc` klappt ebenfalls zu.
- Nebenbei: `node_modules` stammte aus der Linux-Umgebung (Electron war ein
  ELF-Binary) → per `npm ci` neu installiert; `@testing-library/dom` fehlte
  als devDependency. Der E2E-Helfer `dismissDayStartIfPresent` hatte ein
  Rennen (prüfte, bevor die Frage gerendert war) → wartet jetzt erst auf
  Frage *oder* Reiter.

**Nicht verifiziert:** Ein echtes Bildschirmfoto der Notch ließ sich nicht
aufnehmen (keine Freigabe für Bildschirmaufnahme). Geprüft sind nur die
Fensterposition und Electron-eigene Aufnahmen des Inhalts. Ob die schwarze
Form pixelgenau mit der Hardware-Notch verschmilzt und ob das Durchreichen
der Klicks sich gut anfühlt, steht in docs/HANDTEST.md.
