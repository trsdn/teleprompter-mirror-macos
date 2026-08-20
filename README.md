# Teleprompter Mirror

Teleprompter Mirror ist eine eigenständige native macOS-App für einen
Teleprompter- oder Spiegelglas-Aufbau. Sie erzeugt einen **privaten virtuellen
Quellmonitor**, erfasst diesen mit ScreenCaptureKit, spiegelt bzw. dreht das
Bild und zeigt das Ergebnis vollflächig auf einem **physischen Zielmonitor**.
Das Seitenverhältnis bleibt erhalten; freie Flächen sind schwarz.

Die Präsentation (PowerPoint, Keynote, Browser …) wird auf den virtuellen
Quellmonitor gelegt; der physische Zielmonitor – standardmäßig ein Monitor
namens **AAA**, sofern vorhanden – zeigt den gespiegelten/gedrehten Stream.
Weil Quelle und Ziel getrennt sind, verdeckt die Vollbildausgabe die Quelle
nicht und es entsteht keine optische Endlosschleife.

Es gibt keine Drittanbieterpakete oder dauerhaft installierten Daemons. Eine
zweite Instanz derselben signierten Binary läuft während der App-Laufzeit
headless als lokaler Display-Host.

## Warum ein virtueller Quellmonitor

Eine Aufnahme desselben physischen Monitors, auf dem auch die Vollbildausgabe
liegt, ist nicht sinnvoll: Die Ausgabe überdeckt die Quelle. Deshalb erzeugt
die App über die **private CoreGraphics-API** (`CGVirtualDisplay`,
`CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`,
`CGVirtualDisplayMode`) einen synthetischen Monitor „Teleprompter Source“ mit
`1920×1080@60`.

- Die privaten Klassen werden ausschließlich über `NSClassFromString`
  instanziiert (siehe `Sources/VirtualDisplayBridge`, ein separater
  Objective-C-Ziel­baustein mit ARC). Es werden keine privaten Symbole
  gelinkt.
- Der Hauptprozess startet dieselbe signierte Binary mit einem internen
  Headless-Argument. Nur dieser Display-Host hält das `CGVirtualDisplay`-
  Objekt; der Hauptprozess verwendet ausschließlich ScreenCaptureKit und die
  Ausgabe. Diese Prozessgrenze ist auf macOS 26 erforderlich, weil ein normal
  über Finder/LaunchServices gestarteter Prozess für einen selbst erzeugten
  virtuellen Monitor keine zuverlässigen Capture-Callbacks erhält.
- Der Display-Host beendet sich zusammen mit dem Hauptprozess; der virtuelle
  Monitor verschwindet dadurch spätestens eine Sekunde nach dem App-Ende.
- Der virtuelle Monitor erhält eine stabile synthetische Kennung
  (Hersteller/Produkt/Seriennummer) und sRGB-Primärfarben, damit ein Preset
  ihn nicht mit echter Hardware verwechselt.

Der Display-Host meldet die tatsächliche `CGDirectDisplayID` einmalig über
eine private Pipe an den Hauptprozess. Als Aufnahmequelle dient ausschließlich
der `SCDisplay` mit exakt dieser ID. ScreenCaptureKit wird dafür kurz und
begrenzt erneut abgefragt; es gibt keinen Fallback über Namen, Position oder
den zuletzt erschienenen Monitor. Nach der ersten Erkennung wartet die App
einmalig fünf Sekunden, weil macOS 26 einen neuen virtuellen Monitor bereits
auflisten kann, bevor dessen Capture-Framebuffer bereit ist. Der Filter
verwendet `excludingWindows: []`, da App- und Ausgabefenster auf physischen
Monitoren liegen und niemals auf der virtuellen Quelle erscheinen.

Das Vollbild-Ausgabefenster ist randlos, klickdurchlässig, wird nie zum Haupt-
oder Tastaturfenster und aktiviert die App nicht. Vor dem Start wird das
Steuerfenster nach Möglichkeit auf einen anderen physischen Monitor
verschoben – niemals auf den unsichtbaren virtuellen Monitor.

## Teleprompter-Aufbau

1. Den physischen Zielmonitor so platzieren, dass er in das Spiegelglas
   strahlt.
2. Das Glas typischerweise ungefähr im 45°-Winkel vor der Kamera montieren.
3. Standardmäßig ist **Horizontal spiegeln** bei **0°** aktiv. Je nach
   physischem Aufbau Drehung und vertikale Spiegelung anpassen.
4. Die Sprecheransicht bzw. Präsentation auf den virtuellen Monitor
   „Teleprompter Source“ ziehen und die Schriftgröße für den tatsächlichen
   Kameraabstand wählen.

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

Der Test erstellt den virtuellen Quellmonitor, wählt den Standard-Zielmonitor,
startet die Ausgabe und meldet `SELF_TEST_PASS`, sobald ein vollständiger Frame
des virtuellen Quellmonitors angenommen wurde und die Ausgabeschicht den
Rendering-Status meldet – andernfalls `SELF_TEST_FAIL`. Ohne vorhandene
Berechtigung meldet er `SELF_TEST_SKIP`; er fordert sie nicht an und verändert
keine TCC-Einstellung. Der Test ersetzt keine Sichtprüfung: Er trifft weder
eine Aussage über tatsächlich sichtbare Pixel noch darüber, ob die Spiegelung
im physischen Aufbau korrekt orientiert ist.

## Bedienung

1. Einen der drei Preset-Slots auswählen und bei Bedarf benennen.
2. Den physischen **Zielmonitor** für die Ausgabe auswählen (Vorgabe: **AAA**,
   sonst der kleinste externe Monitor).
3. Drehung `0°`, `90°`, `180°` oder `270°` sowie horizontale und vertikale
   Spiegelung einstellen.
4. **Preset speichern** wählen.
5. Bildschirmaufnahme erlauben.
6. Die Präsentation auf den virtuellen Monitor „Teleprompter Source“ ziehen.
7. **Ausgabe starten** wählen.

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

Die Aufnahme ist auf 30 Hz und `queueDepth = 4` begrenzt. Nur
ScreenCaptureKit-Screen-Samples mit Frame-Status `complete`, gültigem
Sample-Buffer und `CVPixelBuffer` werden weitergereicht. Die Capture-Fläche
entspricht mit BGRA `1920×1080` exakt dem virtuellen Quellmodus; Audio ist aus,
der Mauszeiger ist sichtbar.

Der bevorzugte Pfad
`ScreenCaptureKit → AVSampleBufferDisplayLayer` reicht IOSurface-gestützte
BGRA-Puffer readiness- und backpressure-gesteuert direkt weiter; Frames werden
nicht angestaut. Eine Sitzung kann höchstens einmal auf
`Core Image → CALayer` zurückfallen. Dieser sichere Fallback hält nur den
neuesten Frame und erzeugt Kontext und 30-Hz-Timer erst bei Bedarf. Beim
Stoppen werden Frame, Timer, Layer und Kontext freigegeben. Die App verwendet
kein `MTKView`. Eine zunächst leere virtuelle Quelle bleibt aktiv, damit
PowerPoint oder ein anderes Fenster auch später auf den virtuellen Desktop
verschoben werden kann. Echte Stream- und Renderfehler werden weiterhin
explizit gemeldet.

Der vollständige Finder-/LaunchServices-Pfad wurde auf macOS 26.6.1 mit einem
asymmetrischen L/R-Testbild auf dem physischen Zielmonitor AAA visuell geprüft:
Das rote `R` erschien links und das gelbe `L` rechts, die horizontale
Spiegelung war damit korrekt.

## Presets und Monitoridentität

Jeder der drei benannten Presets speichert genau eine **Zielmonitoridentität**
und die Transformation per `Codable` in `UserDefaults`. Die Quelle ist immer
der virtuelle Monitor und muss nicht gespeichert werden. Presets aus der
früheren Version, die noch eine Monitoridentität unter `display` gespeichert
haben, werden weiterhin als Zielmonitor übernommen. Eine Identität kombiniert,
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
wiederzuerkennen. Das Erstellen des virtuellen Monitors selbst benötigt keine
Bildschirmaufnahme-Berechtigung; nur seine Erfassung.

**Bei Anmeldung starten** verwendet `SMAppService.mainApp`. Für zuverlässigen
Anmeldestart sollte die signierte App zuerst nach `/Applications` verschoben
und von dort registriert werden. **Ausgabe beim App-Start automatisch starten**
ist eine getrennte Option.

Fehlt beim Start der gespeicherte Zielmonitor oder wird er getrennt, wartet die
App ohne Polling auf `didChangeScreenParametersNotification`. Bei eindeutiger
Rückkehr startet eine gewünschte automatische Ausgabe wieder. Ein manueller
Stopp unterdrückt jeden automatischen Neustart für die laufende App-Sitzung;
erst ein ausdrückliches **Ausgabe starten** hebt die Unterdrückung auf.
Aufnahme- oder Renderfehler werden blockiert, statt Neustartschleifen zu
erzeugen.

## Einschränkungen

- Die App nutzt eine **private, nicht dokumentierte** CoreGraphics-API für den
  virtuellen Monitor. Diese kann sich zwischen macOS-Versionen ändern und ist
  **nicht App-Store-tauglich**. Ist die API nicht verfügbar, meldet die App
  dies und startet keine Ausgabe.
- Die Spiegelung erfolgt in der Ausgabe-Ebene (Core Animation / Core Image).
  Es findet **kein** physischer Scanout-Flip des Monitors statt; die App kann
  daher nicht garantieren, dass die Orientierung im konkreten Spiegelglas-
  Aufbau korrekt ist – Drehung und Spiegelung sind entsprechend einzustellen.
- Ist nur ein physischer Monitor verbunden, dient dieser als Ziel und die
  Ausgabe überdeckt dort den Schreibtisch. Die Menüleiste bleibt über dem
  klickdurchlässigen Ausgabefenster erreichbar, sodass das Statusmenü zum
  Stoppen und erneuten Anzeigen der Steuerung verfügbar bleibt.
- Der virtuelle Monitor ist headless und verwendet einen 1920×1080-HiDPI-
  Framebuffer; Fenster müssen ggf. „blind“ dorthin verschoben werden.
- DRM-/HDCP-geschützte Inhalte können von macOS **schwarz** geliefert werden.
- Audio wird nicht übertragen; der Mauszeiger wird erfasst.
- Seriennummernlose, identische Zielmonitore ohne eindeutige UUID, Namen oder
  native Abmessungen erfordern eine erneute manuelle Auswahl.
- Das Build-Skript erzeugt standardmäßig die aktuelle Mac-Architektur, kein
  Universal Binary.
