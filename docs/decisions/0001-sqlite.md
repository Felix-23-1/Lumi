# 0001: SQLite-Treiber

**Entscheidung:** `node:sqlite` (Node-Built-in), kein `better-sqlite3`.

**Begründung:** BAUPLAN.md Abschnitt 3 verlangt, zuerst zu prüfen, ob `node:sqlite`
im Electron-Main-Prozess der gewählten Electron-Version läuft. Getestet mit
Electron 44.7.0 (bündelt Node 24.21.0):

```
$ ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron -e "
  const { DatabaseSync } = require('node:sqlite');
  const db = new DatabaseSync(':memory:');
  db.exec('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
  db.prepare('INSERT INTO t (name) VALUES (?)').run('hallo');
  console.log(JSON.stringify(db.prepare('SELECT * FROM t').get()));
"
{"id":1,"name":"hallo"}
```

Funktioniert ohne native Module, ohne `@electron/rebuild`, ohne Build-Schritt
pro Electron-Version. Das deckt die Anforderung aus Abschnitt 3 ab: „Wenn ja,
nimm es (keine nativen Module)".

**Konsequenz:** `src/main/store` nutzt `node:sqlite` (`DatabaseSync`) direkt.
Kein `package.json`-Eintrag für `better-sqlite3`.
