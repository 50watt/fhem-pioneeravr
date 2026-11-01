# fhem-pioneeravr

FHEM-Module zur Steuerung von Pioneer AV-Receivern über TCP/IP oder RS232.
`PIONEERAVR` übernimmt die Verbindung und die Main Zone;
`PIONEERAVRZONE` steuert zusätzliche Zonen, soweit der Receiver sie unterstützt.

## Stand

Basis ist **FHEM-SVN r31859** vom 31. Oktober 2026. Darauf aufbauend enthält
dieser Git-Stand eine Protokoll-Kompatibilitätsprüfung; diese Änderung ist noch
nicht im SVN veröffentlicht. Die Module enthalten strukturierte Metadaten und
die Registrierung über `FHEM::Meta`.

Die deutsche und englische Commandref ist jeweils im Modul enthalten.
Eine Übersicht der Änderungen steht im [Changelog](CHANGELOG.md).

## Metadaten und FHEM Installer

Beide Module deklarieren ihre Perl-/FHEM-Abhängigkeiten in einem `META.json`-Block
und registrieren ihn über `FHEM::Meta::InitMod`. Enthalten sind Beschreibung,
Suchbegriffe, Lizenz und Verweise auf Repository, Fehlerberichte und Commandref.
Die Modulversion wird weiterhin aus dem SVN-`$Id` abgeleitet. Es wird keine
zusätzliche unabhängige Release-Version eingeführt.

`PIONEERAVR` benötigt `HttpUtils`, `DevIo`, `SetExtensions`, `Time::HiRes` und `FHEM::Meta`.
`PIONEERAVRZONE` benötigt `SetExtensions`, `Time::HiRes` und `FHEM::Meta` sowie
ein eingerichtetes `PIONEERAVR`-Hauptgerät als `IODev`. Die Hauptgeräte-Abhängigkeit
ist eine FHEM-Gerätebeziehung, kein zusätzliches CPAN-Paket.
Transportspezifische Voraussetzungen wie die serielle Schnittstelle bleiben
Aufgabe von `DevIo` und der tatsächlich verwendeten Verbindungsart.

Nach Installation beider Dateien und einem FHEM-Neustart lässt sich die
Registrierung in der FHEM-Kommandozeile prüfen:

```text
get <Installer-Device> showModuleInfo PIONEERAVR
get <Installer-Device> showModuleInfo PIONEERAVRZONE
```

Die Datei `patches/pioneeravr-metadata.patch` dokumentiert die ursprüngliche
Änderung gegenüber r31821/r31819. Sie ist ein historischer Patch und darf auf
r31859 oder bereits aktualisierte Dateien nicht nochmals angewendet werden.
Für bestehende Installationen genügt das reguläre FHEM-Update, sobald dessen
Updatequelle r31859 enthält.

## Funktionen

- Steuerung von Power, Lautstärke, Mute, Eingang und weiteren modellabhängigen
  Audio-/Videoeinstellungen.
- Zusätzliche Zonen über `PIONEERAVRZONE`: `zone2`, `zone3` und `hdZone`.
- Zeitgesteuerte Befehlsübertragung mit mindestens 100 ms Abstand;
  Bedienbefehle haben Vorrang vor umfangreichen Hintergrundabfragen.
- Asynchrone Verbindungsprüfung für die Netzwerkverbindung.
- Kommunikationspause über `disable`, einschließlich zugeordneter Zonen.
- Reading `statusRequestState` für vollständige Statusabfragen.
- Receiverbestätigtes Reading `networkStandby`; das bisherige Internal bleibt
  aus Kompatibilitätsgründen erhalten.
- Umbenennen von Eingängen mit Leerzeichen im Alias und Prüfung der
  maximal 14 druckbaren ASCII-Zeichen.

## Installation und Aktualisierung

Für normale FHEM-Installationen können die veröffentlichten Module über das
reguläre FHEM-Update bezogen werden. Die folgenden Schritte sind für die
manuelle Installation des hier enthaltenen Stands gedacht.

Im Repository-Verzeichnis ausführen; den FHEM-Pfad bei Bedarf anpassen:

```bash
(
set -e
backup_dir=$(mktemp -d /tmp/pioneeravr-backup-XXXXXXXX)
sudo cp -p /opt/fhem/FHEM/70_PIONEERAVR.pm "$backup_dir/"
sudo cp -p /opt/fhem/FHEM/71_PIONEERAVRZONE.pm "$backup_dir/"
sudo cp 70_PIONEERAVR.pm 71_PIONEERAVRZONE.pm /opt/fhem/FHEM/
printf 'Sicherung: %s\n' "$backup_dir"
)
```

Die Sicherungsbefehle setzen voraus, dass beide Module bereits installiert
sind. Bei einer Erstinstallation nur vorhandene Dateien sichern. Bei einem
Fehler zuerst dessen Ursache klären, bevor die Dateien ersetzt werden.

Danach in der **FHEM-Kommandozeile**:

```text
reload 70_PIONEERAVR
reload 71_PIONEERAVRZONE
```

Ein späteres reguläres FHEM-Update kann manuell installierte Dateien wieder
durch den dann aktuellen SVN-Stand ersetzen.

## Unterstützte Receiver

Das Modul verwendet das bisherige Pioneer-ASCII-Protokoll auf Basis der
FY14-Befehlsliste von 2013. **Hardwaregetestet: VSX-923 über Netzwerk.**
Andere Modelle funktionieren, soweit sie dieses Protokoll unterstützen.
Viele neuere Geräte ab der Modellgeneration 2016 verwenden Onkyo/Pioneer ISCP;
für sie ist `ONKYO_AVR` vorgesehen. Der VSX-1131 wurde im Forum als mit
PIONEERAVR nicht funktionsfähig gemeldet. Baujahr und Modellreihe sind keine
zuverlässige Freigabe- oder Sperrliste.

`protocolCompatibility` zeigt `unknown`, `compatible` (erkannte Pioneer-Antwort)
oder `incompatible` (gültige ISCP-Antwort). Nach der ersten erfolglosen
TCP-Verbindungs-/Antwortprüfung fragt das Modul einmalig asynchron den
Powerstatus über ISCP am selben Host auf Port 60128 ab. Timeout oder ein
bloß offener Port reichen nicht als Nachweis. Die Prüfung verwendet `timeout`
und erfolgt auch bei `connectionCheck=off`; RS232 öffnet keine Nebenverbindung.
Bestätigtes ISCP stoppt die Kommunikation mit einem Hinweis auf `ONKYO_AVR`.
`set <name> reopen` oder Neudefinition setzt die Erkennung zurück.

## Einrichtung

Beispiel für einen Receiver über Netzwerk:

```text
define VSX923 PIONEERAVR telnet 192.168.1.50:8102
```

IP-Adresse und Port müssen zum Receiver passen. Ohne Portangabe verwendet das
Modul 8102; einzelne Geräte oder Installationen verwenden einen anderen Port.

Für RS232 lautet die Syntax:

```text
define <name> PIONEERAVR serial <devicename[@baudrate]>
```

Zusätzliche Zone, sofern vom Modell unterstützt:

```text
define VSX923Zone2 PIONEERAVRZONE zone2
attr VSX923Zone2 IODev VSX923
```

`IODev` besonders bei mehreren Receivern ausdrücklich setzen.

## Wichtige Befehle und Readings

```text
set VSX923 statusRequest
attr VSX923 disable 1
attr VSX923 disable 0
```

`disable=1` schließt die Verbindung und verwirft Timer und wartende Befehle.
Der Receiver wird dabei nicht ausgeschaltet. `state` und `stateAV` zeigen
`disabled`; andere Readings behalten ihre zuletzt bekannten Werte. Beim
Wiederaktivieren wird die Verbindung erneut aufgebaut, sofern die konfigurierte
externe Stromversorgung dies zulässt. Die vollständige Abfrage nach dem
Wiederverbinden richtet sich nach `statusUpdateReconnect` (Standard: `enable`).

| `statusRequestState` | Bedeutung |
| --- | --- |
| `running` | Status- und Eingangsabfragen werden gesendet. |
| `done` | Alle Abfragen wurden gesendet. |
| `aborted` | Die Abfrage wurde abgebrochen, z. B. durch disable oder Verbindungsverlust. |

`done` bestätigt **keine erfolgreiche Antwort auf jeden Parameter**. Nicht
unterstützte oder aktuell nicht verfügbare Abfragen können Receiverfehler
liefern. Wiederholte vollständige Statusanforderungen teilen sich den laufenden
Scan. Ein separates `get VSX923 loadInputNames` setzt dieses Reading nicht.
Ein vollständiger Scan dauert typischerweise etwa 40–60 Sekunden; zusätzliche
Bedienbefehle oder andere Verzögerungen können die Dauer verlängern.

`networkStandby` zeigt die zuletzt vom Receiver bestätigte Einstellung
`on` oder `off`. Die Einstellung wird nur durch einen ausdrücklichen
`set VSX923 networkStandby on/off` geändert, nicht automatisch durch das Modul.
Bei Telnet und bekanntem `off` wird `set ... on` vor dem Einreihen der
Einschaltbefehle abgewiesen. Bei unbekannter Einstellung wird ein Versuch
zugelassen. RS232-Einschalten wird durch Network Standby nicht gesperrt.

Existierende Readings werden bei `get` im Hauptmodul aus dem gespeicherten
Stand geliefert. `set ... statusRequest` fordert neue Werte vom Receiver an.
Die vollständige Befehls- und Attributbeschreibung ist in der Commandref
im jeweiligen Modul bzw. in FHEM verfügbar:

- [PIONEERAVR Commandref](https://fhem.de/commandref.html#PIONEERAVR)
- [PIONEERAVRZONE Commandref](https://fhem.de/commandref.html#PIONEERAVRZONE)

## Tests

Die Regressionstests laufen mit Perl außerhalb von FHEM:

```bash
perl t/pioneeravr-timing.t 70_PIONEERAVR.pm
```

Alternativ mit dem Perl-Testrunner:

```bash
prove t/pioneeravr-timing.t :: 70_PIONEERAVR.pm
```

Der aktuelle Stand besteht **89 Testgruppen**. Geprüft werden unter anderem
Befehlsabstände, Priorisierung, Verbindungsverlust, Wiederverbindung, disable,
Antwortparser, Eingangsnamen, Nullwerte, Network Standby und Protokollerkennung.
Die ISCP-Tests prüfen auch die echte Lese-/Schreiblogik über ein lokales
Socketpaar; der asynchrone Verbindungsaufbau wird simuliert. Die Tests verwenden
eine simulierte Uhr und Transport-Doubles; sie lesen keine `fhem.cfg` und öffnen
keine Receiververbindung. Die Metadatenregistrierung wird mit einem Test-Double
für `FHEM::Meta::InitMod` geprüft. Die tatsächliche Installer-Anzeige ist zusätzlich
im Zielsystem zu prüfen.

Hardwareprüfungen erfolgten mit einem **Pioneer VSX-923 über Netzwerk**.
Andere Modelle und RS232 wurden nicht an echter Hardware geprüft. Automatisierte
Tests ersetzen diese Prüfung nicht.

## Bekannte Grenzen und Rückmeldungen

- Verfügbare Befehle und Einstellungen hängen vom Receivermodell ab.
- `statusUpdateStart` ist derzeit ein nicht ausgewertetes Kompatibilitätsattribut.
- Receiverfehler werden protokolliert; eigene `lastError`-Readings sind noch
  nicht implementiert.
- Persistierte Eingangsaliase und Aktivierungen verwenden noch gemeinsame
  Schlüssel; bei mehreren Receivern ist diese Einschränkung zu beachten.

Bei Fehlerberichten bitte Receivermodell, Verbindungsart, Modulrevision,
auslösenden Befehl und einen passenden, bereinigten Logauszug angeben.

## Lizenz

Die FHEM-Module stehen gemäß ihren Dateiköpfen unter der GNU GPL Version 2
oder einer späteren Version. Die vorhandenen Lizenz- und Autorenhinweise
bleiben unverändert.
