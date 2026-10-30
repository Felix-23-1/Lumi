// JXA-Skripte für Apple Mail. Jedes Skript ist eine feste Zeichenkette ohne
// Swift-Interpolation. Werte (IDs, Adressen, Betreff, Text) kommen nur als
// JSON-Argument `argv[0]` in das Skript und werden dort mit JSON.parse gelesen.
// Ausgabe: JSON über JSON.stringify auf stdout.
enum AppleMailScripts {
  /// Argumente: {"days": Zahl, "limit": Zahl}
  static let inbox = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    if (Mail.accounts().length === 0) { throw new Error('NO_ACCOUNT'); }
    const cutoff = new Date(Date.now() - p.days * 86400000);
    const msgs = Mail.inbox.messages.whose({dateReceived: {'>': cutoff}});
    const ids = msgs.messageId();
    const subjects = msgs.subject();
    const senders = msgs.sender();
    const dates = msgs.dateReceived();
    const reads = msgs.readStatus();
    const flags = msgs.flaggedStatus();
    const time = function (d) { return d ? d.getTime() : 0; };
    const order = [];
    for (let i = 0; i < ids.length; i++) { order.push(i); }
    order.sort(function (a, b) { return time(dates[b]) - time(dates[a]); });
    const out = [];
    for (const i of order.slice(0, p.limit)) {
      const id = ids[i];
      if (!id) { continue; }
      const m = msgs[i];
      const box = m.mailbox();  // einmal je Nachricht statt zweimal
      out.push({
        id: id,
        subject: subjects[i] || '',
        sender: senders[i] || '',
        date: dates[i] ? dates[i].toISOString() : null,
        read: reads[i],
        flagged: flags[i],
        account: box.account().name(),
        mailbox: box.name()
      });
    }
    return JSON.stringify(out);
  }
  """

  /// Argumente: {"id": Text}
  static let body = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    const hits = Mail.inbox.messages.whose({messageId: p.id})();
    if (hits.length === 0) { throw new Error('NOT_FOUND'); }
    return JSON.stringify({content: hits[0].content()});
  }
  """

  /// Argumente: {"id": Text, "read": Wahrheitswert}
  static let setRead = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    const hits = Mail.inbox.messages.whose({messageId: p.id})();
    if (hits.length === 0) { throw new Error('NOT_FOUND'); }
    hits[0].readStatus = p.read;
    return JSON.stringify({ok: true});
  }
  """

  /// Argumente: {"id": Text, "flagged": Wahrheitswert}
  static let setFlagged = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    const hits = Mail.inbox.messages.whose({messageId: p.id})();
    if (hits.length === 0) { throw new Error('NOT_FOUND'); }
    hits[0].flaggedStatus = p.flagged;
    return JSON.stringify({ok: true});
  }
  """

  /// Argumente: {"id": Text}. Sucht den Archiv-Ordner des Kontos der Mail.
  static let archive = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    const hits = Mail.inbox.messages.whose({messageId: p.id})();
    if (hits.length === 0) { throw new Error('NOT_FOUND'); }
    const msg = hits[0];
    const account = msg.mailbox().account();
    const names = ['Archive', 'Archiv', 'All Mail', 'Alle Nachrichten'];
    let box = null;
    for (const n of names) {
      const found = account.mailboxes.whose({name: n})();
      if (found.length > 0) { box = found[0]; break; }
    }
    if (box === null) { throw new Error('NO_ARCHIVE'); }
    Mail.move(msg, {to: box});
    return JSON.stringify({ok: true});
  }
  """

  /// Argumente: {"id": Text}. Verschiebt in den Papierkorb.
  static let trash = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    const hits = Mail.inbox.messages.whose({messageId: p.id})();
    if (hits.length === 0) { throw new Error('NOT_FOUND'); }
    Mail.delete(hits[0]);
    return JSON.stringify({ok: true});
  }
  """

  /// Argumente: {"id": Text}. Öffnet ein sichtbares Antwort-Fenster; gesendet wird nichts.
  static let replyDraft = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    const hits = Mail.inbox.messages.whose({messageId: p.id})();
    if (hits.length === 0) { throw new Error('NOT_FOUND'); }
    Mail.reply(hits[0], {openingWindow: true, replyToAll: false});
    Mail.activate();
    return JSON.stringify({ok: true});
  }
  """

  /// Argumente: {"to": [Adressen], "subject": Text, "body": Text, "replyToId": Text (optional)}
  static let send = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    if (p.replyToId) {
      const hits = Mail.inbox.messages.whose({messageId: p.replyToId})();
      if (hits.length === 0) { throw new Error('NOT_FOUND'); }
      const r = Mail.reply(hits[0], {openingWindow: false, replyToAll: false});
      // Empfänger = genau die bestätigten, nie Reply-To/Absender der Original-Mail (Karte zeigt `p.to`).
      if (!p.to || p.to.length === 0) { throw new Error('NO_RECIPIENT'); }
      r.toRecipients().forEach(x => x.delete());
      for (const a of p.to) { r.toRecipients.push(Mail.Recipient({address: a})); }
      if (r.toRecipients().length !== p.to.length) { throw new Error('RECIPIENT_MISMATCH'); }
      r.content = p.body;
      r.send();
    } else {
      const m = Mail.OutgoingMessage({subject: p.subject, content: p.body, visible: false});
      Mail.outgoingMessages.push(m);
      for (const a of p.to) { m.toRecipients.push(Mail.Recipient({address: a})); }
      m.send();
    }
    return JSON.stringify({ok: true});
  }
  """

  /// Argumente: {"to": [Adressen], "subject": Text, "body": Text}. Öffnet sichtbar, sendet nie.
  static let newDraft = """
  function run(argv) {
    const p = JSON.parse(argv[0]);
    const Mail = Application('Mail');
    const m = Mail.OutgoingMessage({subject: p.subject, content: p.body, visible: true});
    Mail.outgoingMessages.push(m);
    for (const a of p.to) { m.toRecipients.push(Mail.Recipient({address: a})); }
    Mail.activate();
    return JSON.stringify({ok: true});
  }
  """
}
