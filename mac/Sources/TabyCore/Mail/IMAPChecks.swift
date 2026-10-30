// Prüfungen für IMAP: Parser mit Beispielantworten (Literale, Quoted Strings, NIL),
// Kopf- und Körperdecodierung, Kennungen, Ordnerwahl und Backend-Auswahl.
// Keine echte Verbindung: die Grenze zum Netz ist NWConnection, nicht geprüft.
import Foundation

enum IMAPChecks {
  static let cases: [CheckCase] = [
    // MARK: Parser
    CheckCase("IMAP: Suchantwort liefert die UIDs") {
      let r = try IMAPParser.responses(Data("* SEARCH 2 5 9\r\nT1 OK SEARCH done\r\n".utf8))
      try expectEqual(r.count, 2)
      try expectEqual(r[0].keyword, "SEARCH")
      try expectEqual(r[0].items.dropFirst().compactMap { $0.string }, ["2", "5", "9"])
      try expectEqual(r[1].tag, "T1")
      try expectEqual(r[1].keyword, "OK")
    },
    CheckCase("IMAP: Literal mit Klammern und Anführungszeichen bleibt ein Wert") {
      let text = "Hi \"there\") (x"
      let raw = "* 3 FETCH (UID 8 BODY[TEXT] {\(text.utf8.count)}\r\n\(text))\r\nT2 OK done\r\n"
      let r = try IMAPParser.responses(Data(raw.utf8))
      let pairs = IMAPParser.pairs(r[0]) ?? [:]
      try expectEqual(r[0].number, 3)
      try expectEqual(pairs["UID"]?.string, "8")
      try expectEqual(pairs["BODY[TEXT]"]?.data.map { String(decoding: $0, as: UTF8.self) }, text)
    },
    CheckCase("IMAP: Abschnittsname BODY[HEADER.FIELDS (…)] bleibt ein Schlüssel") {
      let raw = "* 1 FETCH (BODY[HEADER.FIELDS (LIST-UNSUBSCRIBE)] NIL FLAGS () )\r\nT3 OK done\r\n"
      let pairs = IMAPParser.pairs(try IMAPParser.responses(Data(raw.utf8))[0]) ?? [:]
      try expectEqual(pairs["BODY[HEADER.FIELDS (LIST-UNSUBSCRIBE)]"]?.optionalString, nil)
      try expectEqual(pairs["FLAGS"]?.list?.count, 0)
    },
    CheckCase("IMAP: abgeschnittene Antwort wird als unvollständig gemeldet") {
      do {
        _ = try IMAPParser.responses(Data("* 1 FETCH (BODY[TEXT] {50}\r\nabc".utf8))
        try expectEqual(true, false)
      } catch IMAPParseError.incomplete {
        // erwartet
      }
    },
    CheckCase("IMAP: zu großes Literal wird abgewiesen, überlange Zahl stürzt nicht ab") {
      do {
        _ = try IMAPParser.responses(Data("* 1 FETCH (BODY[TEXT] {20000000}\r\nabc".utf8))
        try expectEqual(true, false)
      } catch IMAPParseError.tooLarge {
        // erwartet
      }
      do {
        _ = try IMAPParser.responses(Data("* 1 FETCH (BODY[TEXT] {99999999999999999999999}\r\nabc".utf8))
        try expectEqual(true, false)
      } catch IMAPParseError.malformed {
        // erwartet
      }
    },
    CheckCase("IMAP: Zeitlimit beendet einen hängenden Vorgang pünktlich und ruft onTimeout") {
      let started = DispatchTime.now().uptimeNanoseconds
      do {
        _ = try await IMAPTimeout.run(seconds: 0.2, onTimeout: {}) {
          try await Task.sleep(nanoseconds: 60_000_000_000)
          return 1
        }
        try expectEqual(true, false)
      } catch let e as MailError {
        try expectEqual(e, MailError.timeout)
      }
      let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
      try expect(seconds < 2, "Zeitlimit nach 0,2 s, nicht erst nach dem Vorgang (\(seconds) s)")
    },
    CheckCase("IMAP: Ergebnis vor dem Zeitlimit kommt unverändert zurück") {
      let v = try await IMAPTimeout.run(seconds: 5) { 42 }
      try expectEqual(v, 42)
    },
    CheckCase("IMAP: ENVELOPE mit NIL-Feldern und Adressliste") {
      let raw = "* 4 FETCH (ENVELOPE (NIL NIL ((\"Lena Weber\" NIL \"lena\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\nT4 OK done\r\n"
      let pairs = IMAPParser.pairs(try IMAPParser.responses(Data(raw.utf8))[0]) ?? [:]
      let env = IMAPBackend.envelope(pairs["ENVELOPE"] ?? .nilValue)
      try expectEqual(env.subject, "")
      try expectEqual(env.name, "Lena Weber")
      try expectEqual(env.address, "lena@example.com")
    },
    CheckCase("IMAP: Ordnerliste mit Sonderrolle und Trennzeichen") {
      let raw = "* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"\r\n* LIST (\\Trash) \".\" INBOX.Papierkorb\r\nT5 OK done\r\n"
      let rs = try IMAPParser.responses(Data(raw.utf8))
      try expectEqual(rs[0].items.count, 4)
      try expectEqual(rs[0].items[1].list?.compactMap { $0.string } ?? [], ["\\HasNoChildren", "\\Archive"])
      try expectEqual(rs[1].items[3].optionalString, "INBOX.Papierkorb")
    },
    CheckCase("IMAP: UIDVALIDITY steht im OK-Abschnitt") {
      let raw = "* OK [UIDVALIDITY 3857529045] UIDs valid\r\nT6 OK done\r\n"
      let r = try IMAPParser.responses(Data(raw.utf8))
      try expectEqual(r[0].items[1].string, "[UIDVALIDITY 3857529045]")
    },

    // MARK: Kopfzeilen (RFC 2047)
    CheckCase("Kopf: Base64-Betreff =?UTF-8?B?…?= wird entschlüsselt") {
      let encoded = "=?UTF-8?B?\(Data("Grüße aus Köln".utf8).base64EncodedString())?="
      try expectEqual(MailText.decodeWords(encoded), "Grüße aus Köln")
    },
    CheckCase("Kopf: Q-Codierung mit Latin-1 und Unterstrich") {
      try expectEqual(MailText.decodeWords("=?ISO-8859-1?Q?Gr=FC=DFe?= Test"), "Grüße Test")
      try expectEqual(MailText.decodeWords("=?UTF-8?Q?Gr=C3=BC_e?="), "Grü e")
    },
    CheckCase("Kopf: zwei Wörter nebeneinander ohne Leerzeichen dazwischen") {
      try expectEqual(MailText.decodeWords("=?UTF-8?Q?Gr=C3=BC?= =?UTF-8?Q?=C3=9Fe?="), "Grüße")
    },
    CheckCase("Kopf: Text ohne Kodierung bleibt unverändert") {
      try expectEqual(MailText.decodeWords("Rechnung Mai 2026"), "Rechnung Mai 2026")
    },
    CheckCase("Kopf: Fortsetzungszeile und Content-Type-Parameter") {
      let h = MailText.parseHeaders("Subject: Hallo\r\n  Welt\r\nContent-Type: text/plain; charset=\"utf-8\"\r\n")
      try expectEqual(h["subject"], "Hallo Welt")
      let ct = MailText.contentType(h["content-type"] ?? "")
      try expectEqual(ct.type, "text/plain")
      try expectEqual(ct.params["charset"], "utf-8")
    },

    // MARK: Körper
    CheckCase("Körper: quoted-printable mit weichem Umbruch und Umlauten") {
      let out = MailText.quotedPrintable(Data("Gr=C3=BC=C3=9Fe =\r\nweiter".utf8))
      try expectEqual(String(decoding: out, as: UTF8.self), "Grüße weiter")
    },
    CheckCase("Körper: base64 wird dekodiert") {
      let raw = Data("Grüße aus Köln".utf8).base64EncodedString()
      let out = MailText.decodeTransfer(Data(raw.utf8), encoding: "base64")
      try expectEqual(String(decoding: out, as: UTF8.self), "Grüße aus Köln")
    },
    CheckCase("Körper: Latin-1-Zeichensatz wird richtig gelesen") {
      try expectEqual(MailText.decodeBytes(Data([0x47, 0xFC]), charset: "ISO-8859-1"), "Gü")
    },
    CheckCase("Körper: multipart nimmt text/plain vor text/html") {
      let raw = "Content-Type: multipart/alternative; boundary=\"XYZ\"\r\n\r\n"
        + "--XYZ\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Hallo <b>Welt</b></p>\r\n"
        + "--XYZ\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
        + "Hallo =C3=84rger\r\n--XYZ--\r\n"
      try expectEqual(MailText.plainText(message: Data(raw.utf8)), "Hallo Ärger")
    },
    CheckCase("Körper: reines HTML wird zu Text, Skript fällt weg") {
      let raw = "Content-Type: text/html; charset=utf-8\r\n\r\n<style>x{}</style><p>Zeile&nbsp;eins</p><p>Zwei &amp; drei</p>"
      let text = MailText.plainText(message: Data(raw.utf8))
      try expect(text.contains("Zeile eins"), "Absatz bleibt erhalten")
      try expect(text.contains("Zwei & drei"), "Entities werden aufgelöst")
      try expect(!text.contains("x{}"), "Stil fällt weg")
    },

    // MARK: Kennung, Befehle, Datum
    CheckCase("IMAP: Mail-Kennung mit UIDVALIDITY kommt heil zurück") {
      let id = IMAPBackend.makeID(validity: "777", uid: 5)
      try expectEqual(id, "imap:777:5")
      try expectEqual(IMAPBackend.parseID(id)?.validity, "777")
      try expectEqual(IMAPBackend.parseID(id)?.uid, 5)
      try expect(IMAPBackend.parseID("imap:1:x") == nil, "UID muss Zahl sein")
      try expect(IMAPBackend.parseID("apple-7") == nil, "fremde Kennung wird abgewiesen")
      try expectEqual(IMAPBackend.parseID("imap::9")?.validity, "")
    },
    CheckCase("IMAP: Befehlsargumente werden in Anführungszeichen gesetzt und escaped") {
      try expectEqual(IMAPSession.quote("a\"b\\c"), "\"" + "a\\\"b\\\\c" + "\"")
      try expectEqual(IMAPSession.quote("ab\r\ncd"), "\"abcd\"")
    },
    CheckCase("IMAP: INTERNALDATE wird lokal im Format der Mail-Liste") {
      let s = IMAPBackend.internalDate("17-Jul-1996 02:44:25 -0700")
      try expectEqual(s.count, 16)
      try expect(s.hasPrefix("1996-07-1"), "Datum bleibt im Juli 1996")
      try expectEqual(IMAPBackend.internalDate(nil), "")
    },
    CheckCase("IMAP: Archiv und Papierkorb werden per Sonderrolle oder Name gefunden") {
      let folders = [
        IMAPFolder(name: "Archive", delimiter: "/", attributes: []),
        IMAPFolder(name: "Gelöscht", delimiter: "/", attributes: ["\\Trash"]),
        IMAPFolder(name: "INBOX.Papierkorb", delimiter: ".", attributes: []),
      ]
      try expectEqual(IMAPBackend.folder(in: folders, leaves: ["archive", "archiv"], special: "\\ARCHIVE")?.name, "Archive")
      try expectEqual(IMAPBackend.folder(in: folders, leaves: ["trash", "papierkorb"], special: "\\TRASH")?.name, "Gelöscht")
      try expectEqual(IMAPBackend.folder(in: folders.dropFirst(2).map { $0 }, leaves: ["papierkorb"], special: "\\TRASH")?.name,
                      "INBOX.Papierkorb")
      try expect(IMAPBackend.folder(in: [], leaves: ["archive"], special: "\\ARCHIVE") == nil, "ohne Ordner nil")
    },

    // MARK: Auswahl des Zugangs
    CheckCase("Auswahl: „apple“ nimmt Apple Mail, „imap“ den IMAP-Zugang") {
      var apple = TabySettings.defaults
      apple.mailBackend = "apple"
      try expect(SwitchingMailBackend(settings: { apple }).current() is AppleMailBackend, "Standard ist Apple Mail")
      var imap = TabySettings.defaults
      imap.mailBackend = "imap"
      imap.imapHost = "imap.example.com"
      imap.imapUser = "lena@example.com"
      try expect(SwitchingMailBackend(settings: { imap }).current() is IMAPBackend, "IMAP wird gewählt")
    },
  ]
}
