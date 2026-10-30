# 0008 – Profi-Netzwerkwerkzeuge (nmap, Mitschnitt, Verbindungen)

Stand: 2026-10-12 · Status: angenommen

## Kontext
Der Nutzer wünscht nmap- und Wireshark-artige Funktionen direkt in Taby, mit
eigener, größerer Oberfläche. Gleichzeitig soll Taby sicher bleiben und keine
Daten unkontrolliert nach außen geben.

## Entscheidung
- **Teil des optionalen Netzwerk-Moduls** (`networkToolsEnabled`): nichts
  erscheint oder läuft, bevor der Nutzer es einschaltet.
- **Scan-Ziele begrenzt:** Gründlicher Scan (nmap, sonst eigener TCP-Scan) und
  Port-Dienste nur gegen private Adressen (Heimnetz) oder gegen Hosts, die der
  Nutzer unter „Meine Server“ einträgt und dabei bestätigt, dass er sie prüfen
  darf. Beliebige fremde Hosts werden abgelehnt (`ScanTargets.isAllowed`).
  Die „Verbindungen“-Ansicht zeigt nur, womit dieser Mac spricht; fremde Server
  werden dort nie gescannt.
- **Paket-Mitschnitt:** tcpdump braucht Admin-Rechte. Taby fragt pro Mitschnitt
  mit dem normalen macOS-Dialog (`osascript … with administrator privileges`),
  keine dauerhafte Rechteerweiterung (kein ChmodBPF). Der Filter wird vor dem
  Aufruf gegen eine Positivliste geprüft (`isValidTcpdumpFilter`); Werte gehen
  nie durch eine Shell ungefiltert.
- **Nur Zusammenfassungen:** Taby zeigt je Paket eine Kurzzeile (Zeit, Protokoll,
  Quelle→Ziel, Länge, Info) und eine Statistik je Gegenstelle. Rohinhalte werden
  nicht ausgewertet. Für die Tiefenanalyse kann der Mitschnitt als `.pcap`
  gespeichert und in Wireshark geöffnet werden.
- **Eigenes Fenster:** Reiter lassen sich über den Fenster-Knopf in ein frei
  vergrößerbares macOS-Fenster lösen. Zusätzlich kann die Insel angeheftet
  werden; während Scan oder Mitschnitt hält sie sich von selbst offen
  (`IslandCardRules.isBusy`), auch beim Klick nach außen.

## Keine Einbindung von Wireshark/nmap als Binärauslieferung
Taby nutzt ein vorhandenes `nmap` (Homebrew), sonst einen eigenen TCP-Scan als
Rückfall. Wireshark wird nicht mitgeliefert; der Export als `.pcap` genügt.
tcpdump ist in macOS enthalten.
