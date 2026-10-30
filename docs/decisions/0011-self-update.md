# 0011: Selbst-Update für Freunde

**Entscheidung:** "Jetzt aktualisieren" in den Einstellungen (Gruppe
Allgemein, Abschnitt Updates) holt die neueste Taby-Version von der
Update-Adresse. Standard ist das GitHub-Repo des Eigentümers; die Adresse
kann auf einen anderen GitHub-Link oder einen beliebigen https-Ordner zeigen.

**Warum `version.json` und rohes GitHub:** Kein Server, kein Konto, keine
API-Grenze. `publish-dmg.sh` schreibt `download/version.json` (Commit, Build
und Zeit) neben `download/Taby.dmg`; die App liest beides über
`raw.githubusercontent.com`. Entschieden wird über die Build-Nummer: `bundle.sh`
schreibt `git rev-list --count HEAD` als `TabyBuild` in die Info.plist, und
es gibt nur ein Update, wenn der Build auf der Adresse größer ist als der eigene.
Entwickler-Builds ohne git (Build 0) fragen nie nach. `publish-dmg.sh` bricht
ab, solange uncommittete Änderungen da sind, damit Build und Code zusammenpassen.
Die letzte gemeldete Version steht in `UserDefaults` ("lastNotifiedUpdate"),
damit die Benachrichtigung auch nach einem Neustart nur einmal kommt.

**Warum lokale Neusignatur:** Die DMG ist ad hoc signiert. Damit macOS die
Freigaben (Schlüsselbund, Kalender, Erinnerungen) über Updates behält, signiert
das Austausch-Skript die neue App mit dem Zertifikat dieses Macs, indem es
`friend-setup.command` aufruft (das Skript liegt im App-Bundle). Fehlt es, wird
ad hoc signiert.

**Warum Signatur (Ed25519):** Ohne Apple-Entwicklerkonto gibt es keine
Herausgeber-Prüfung durch macOS. Darum signiert der Eigentümer jedes Update
selbst. `publish-dmg.sh` berechnet die SHA-256 der `Taby.dmg` und signiert
die Nachricht `"<build>\n<commit>\n<sha256>"` mit einem Ed25519-Schlüssel
(CryptoKit, `scripts/update-sign.swift`). `version.json` trägt `sha256` und
`signature` (base64). Die App hat den öffentlichen Schlüssel fest eingebaut
(`CoreServices.updatePublicKey`, `UpdateSignature.check`). Vor dem Schreiben
der DMG auf die Platte prüft sie: SHA der DMG gleich `sha256`, Signatur gültig
über die Nachricht, Build größer als der eigene (kein Zurückspielen alter,
signierter Versionen). Fehlt etwas oder passt etwas nicht, wird nichts
installiert. Das gilt auch für eine eigene Update-Adresse.

**Schlüssel:** Der private Schlüssel liegt nur im Schlüsselbund des
Eigentümers (generic password, Dienst `taby-update-signing-key`, Konto
`Taby`). Er steht in keinem Repository, Skript-Argument, Log oder Bericht.
`scripts/make-update-key.sh` legt ihn einmal an und gibt nur den öffentlichen
Schlüssel aus. Schlüssel sichern, sonst können keine Updates mehr signiert
werden. Geht er verloren, muss der öffentliche Schlüssel in der App ersetzt
werden, und alle Freunde müssen einmal manuell neu installieren.

**Ablauf:** Taby lädt die DMG, mountet sie, kopiert die App nach temporär,
startet ein Shell-Skript und beendet sich. Das Skript wartet auf das Ende des
alten Prozesses (läuft er nach 30 Sekunden noch, bricht es ab). Dann kopiert es
die neue App nach "$APP.new", prüft Signatur und Bundle-ID und erst danach
legt es die alte App in den Papierkorb und setzt die neue an ihren Platz.
Schlägt ein Schritt vor dem Tausch fehl, wird "$APP.new" gelöscht und die alte
App wieder geöffnet. Scheitert das Verschieben der neuen App, kommt die
Papierkorb-Kopie zurück. Danach signiert es mit dem Einrichtungs-Skript (bei
Fehler ad hoc) und öffnet die App. Alle Ausgaben stehen in
`~/Library/Logs/Taby-Update.log`. Eine Benachrichtigung kommt beim Start
höchstens einmal je neuer Version.

**Grenzen:**
- Die Version vom Eigentümer ersetzt auch einen eigenen Element-Build; dort
  ist Element nicht enthalten.
- Der Austausch braucht Schreibrecht auf den Ordner der App und das
  Zertifikat-Setup am Mac; Gatekeeper-Fragen können trotzdem erscheinen.
- Die Signatur beweist, dass der Schlüsselinhaber die Version freigegeben hat.
  Ein Angreifer ohne den privaten Schlüssel kann nichts installieren. Wer den
  Schlüssel hat, kann jede Version signieren. Die Bundle-ID wird geprüft.
- Noch offen aus dem Sicherheitsbericht (H1): `friend-setup.command` wird
  weiterhin aus dem neuen Bundle gestartet, und die Größe der DMG ist nicht
  begrenzt.
- Eine eigene Update-Adresse bedeutet volles Vertrauen in deren Server: wer dort
  schreiben kann, kann Taby ausliefern. Die Adresse ist frei wählbar, weil der
  Nutzer das so will; sie sollte nur eine Quelle sein, der man selbst traut.
- Ein Zurückrollen ist nicht eingebaut; die alte App liegt im Papierkorb.
