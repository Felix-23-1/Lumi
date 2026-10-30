// Aufgaben-Friedhof (Beispiel-Mod, Trigger: dayStarted)
// Rechte: tasks.read, notify. Kein Löschrecht – der Mod meldet nur.
// Taby gibt dem Lauf input.now (ISO) und input.weekday (1=Mo…7=So).
// Über den Trigger meldet er sich nur montags; von Hand gestartet immer.
var MAX_AGE_DAYS = 21;

// Tage zwischen zwei "YYYY-MM-DD…" (nur Datumsteil, keine Zeitzonen-Fallen).
function daysBetween(from, to) {
  function utc(s) { var p = s.slice(0, 10).split("-"); return Date.UTC(+p[0], +p[1] - 1, +p[2]); }
  return Math.round((utc(to) - utc(from)) / 86400000);
}

async function run(input) {
  input = input || {};
  if (!input.now) return "Keine Zeit von Taby erhalten.";
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
