// Prüfungen und Snapshots für den Notiz-Editor: Format-Aktionen (Auswahl, Cursor, Umschalten),
// Listen-Fortsetzung, Roundtrip des Markdown-Texts, Zeilenarten und die Notizansicht mit
// Format-Leiste sowie mit Aufgaben-Stand-Leiste.
import AppKit
import Foundation
import SwiftUI
import TabyCore

enum NoteEditorChecks {
  private static let now = "2026-10-11T09:00"

  private static func sel(_ location: Int, _ length: Int = 0) -> NSRange {
    NSRange(location: location, length: length)
  }

  private static func edit(_ action: NoteFormatting.Action, _ text: String, _ s: NSRange) -> NoteFormatting.Edit {
    NoteFormatting.edit(action, text: text, selection: s)
  }

  @MainActor private static func fixture() -> FakeServices {
    let fake = FakeServices(sample: false)
    fake.current.tasks = [
      TabyTask(id: "s1", title: "Steuererklärung abgeben", due: "2026-10-14", createdAt: "2026-10-01T08:00",
               status: .inProgress),
    ]
    fake.current.notes = [
      Note(id: "e1", title: "Einkauf", content: "# Einkauf\n\n- [ ] Milch\n- **Brot** für *Freitag*\n> Tipp: Liste nach Laden sortieren",
           createdAt: now, updatedAt: now),
      Note(id: "e2", title: "Belege", content: "Kontoauszüge Q2\n- [x] Quittung Fahrrad",
           createdAt: now, updatedAt: now, taskId: "s1"),
    ]
    return fake
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Format: fett um Auswahl setzen und wieder entfernen, Auswahl bleibt auf dem Wort") {
        let a = edit(.bold, "Hallo Welt", sel(6, 4))
        try expectEqual(a.text, "Hallo **Welt**")
        try expectEqual(a.selection, sel(8, 4))
        let b = edit(.bold, a.text, a.selection)
        try expectEqual(b.text, "Hallo Welt", "Umschalten aus")
        try expectEqual(b.selection, sel(6, 4))
      },
      CheckCase("Format: kursiv um Auswahl setzen und wieder entfernen") {
        let a = edit(.italic, "Hallo Welt", sel(6, 4))
        try expectEqual(a.text, "Hallo *Welt*")
        try expectEqual(a.selection, sel(7, 4))
        let b = edit(.italic, a.text, a.selection)
        try expectEqual(b.text, "Hallo Welt")
      },
      CheckCase("Format: fett am Cursor fügt ** ** ein, Cursor dazwischen; zweites Mal entfernt beides") {
        let a = edit(.bold, "ab", sel(1))
        try expectEqual(a.text, "a****b")
        try expectEqual(a.selection, sel(3))
        let b = edit(.bold, a.text, a.selection)
        try expectEqual(b.text, "ab")
        try expectEqual(b.selection, sel(1))
      },
      CheckCase("Format: kursiv am Cursor fügt * * ein und entfernt sie wieder") {
        let a = edit(.italic, "ab", sel(1))
        try expectEqual(a.text, "a**b")
        try expectEqual(a.selection, sel(2))
        let b = edit(.italic, a.text, a.selection)
        try expectEqual(b.text, "ab")
        try expectEqual(b.selection, sel(1))
      },
      CheckCase("Format: Überschrift groß setzt # und Cursor wandert mit, Umschalten entfernt") {
        let a = edit(.heading1, "Titel", sel(0))
        try expectEqual(a.text, "# Titel")
        try expectEqual(a.selection, sel(2))
        let b = edit(.heading1, a.text, a.selection)
        try expectEqual(b.text, "Titel")
        try expectEqual(b.selection, sel(0))
      },
      CheckCase("Format: Überschrift mittel ersetzt # durch ## statt zu verdoppeln") {
        let a = edit(.heading2, "# Titel", sel(2))
        try expectEqual(a.text, "## Titel")
        try expectEqual(a.selection, sel(3))
      },
      CheckCase("Format: Aufzählung über zwei Zeilen, Umschalten entfernt die Markierung wieder") {
        let a = edit(.bullet, "a\nb", sel(0, 3))
        try expectEqual(a.text, "- a\n- b")
        try expectEqual(a.selection, sel(0, 7), "Auswahl deckt beide Zeilen")
        let b = edit(.bullet, a.text, a.selection)
        try expectEqual(b.text, "a\nb")
        try expectEqual(b.selection, sel(0, 3))
      },
      CheckCase("Format: Nummerierung zählt die Zeilen der Auswahl, Umschalten entfernt") {
        let a = edit(.numbered, "a\nb", sel(0, 3))
        try expectEqual(a.text, "1. a\n2. b")
        let b = edit(.numbered, a.text, a.selection)
        try expectEqual(b.text, "a\nb")
      },
      CheckCase("Format: Checkbox am Cursor setzen und entfernen; geprüfte Zeile wird auch entfernt") {
        let a = edit(.checkbox, "x", sel(0))
        try expectEqual(a.text, "- [ ] x")
        try expectEqual(a.selection, sel(6))
        let b = edit(.checkbox, a.text, a.selection)
        try expectEqual(b.text, "x")
        let c = edit(.checkbox, "- [x] done", sel(10))
        try expectEqual(c.text, "done", "erledigte Checkbox wird entfernt")
      },
      CheckCase("Format: Zitat setzen und entfernen; Art wechselt zwischen Zeilen nicht doppelt") {
        let a = edit(.quote, "Zitat", sel(0))
        try expectEqual(a.text, "> Zitat")
        try expectEqual(a.selection, sel(2))
        let b = edit(.quote, a.text, a.selection)
        try expectEqual(b.text, "Zitat")
        try expectEqual(edit(.bullet, "> Zitat", sel(0)).text, "- Zitat", "Zitat wird zur Aufzählung, nicht verdoppelt")
      },
      CheckCase("Format: Trennlinie hinter Text mit Leerzeile davor; auf leerer Zeile nur die Linie") {
        let a = edit(.rule, "Text", sel(4))
        try expectEqual(a.text, "Text\n\n---")
        try expectEqual(a.selection, sel(9))
        try expectEqual(edit(.rule, "", sel(0)).text, "---")
        let c = edit(.rule, "Para\n\nNext", sel(5))
        try expectEqual(c.text, "Para\n\n---\nNext", "Leerzeile nach Text bleibt, keine Setext-Überschrift")
      },
      CheckCase("Liste: Return setzt Aufzählung, Nummer und Checkbox fort") {
        let a = NoteFormatting.continueList("- eins", selection: sel(6))
        try expectEqual(a?.text, "- eins\n- ")
        try expectEqual(a?.selection, sel(9))
        let n = NoteFormatting.continueList("1. a", selection: sel(4))
        try expectEqual(n?.text, "1. a\n2. ")
        let c = NoteFormatting.continueList("- [x] erledigt", selection: sel(14))
        try expectEqual(c?.text, "- [x] erledigt\n- [ ] ", "Checkbox kommt unmarkiert")
        let i = NoteFormatting.continueList("  - a", selection: sel(5))
        try expectEqual(i?.text, "  - a\n  - ", "Einrückung bleibt")
        let ten = NoteFormatting.continueList("9. x", selection: sel(4))
        try expectEqual(ten?.text, "9. x\n10. ")
      },
      CheckCase("Liste: Return auf leerer Listenzeile beendet die Liste; Text ohne Liste bleibt unberührt") {
        let e = NoteFormatting.continueList("- ", selection: sel(2))
        try expectEqual(e?.text, "", "Markierung weg")
        try expectEqual(e?.selection, sel(0))
        try expectEqual(NoteFormatting.continueList("2. ", selection: sel(3))?.text, "")
        try expectEqual(NoteFormatting.continueList("Text", selection: sel(4)), nil, "keine Liste: normal")
        try expectEqual(NoteFormatting.continueList("# T", selection: sel(3)), nil, "Überschrift ist keine Liste")
        try expectEqual(NoteFormatting.continueList("- a", selection: sel(0, 1)), nil, "mit Auswahl: normal")
      },
      CheckCase("Roundtrip: Umschalten zweimal und Hervorhebung ändern den Markdown-Text nicht") {
        let text = "Ein *Satz* mit **fett** und ** offen\n- [ ] Milch\n- [x] Brot\n# Titel\n> Zitat\n---\n1. eins"
        let wrapped = edit(.bold, text, sel(0, (text as NSString).length))
        let back = edit(.bold, wrapped.text, wrapped.selection)
        try expectEqual(back.text, text, "fett um ganzen Text und wieder weg")
        let items = "a\nb"
        let once = edit(.bullet, items, sel(0, 3))
        try expectEqual(edit(.bullet, once.text, once.selection).text, items)
        let styled = NoteMarkdownStyle.attributed(text, size: 13)
        try expectEqual(styled.string, text, "Darstellung ändert keinen Zeichen")
        try expectEqual(styled.length, (text as NSString).length)
      },
      CheckCase("Zeilenart: Überschrift, Aufzählung, Nummer, Checkbox, Zitat, Trennlinie, Text") {
        try expectEqual(NoteFormatting.lineKind("## x"), .heading(2))
        try expectEqual(NoteFormatting.lineKind("- [X] a"), .checkbox(checked: true))
        try expectEqual(NoteFormatting.lineKind("- [ ] a"), .checkbox(checked: false))
        try expectEqual(NoteFormatting.lineKind("- a"), .bullet)
        try expectEqual(NoteFormatting.lineKind("1. a"), .numbered)
        try expectEqual(NoteFormatting.lineKind("> q"), .quote)
        try expectEqual(NoteFormatting.lineKind("---"), .rule)
        try expectEqual(NoteFormatting.lineKind("#tag"), .text, "ohne Leerzeichen keine Überschrift")
      },
      CheckCase("Hervorhebung: fett und kursiv Bereiche, Markierungen gedimmt, Überschrift über die ganze Zeile") {
        let fett = NoteFormatting.spans("**a** x")
        try expect(fett.contains(NoteFormatting.Span(range: sel(0, 2), style: .marker)), "öffnende Markierung")
        try expect(fett.contains(NoteFormatting.Span(range: sel(2, 1), style: .bold)), "fetter Text")
        let kursiv = NoteFormatting.spans("a *b*")
        try expect(kursiv.contains(NoteFormatting.Span(range: sel(3, 1), style: .italic)), "kursiver Text")
        let h = NoteFormatting.spans("# T")
        try expect(h.contains(NoteFormatting.Span(range: sel(0, 3), style: .heading(1))), "Überschrift")
      },
      CheckCase("Einrücken: Auswahl und Cursor-Zeile um zwei Leerzeichen; Ausrücken nimmt Tab oder bis zu zwei Leerzeichen") {
        let a = edit(.indent, "a\nb", sel(0, 3))
        try expectEqual(a.text, "  a\n  b")
        try expectEqual(a.selection, sel(0, 7), "Auswahl deckt beide Zeilen")
        let c = edit(.indent, "- x", sel(3))
        try expectEqual(c.text, "  - x")
        try expectEqual(c.selection, sel(5), "Cursor bleibt am selben Zeichen")
        let o = edit(.outdent, "    a", sel(4))
        try expectEqual(o.text, "  a")
        try expectEqual(o.selection, sel(2))
        try expectEqual(edit(.outdent, "\tx", sel(1)).text, "x", "Tab wird entfernt")
        try expectEqual(edit(.outdent, " x", sel(0)).text, "x", "ein Leerzeichen reicht")
        try expectEqual(edit(.outdent, "a", sel(0)).text, "a", "nichts zum Ausrücken")
      },
      CheckCase("Einrücken: Einrücken und Ausrücken heben sich auf, auch bei Listen") {
        let text = "- a\n- b\nText"
        let i = edit(.indent, text, sel(0, 7))
        try expectEqual(i.text, "  - a\n  - b\nText")
        let back = edit(.outdent, i.text, i.selection)
        try expectEqual(back.text, text)
      },
      CheckCase("Zähler: Wörter durch Leerraum, Zeichen mit Zeilenumbruch; leerer Text zählt null") {
        let s = NoteFormatting.stats("Hallo  Welt\nneu")
        try expectEqual(s.words, 3)
        try expectEqual(s.chars, 15)
        try expectEqual(NoteFormatting.stats("").words, 0)
        try expectEqual(NoteFormatting.stats("  ").words, 0, "nur Leerraum ist kein Wort")
      },
      CheckCase("Speicherstand: ungesichert oder gesichert") {
        try expectEqual(NoteFormatting.saveLabel(dirty: true), "Ungesicherte Änderungen")
        try expectEqual(NoteFormatting.saveLabel(dirty: false), "Alles gesichert")
      },
    ]
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-notes-format-editor", size: ViewSnapshots.size) {
        let fake = fixture()
        let model = AppModel(services: fake)
        return AnyView(NotesView(notes: fake.current.notes, expanded: "e1", tasks: fake.current.tasks, startEditing: true)
          .environmentObject(model).tabyNow(now).environment(\.tabySnapshot, true)
          .frame(maxHeight: .infinity, alignment: .top))
      },
      SnapshotSpec("view-notes-task-status", size: ViewSnapshots.size) {
        let fake = fixture()
        let model = AppModel(services: fake)
        return AnyView(NotesView(notes: fake.current.notes, expanded: "e2", tasks: fake.current.tasks)
          .environmentObject(model).tabyNow(now).environment(\.tabySnapshot, true)
          .frame(maxHeight: .infinity, alignment: .top))
      },
    ]
  }
}
