// Eingebaute Mod-Bibliothek: fertige Mods, die mit Lumi ausgeliefert werden.
// Installierte Mods sind ausgeschaltet und ungeprüft, bis der Nutzer sie freigibt.
// Die Skripte nutzen nur die Funktionen aus ScriptModBridge.swift (taby.*).
import Foundation

public enum ModCatalog {
  public static let entries: [CatalogMod] = [
    script("aufgaben-friedhof", "Aufgaben-Friedhof",
           "Erinnert montags an Aufgaben, die seit über drei Wochen offen liegen.",
           triggers: [.dayStarted], permissions: ["tasks.read", "notify"], code: aufgabenFriedhofCode),
    script("feierabend-check", "Feierabend-Check",
           "Zählt zum Tagesabschluss die offenen Aufgaben von heute und meldet sie.",
           triggers: [.dayEnded], permissions: ["tasks.read", "notify"], code: feierabendCheckCode),
    script("pause-nach-fokus", "Pause nach Fokus",
           "Schlägt nach einer Fokus-Sitzung eine kurze Pause vor.",
           triggers: [.focusFinished], permissions: ["notify"], code: pauseNachFokusCode),
    script("wetter-notch", "Wetter in der Notch",
           "Zeigt die aktuelle Temperatur an deinem Wohnort (Einstellungen → Notch) in der Notch. "
             + "Fragt dafür open-meteo.com.",
           triggers: [.dayStarted, .hourly], permissions: ["http:open-meteo.com", "island.text"],
           code: wetterNotchCode),
    script("pomodoro-zaehler", "Pomodoro-Zähler",
           "Zählt die beendeten Fokus-Sitzungen von heute und zeigt „🍅 N heute“ in der Notch.",
           triggers: [.focusFinished], permissions: ["storage", "notes.read", "notes.write", "island.text"],
           code: pomodoroZaehlerCode),
    script("pausen-erinnerung", "Pausen-Erinnerung",
           "Werktags von 9 bis 17 Uhr: erinnert stündlich ans Aufstehen, außer ein Fokus läuft.",
           triggers: [.hourly], permissions: ["notify", "focus"], code: pausenErinnerungCode),
    script("tagesstatistik", "Tagesstatistik",
           "Fasst am Tagesabschluss zusammen, was heute erledigt wurde und was überfällig offen ist.",
           triggers: [.dayEnded], permissions: ["tasks.read", "notify"], code: tagesstatistikCode),
    script("feiertage", "Feiertage",
           "Zeigt in der Notch den bundesweiten Feiertag von heute oder der nächsten 7 Tage.",
           triggers: [.dayStarted], permissions: ["island.text"], code: feiertageCode),
    script("oepnv-abfahrt", "ÖPNV-Abfahrt",
           "Zeigt in der Notch die nächste Abfahrt deiner Haltestelle (Einstellung „stopId“, Deutsche Bahn).",
           triggers: [.hourly], permissions: ["http:v6.db.transport.rest", "island.text"],
           settings: [ModSetting(key: "stopId", label: "Haltestellen-ID (DB)")],
           code: oepnvAbfahrtCode),
    script("geburtstag-vorlauf", "Geburtstag-Vorlauf",
           "Meldet am Tagesstart Geburtstage aus dem Kalender, die in den nächsten 3 Tagen anstehen.",
           triggers: [.dayStarted], permissions: ["calendar.read", "notify"], code: geburtstagVorlaufCode),
  ] + skills

  /// Fertige Skills („Mod ohne Code“): Anleitung + erlaubte Werkzeuge, kein Code.
  static let skills: [CatalogMod] = [
    skill("wochenplanung", "Wochenplanung", "wochenplan",
          "Sieht offene Aufgaben und die Termine der Woche durch und schlägt einen Plan vor.",
          tools: ["list_tasks", "get_overview", "list_events", "find_free_time", "list_weekly_goals"],
          prompt: """
          Erstelle einen Wochenplan. Lies zuerst die offenen Aufgaben und die Termine der laufenden Woche.
          Schlage pro Tag konkrete Zeitblöcke für die wichtigsten Aufgaben vor und nenne freie Zeiten.
          Lege nichts an: Du hast nur lesende Werkzeuge. Frage am Ende, ob der Nutzer den Plan übernehmen möchte;
          erst dann legst du Aufgaben oder Termine an (im nächsten Schritt mit den normalen Werkzeugen).
          Antworte kurz, auf Deutsch, mit einer Liste pro Tag.
          """),
    skill("meeting-vorbereitung", "Meeting-Vorbereitung", "meeting",
          "Nimmt den nächsten Termin und sucht passende Mails, Notizen und Kontakte für eine kurze Vorbereitung.",
          tools: ["list_events", "list_mails", "read_mail", "search_notes", "list_notes", "find_contact", "list_tasks"],
          prompt: """
          Bereite den nächsten Termin vor. Finde zuerst den nächsten Termin, dann Mails, Notizen und Kontakte,
          die dazu passen (Stichwort: Titel und Teilnehmer). Schreibe ein kurzes Briefing auf Deutsch:
          Worum es geht, wer dabei ist, offene Punkte und was man mitbringen sollte. Höchstens 12 Zeilen.
          Du liest nur; nichts wird geändert oder gesendet.
          """),
    skill("tagesabschluss-mail", "Tagesabschluss-Mail", "abschluss",
          "Fasst erledigte und offene Aufgaben des Tages zusammen und öffnet dafür einen Mail-Entwurf.",
          tools: ["get_overview", "list_tasks", "list_habits", "draft_mail"],
          prompt: """
          Erstelle den Tagesabschluss. Lies Übersicht, Aufgaben und Gewohnheiten von heute.
          Fasse kurz zusammen, was erledigt ist und was offen bleibt. Danach öffnest du mit draft_mail einen
          Mail-Entwurf an den Nutzer selbst (Betreff „Tagesabschluss“ mit Datum). Sende nie.
          Die Mail ist nur ein Entwurf, den der Nutzer selbst abschickt. Sag am Ende, dass der Entwurf offen ist.
          """),
  ]

  private static func skill(_ id: String, _ name: String, _ command: String, _ description: String,
                            tools: [String], prompt: String) -> CatalogMod {
    CatalogMod(manifest: ModManifest(id: id, name: name, description: description, author: "Lumi",
                                     kind: .skill, prompt: prompt, tools: tools, command: command))
  }

  private static func script(_ id: String, _ name: String, _ description: String, triggers: [ModTrigger],
                             permissions: [String], settings: [ModSetting]? = nil, code: String) -> CatalogMod {
    CatalogMod(manifest: ModManifest(id: id, name: name, description: description, author: "Lumi",
                                     kind: .script, entry: "main.js", triggers: triggers,
                                     permissions: permissions, settings: settings),
               code: code)
  }

  private static let aufgabenFriedhofCode = #"""
  // Aufgaben-Friedhof (Trigger: dayStarted)
  // Rechte: tasks.read, notify. Kein Löschrecht – der Mod meldet nur.
  // Lumi gibt dem Lauf input.now (ISO) und input.weekday (1=Mo…7=So).
  // Über den Trigger meldet er sich nur montags; von Hand gestartet immer.
  var MAX_AGE_DAYS = 21;

  // Tage zwischen zwei "YYYY-MM-DD…" (nur Datumsteil, keine Zeitzonen-Fallen).
  function daysBetween(from, to) {
    function utc(s) { var p = s.slice(0, 10).split("-"); return Date.UTC(+p[0], +p[1] - 1, +p[2]); }
    return Math.round((utc(to) - utc(from)) / 86400000);
  }

  async function run(input) {
    input = input || {};
    if (!input.now) return "Keine Zeit von Lumi erhalten.";
    if (input.trigger && input.weekday !== 1) return "Nur montags.";
    var today = input.now.slice(0, 10);
    var tasks = await taby.tasks.list();
    var stale = tasks.filter(function (t) {
      if (t.done || !t.createdAt) return false;
      var noDueOrOverdue = !t.due || t.due.slice(0, 10) < today;
      return daysBetween(t.createdAt, today) > MAX_AGE_DAYS && noDueOrOverdue;
    });
    if (stale.length === 0) return "Keine alten Aufgaben.";
    var names = stale.slice(0, 3).map(function (t) { return "„" + t.title + "“"; }).join(", ");
    var more = stale.length > 3 ? " und " + (stale.length - 3) + " weitere" : "";
    await taby.notify("Aufgaben-Friedhof",
      stale.length + (stale.length === 1 ? " Aufgabe liegt" : " Aufgaben liegen") +
      " seit über 3 Wochen: " + names + more + ". Erledigen, einplanen oder löschen?");
    return stale.length + " alte Aufgaben";
  }
  """#

  private static let feierabendCheckCode = #"""
  // Feierabend-Check (Trigger: dayEnded)
  // Rechte: tasks.read, notify. Zählt nur, ändert nichts.
  // Zählt offene Aufgaben mit Fälligkeit heute oder früher (überfällig).
  async function run(input) {
    input = input || {};
    var today = String(input.now || "").slice(0, 10);
    if (!today) return "Keine Zeit von Lumi erhalten.";
    var tasks = await taby.tasks.list();
    var open = tasks.filter(function (t) {
      return !t.done && t.due && t.due.slice(0, 10) <= today;
    });
    var text = open.length === 0
      ? "Alles erledigt für heute"
      : "Noch " + open.length + (open.length === 1 ? " Aufgabe" : " Aufgaben") + " von heute offen";
    await taby.notify("Feierabend-Check", text);
    return text;
  }
  """#

  private static let pauseNachFokusCode = #"""
  // Pause nach Fokus (Trigger: focusFinished)
  // Rechte: notify. Nur ein Hinweis, es werden keine Daten gelesen.
  async function run() {
    var text = "Kurz aufstehen, etwas trinken und den Blick in die Ferne schweifen lassen.";
    await taby.notify("Pause nach Fokus", text);
    return "Pausen-Hinweis gesendet";
  }
  """#

  private static let wetterNotchCode = #"""
  // Wetter in der Notch (Trigger: dayStarted, hourly)
  // Rechte: http:open-meteo.com, island.text. Ort = input.city (Einstellungen → Wohnort).
  // Schlägt eine Anfrage fehl, bleibt die Notch unverändert.
  function symbol(code) {
    if (code === 0) return "☀️";
    if (code <= 3) return "⛅️";
    if (code <= 48) return "🌫️";
    if (code <= 67 || (code >= 80 && code <= 82)) return "🌧️";
    if (code <= 77 || code === 85 || code === 86) return "🌨️";
    return "⛈️";
  }

  async function run(input) {
    input = input || {};
    var city = String(input.city || "").trim();
    if (!city) return "Kein Wohnort eingestellt (Einstellungen → Notch → Wohnort).";
    var place, res;
    try {
      var geo = await taby.http.get("https://geocoding-api.open-meteo.com/v1/search?count=1&language=de&name=" +
        encodeURIComponent(city));
      place = geo && geo.json && geo.json.results ? geo.json.results[0] : null;
      if (!place) return "Ort „" + city + "“ nicht gefunden.";
      res = await taby.http.get("https://api.open-meteo.com/v1/forecast?latitude=" + place.latitude +
        "&longitude=" + place.longitude + "&current=temperature_2m,weather_code");
    } catch (e) {
      return "Wetter nicht abrufbar.";
    }
    var current = res && res.json ? res.json.current : null;
    var temp = current ? current.temperature_2m : undefined;
    if (typeof temp !== "number") return "Keine Temperatur erhalten.";
    var text = symbol(current.weather_code) + " " + place.name + " " + Math.round(temp) + " °C";
    await taby.island.set(text, 3600);
    return text;
  }
  """#

  private static let pomodoroZaehlerCode = #"""
  // Pomodoro-Zähler (Trigger: focusFinished)
  // Rechte: storage (Zähler), notes.* nur als Ersatz, island.text.
  async function run(input) {
    input = input || {};
    var today = String(input.now || "").slice(0, 10);
    if (!today) return "Keine Zeit von Lumi erhalten.";
    var count = null;
    try {
      count = (Number(await taby.storage.get("pomodoro:" + today)) || 0) + 1;
      await taby.storage.set("pomodoro:" + today, count);
    } catch (e) {
      count = null;  // ohne Speicher: Notiz als Zähler
    }
    if (count === null) {
      var title = "Pomodoro " + today;
      var notes = await taby.notes.list();
      count = notes.filter(function (n) { return n.title === title; }).length + 1;
      await taby.notes.add({ title: title, content: "Sitzung " + count });
    }
    var text = "🍅 " + count + " heute";
    await taby.island.set(text, 3600);
    return text;
  }
  """#

  private static let pausenErinnerungCode = #"""
  // Pausen-Erinnerung (Trigger: hourly)
  // Rechte: notify, focus. Werktags 9–17 Uhr, stündlich; läuft ein Fokus, schweigt der Mod.
  async function run(input) {
    input = input || {};
    if (!input.now) return "Keine Zeit von Lumi erhalten.";
    var hour = Number(String(input.now).slice(11, 13));
    if (input.trigger && (input.weekday > 5 || hour < 9 || hour > 17)) return "Außerhalb der Erinnerungszeit.";
    var focusing = false;
    try { focusing = await taby.focus.isRunning(); } catch (e) { focusing = false; }
    if (focusing) return "Fokus läuft, keine Pause.";
    await taby.notify("Pausen-Erinnerung", "Kurz aufstehen und trinken.");
    return "Pausen-Erinnerung gesendet";
  }
  """#

  private static let tagesstatistikCode = #"""
  // Tagesstatistik (Trigger: dayEnded)
  // Rechte: tasks.read, notify. Zählt nur, ändert nichts.
  async function run(input) {
    input = input || {};
    var today = String(input.now || "").slice(0, 10);
    if (!today) return "Keine Zeit von Lumi erhalten.";
    var tasks = await taby.tasks.list();
    var doneToday = tasks.filter(function (t) {
      return t.done && String(t.doneAt || "").slice(0, 10) === today;
    }).length;
    var overdue = tasks.filter(function (t) {
      return !t.done && t.due && t.due.slice(0, 10) < today;
    }).length;
    var text = "Heute erledigt: " + doneToday + " · überfällig offen: " + overdue;
    await taby.notify("Tagesstatistik", text);
    return text;
  }
  """#

  private static let feiertageCode = #"""
  // Feiertage (Trigger: dayStarted)
  // Rechte: island.text. Bundesweite Feiertage, ohne Netz. Ostern wird berechnet (Gauß/Meeus).
  function easter(y) {
    var a = y % 19, b = Math.floor(y / 100), c = y % 100, d = Math.floor(b / 4), e = b % 4;
    var f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3);
    var h = (19 * a + b - d - g + 15) % 30, i = Math.floor(c / 4), k = c % 4;
    var l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451);
    var month = Math.floor((h + l - 7 * m + 114) / 31), day = ((h + l - 7 * m + 114) % 31) + 1;
    return Date.UTC(y, month - 1, day);
  }

  // Liste [Zeitpunkt in ms (UTC, nur Datum), Name] für ein Jahr.
  function holidays(y) {
    var e = easter(y), day = 86400000;
    return [
      [Date.UTC(y, 0, 1), "Neujahr"],
      [e - 2 * day, "Karfreitag"],
      [e + day, "Ostermontag"],
      [Date.UTC(y, 4, 1), "Tag der Arbeit"],
      [e + 39 * day, "Christi Himmelfahrt"],
      [e + 50 * day, "Pfingstmontag"],
      [Date.UTC(y, 9, 3), "Tag der Deutschen Einheit"],
      [Date.UTC(y, 11, 25), "1. Weihnachtstag"],
      [Date.UTC(y, 11, 26), "2. Weihnachtstag"]
    ];
  }

  async function run(input) {
    input = input || {};
    var today = String(input.now || "").slice(0, 10);
    if (!today) return "Keine Zeit von Lumi erhalten.";
    var p = today.split("-");
    var y = +p[0], todayMs = Date.UTC(y, +p[1] - 1, +p[2]);
    var next = holidays(y).concat(holidays(y + 1))
      .map(function (h) { return [Math.round((h[0] - todayMs) / 86400000), h[1]]; })
      .filter(function (h) { return h[0] >= 0 && h[0] <= 7; })
      .sort(function (a, b) { return a[0] - b[0]; })[0];
    if (!next) return "Kein Feiertag in den nächsten 7 Tagen.";
    var text = next[0] === 0 ? "Heute: " + next[1] : "In " + next[0] + " Tagen: " + next[1];
    await taby.island.set(text, 86400);
    return text;
  }
  """#

  private static let oepnvAbfahrtCode = #"""
  // ÖPNV-Abfahrt (Trigger: hourly, 6–20 Uhr)
  // Rechte: http:v6.db.transport.rest, island.text. Haltestellen-ID aus den Einstellungen (stopId).
  // Fester Host, damit die Freigabe statisch bleibt; nur die ID wird eingesetzt.
  async function run(input) {
    input = input || {};
    var stopId = String((input.settings || {}).stopId || "").trim();
    if (!stopId) return "Keine Haltestelle eingestellt (Einstellungen → Mod → stopId).";
    if (!input.now) return "Keine Zeit von Lumi erhalten.";
    var hour = Number(String(input.now).slice(11, 13));
    if (input.trigger && (hour < 6 || hour > 20)) return "Außerhalb 6–20 Uhr.";
    var res;
    try {
      res = await taby.http.get("https://v6.db.transport.rest/stops/" + encodeURIComponent(stopId) +
        "/departures?duration=30&results=3");
    } catch (e) {
      return "Abfahrten nicht abrufbar.";
    }
    var j = res && res.json ? res.json : {};
    var list = Array.isArray(j) ? j : (Array.isArray(j.departures) ? j.departures : []);
    var now = Date.parse(input.now);
    var deps = list.map(function (d) {
      return {
        line: d.line && d.line.name ? d.line.name : "?",
        direction: d.direction || "",
        min: Math.round((Date.parse(d.when || d.plannedWhen) - now) / 60000)
      };
    }).filter(function (d) { return d.min >= 0; });
    if (deps.length === 0) return "Keine Abfahrt in den nächsten 30 Minuten.";
    var d = deps[0];
    var text = "🚆 " + d.line + " " + d.direction + (d.min === 0 ? " jetzt" : " in " + d.min + " Min");
    await taby.island.set(text, 3600);
    return text;
  }
  """#

  private static let geburtstagVorlaufCode = #"""
  // Geburtstag-Vorlauf (Trigger: dayStarted)
  // Rechte: calendar.read, notify. Ganztägige Termine mit „Geburtstag“ in den nächsten 3 Tagen.
  // Kontakte sind für Mods nicht zugänglich; Geburtstage stehen als Kalendertermine.
  async function run(input) {
    input = input || {};
    var today = String(input.now || "").slice(0, 10);
    if (!today) return "Keine Zeit von Lumi erhalten.";
    var p = today.split("-");
    var base = Date.UTC(+p[0], +p[1] - 1, +p[2]);
    var end = new Date(base + 3 * 86400000).toISOString().slice(0, 10);
    var events = await taby.calendar.events(today, end);
    var texts = (events || []).filter(function (e) {
      return e.allDay && /Geburtstag/i.test(e.title || "");
    }).map(function (e) {
      var q = e.start.slice(0, 10).split("-");
      var days = Math.round((Date.UTC(+q[0], +q[1] - 1, +q[2]) - base) / 86400000);
      return { days: days, title: e.title };
    }).filter(function (b) { return b.days >= 0 && b.days <= 3; })
      .map(function (b) { return (b.days === 0 ? "Heute: " : "In " + b.days + " Tagen: ") + b.title; });
    if (texts.length === 0) return "Keine Geburtstage in den nächsten 3 Tagen.";
    var text = texts.join(" · ");
    await taby.notify("Geburtstag-Vorlauf", text);
    return text;
  }
  """#
}
