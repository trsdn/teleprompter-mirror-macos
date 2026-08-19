# Teleprompter Mirror

Teleprompter Mirror ist eine eigenständige native macOS-App für einen
Teleprompter- oder Spiegelglas-Aufbau. Sie erfasst genau den ausgewählten
physischen Monitor, spiegelt bzw. dreht dessen Inhalt und zeigt das Ergebnis
vollflächig **auf demselben Monitor**. Das Seitenverhältnis bleibt erhalten;
freie Flächen sind schwarz.

Es gibt keine Drittanbieterpakete, Hilfsprozesse oder Daemons.

## Sichere Ausgabe auf demselben Monitor

Eine normale Bildschirmaufnahme würde das eigene Vollbild erneut aufnehmen und
eine optische Endlosschleife erzeugen. Die App verhindert das fail-closed:

1. ScreenCaptureKit muss die laufende App anhand ihrer Prozess-ID als
   `SCApplication` liefern.
2. Diese Anwendung wird im `SCContentFilter` vollständig ausgeschlossen.
3. Alle App-Fenster erhalten `sharingType = .none`.
4. Das passive Ausgabefenster bleibt verborgen, bis Aufnahme und Filter
   eingerichtet und derselbe unveränderliche Monitor-Snapshot mit
   `CGDirectDisplayID`, `SCDisplay` und `NSScreen` erneut geprüft wurde.

Ist der Prozessausschluss nicht verfügbar oder ändert sich die
Monitorkonfiguration während des Starts, bleibt die Ausgabe aus.

Das Vollbildfenster ist randlos, klickdurchlässig, wird nie zum Haupt- oder
Tastaturfenster und aktiviert die App nicht. Vor dem Start wird das
Steuerfenster nach Möglichkeit auf einen anderen angeschlossenen Monitor
verschoben und an dessen sichtbaren Bereich angepasst.

## Teleprompter-Aufbau

1. Den ausgewählten Monitor so platzieren, dass er in das Spiegelglas strahlt.
2. Das Glas typischerweise ungefähr im 45°-Winkel vor der Kamera montieren.
3. Standardmäßig ist **Horizontal spiegeln** bei **0°** aktiv. Je nach
   physischem Aufbau Drehung und vertikale Spiegelung anpassen.
4. Die Schriftgröße der verwendeten Sprecheransicht so wählen, dass sie am
   tatsächlichen Kameraabstand gut lesbar ist.

## Voraussetzungen

- macOS 13 Ventura oder neuer
- Xcode oder Command Line Tools mit Swift 6
- Bildschirmaufnahme-Berechtigung für das gebaute App-Bundle

## Bauen und testen

```bash
git clone https://github.com/trsdn/teleprompter-mirror-macos.git
cd teleprompter-mirror-macos
swift test
./build-app.sh
```

Das Skript erstellt `dist/Teleprompter Mirror.app`. Es bevorzugt automatisch
eine vorhandene Identität vom Typ **Developer ID Application**, verwendet
ersatzweise **Apple Development** und fällt nur ohne stabile Identität mit
Warnung auf eine Ad-hoc-Signatur zurück. Es gibt keine fest eingetragene Team-
oder Zertifikatskennung. Eine Identität kann ausdrücklich gesetzt werden:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build-app.sh
```

Das Skript signiert mit Hardened Runtime; Developer-ID-Builds erhalten einen
Apple-Zeitstempel.

### Optionaler Laufzeit-Selbsttest

Nur wenn **Teleprompter Mirror selbst** bereits Bildschirmaufnahmezugriff hat,
kann der signierte Build ohne neuen Berechtigungsdialog getestet werden:

```bash
open "dist/Teleprompter Mirror.app" --args --self-test
```

Der Test verwendet einen verbundenen Monitor gleichzeitig als Quelle und
Ausgabe, meldet `SELF_TEST_PASS` oder `SELF_TEST_FAIL` im Systemprotokoll,
stoppt die Ausgabe und beendet die App. Ohne vorhandene Berechtigung meldet er
`SELF_TEST_SKIP`; er fordert sie nicht an und verändert keine TCC-Einstellung.

## Bedienung

1. Einen der drei Preset-Slots auswählen und bei Bedarf benennen.
2. Den physischen Monitor für Aufnahme **und** Ausgabe auswählen.
3. Drehung `0°`, `90°`, `180°` oder `270°` sowie horizontale und vertikale
   Spiegelung einstellen.
4. **Preset speichern** wählen.
5. Bildschirmaufnahme erlauben.
6. **Ausgabe starten** wählen.

Alle freien Flächen bleiben durch proportionale Einpassung schwarz.
Transformationen können während der Ausgabe geändert werden.

### Stoppen und Steuerung

- **Stoppen** im Steuerfenster
- `⌘.` solange das App-Menü bzw. Steuerfenster aktiv ist
- **Ausgabe stoppen** im Statusmenü der macOS-Menüleiste
- **Teleprompter Mirror beenden** im Statusmenü oder App-Menü

`Escape` kann im aktiven Steuer-/Menükontext den dortigen Abbruch auslösen.
Das passive Ausgabefenster wird absichtlich nie zum Tastaturfenster und kann
`Escape` deshalb nicht selbst empfangen. Das Statusmenü bleibt der
zuverlässige Stoppweg, auch wenn das Steuerfenster verdeckt oder geschlossen
ist. Es werden keine globalen Tastatur-Event-Taps installiert.

## Rendering und Ressourcenverbrauch

Die Aufnahme läuft mit 30 Hz und `queueDepth = 2`. Unvollständige oder
ScreenCaptureKit-Idle-Frames werden verworfen. Die Capture-Größe wird auf den
Ausgabebedarf begrenzt.

Der bevorzugte Pfad
`ScreenCaptureKit → AVSampleBufferDisplayLayer` reicht IOSurface-gestützte
BGRA-Puffer readiness- und backpressure-gesteuert direkt weiter; Frames werden
nicht angestaut. Eine Sitzung kann höchstens einmal auf
`Core Image → CALayer` zurückfallen. Dieser sichere Fallback hält nur den
neuesten Frame und erzeugt Kontext und 30-Hz-Timer erst bei Bedarf. Beim
Stoppen werden Frame, Timer, Layer und Kontext freigegeben. Die App verwendet
kein `MTKView`. Wird innerhalb von fünf Sekunden kein vollständiger Frame
dargestellt, beendet und blockiert die App die Ausgabe statt dauerhaft einen
schwarzen Vollbildstatus als laufend zu melden.

## Presets und Monitoridentität

Jeder der drei benannten Presets speichert genau eine Monitoridentität und die
Transformation per `Codable` in `UserDefaults`. Eine Identität kombiniert,
soweit verfügbar:

- Hersteller-, Produkt- und Seriennummer
- stabile Display-UUID
- als eindeutigen Fallback normalisierten Namen und rotationsunabhängige native
  Pixelabmessungen

Eine flüchtige `CGDirectDisplayID` wird nie allein oder dauerhaft gespeichert.
Mehrdeutige Treffer werden nicht automatisch verwendet.

## Berechtigung, Anmeldestart und Wiederverbinden

Unter **Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme**
muss das konkrete signierte App-Bundle erlaubt sein. Eine stabile Signatur,
Bundle-ID und ein stabiler App-Pfad helfen macOS, die Berechtigung nach Builds
wiederzuerkennen.

**Bei Anmeldung starten** verwendet `SMAppService.mainApp`. Für zuverlässigen
Anmeldestart sollte die signierte App zuerst nach `/Applications` verschoben
und von dort registriert werden. **Ausgabe beim App-Start automatisch starten**
ist eine getrennte Option.

Fehlt beim Start die gespeicherte Monitoridentität oder wird der Monitor
getrennt, wartet die App ohne Polling auf
`didChangeScreenParametersNotification`. Bei eindeutiger Rückkehr startet eine
gewünschte automatische Ausgabe wieder. Ein manueller Stopp unterdrückt jeden
automatischen Neustart für die laufende App-Sitzung; erst ein ausdrückliches
**Ausgabe starten** hebt die Unterdrückung auf. Aufnahme- oder Renderfehler
werden blockiert, statt Neustartschleifen zu erzeugen.

## Einschränkungen

- Bei nur einem Monitor überdeckt die Ausgabe den dortigen Schreibtisch und
  meist auch das Steuerfenster. Das Statusmenü in der Menüleiste bleibt zum
  Stoppen und erneuten Anzeigen der Steuerung verfügbar.
- Der ausgewählte Monitor bleibt technisch Teil des macOS-Schreibtischs.
- DRM-/HDCP-geschützte Inhalte können von macOS **schwarz** geliefert werden.
- Audio wird nicht übertragen; der Mauszeiger wird erfasst.
- Seriennummernlose, identische Monitore ohne eindeutige UUID, Namen oder
  native Abmessungen erfordern eine erneute manuelle Auswahl.
- Das Build-Skript erzeugt standardmäßig die aktuelle Mac-Architektur, kein
  Universal Binary.
