# Changelog

Die nummerierten Revisionen beziehen sich auf das FHEM-SVN. Aktuell veröffentlicht:
PIONEERAVR r31862 und PIONEERAVRZONE r31859.
Regressionstests werden hier zusätzlich bereitgestellt und sind nicht Teil
der bisherigen SVN-Veröffentlichungen.

## r31862 — 2026-11-01

- Reading `protocolCompatibility`: `unknown`, `compatible`, `incompatible`.
- Einmalige asynchrone ISCP-Power-Abfrage nach erfolgloser Netzwerkprüfung.
- Gültige ISCP-Pakete werden vor dem Pioneer-Zeilenparser erkannt; beliebige
  CR/LF-Nachrichten bestätigen die Erreichbarkeit nicht mehr.
- Bestätigtes ISCP stoppt Kommunikation mit Hinweis auf `ONKYO_AVR`.
- Disable, Löschen, Neudefinition und Stromabschaltung brechen die Nebenabfrage ab.
- Deutsche/englische Commandref und README zur Modell-/Baujahrsabgrenzung ergänzt.
- 89 automatisierte Testgruppen bestanden; Protokollprüfung am VSX-923 bestätigt.
- Hardwaretest der Erkennung inkompatibler ISCP-Receiver steht noch aus.

## r31859 — 2026-10-31

- `META.json` für PIONEERAVR und PIONEERAVRZONE ergänzt.
- Registrierung beider Module über `FHEM::Meta::InitMod`.
- Laufzeitabhängigkeiten, deutsche/englische Beschreibung, Keywords, GPL_2
  und Repository-/Support-/Commandref-Verweise deklariert.
- SVN-basierte Versionierung über `$Id` bleibt erhalten.
- Keine Änderungen an Receiverbefehlen, Verbindungsabläufen oder Timern.
- Regressionstest für die Registrierung ergänzt, insgesamt 75 Testgruppen.
- Historischen Modulpatch gegenüber r31821/r31819 zur Nachvollziehbarkeit erhalten.
- Metadatenanzeige beider Module im produktiven FHEM Installer bestätigt.

## r31821 — 2026-10-20

- Nullwerte in Set-Argumenten bleiben erhalten, etwa bei `inputSkip ... 0`.
- Receiverantworten aktualisieren das Reading `networkStandby` und das
  bisherige gleichnamige Internal.
- Telnet-Einschaltbefehle werden bei bekanntem Network Standby `off` bereits
  vor dem Einreihen abgewiesen; RS232 bleibt davon unabhängig.
- Deutsche und englische Dokumentation zu Network Standby angepasst.

## r31820 — 2026-10-20

- Neues Reading `statusRequestState`: `running`, `done`, `aborted`.
- Gemeinsamer Ablauf für manuelle und automatische vollständige Statusabfragen.
- `done` bezeichnet das Ende der Befehlsübertragung, keine vollständige
  Bestätigung aller abgefragten Parameter.

## r31819 — 2026-10-20

- Kommunikationspause über `disable` im Hauptgerät und zugeordneten Zonen.
- Verbindung, Timer und wartende Befehle werden beim Pausieren beendet.
- Wiederaktivieren baut die Verbindung neu auf; der Receiver-Einschaltzustand
  wird durch disable nicht verändert.
- Deutsche und englische Dokumentation ergänzt.

## r31818 — 2026-10-20

- Asynchrone Verbindungsprüfung über ReadFn und Timer.
- Verbindungsabbrüche und Wiederverbindung verwenden die bestehenden
  DevIo-/ReadyFn-Pfade.

## r31817 — 2026-10-20

- `renameInputAlias` unterstützt Leerzeichen im neuen Namen.
- Prüfung auf 1–14 druckbare ASCII-Zeichen und eindeutige Eingangsauswahl.
- Geänderte Aliase werden vom Receiver zurückgelesen.

## r31816 — 2026-10-20

- Zeitgesteuerte Befehlsübertragung mit mindestens 100 ms Abstand.
- Status- und Eingangsscans laufen als Hintergrundarbeit; Bedienbefehle
  haben Vorrang.
- Wiederholte gleichartige Scans werden zusammengefasst.

## r31815 — 2026-10-20

- HDMI-Ausgangszuordnung korrigiert.
- Doppelte Schleife beim Löschen der Displayanzeige entfernt.

## r31813 — 2026-10-20

- Deutsche und englische Moduldokumentation überarbeitet.
