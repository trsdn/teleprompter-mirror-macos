# Mitwirken

Danke für dein Interesse an Teleprompter Mirror. Dieses Projekt ist bewusst
klein gehalten – bitte lies vor größeren Änderungen den Abschnitt
[Projektumfang](#projektumfang).

## Voraussetzungen

- macOS 13 oder neuer (entwickelt und getestet auf aktuellen Versionen)
- Xcode-Kommandozeilenwerkzeuge mit Swift 6.1 oder neuer
  (`swift-tools-version: 6.1`, siehe `Package.swift`)
- Für signierte Builds: ein „Developer ID Application“- oder
  „Apple Development“-Zertifikat im Schlüsselbund

Es gibt keine Drittanbieter-Abhängigkeiten. `swift build` genügt.

## Entwicklungsablauf

```bash
swift build          # übersetzen
swift test           # Unit-Tests ausführen
./build-app.sh       # signiertes .app-Bundle nach dist/ erzeugen
```

Das App-Icon wird aus Code erzeugt und liegt als `Resources/AppIcon.icns` im
Repository. Nach Änderungen an `Scripts/make-icon.swift` neu generieren:

```bash
swift Scripts/make-icon.swift
```

Für einen Rauchtest ohne echten Zielmonitor gibt es einen Selbsttest:

```bash
open "dist/Teleprompter Mirror.app" --args --self-test
```

Er meldet `SELF_TEST_PASS`, wenn Capture-Aufbau und Ausgabe funktionieren.

## Vor dem Pull Request

- `swift build` läuft ohne Warnungen durch.
- `swift test` ist grün.
- Die Änderung wurde mit mindestens einer Quelle manuell geprüft.
- Verhaltensänderungen sind in der `README.md` beschrieben.

## Konventionen

- **Sprache:** Alle Texte, die Nutzende sehen – UI-Beschriftungen, Statusmeldungen,
  Fehlermeldungen, Skriptausgaben – sind auf **Deutsch**. Code-Kommentare und
  Symbolnamen sind auf **Englisch**.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/),
  Betreffzeile auf Deutsch, z. B. `fix: Ausgabe überdeckt die Menüleiste`.
- **Formatierung:** Vier Leerzeichen Einrückung, Zeilenlänge 80 Zeichen als
  Richtwert.
- **Abhängigkeiten:** Keine. Wenn eine Aufgabe ohne fremdes Paket lösbar ist,
  wird sie ohne gelöst.
- **Private APIs:** Der Zugriff auf `CGVirtualDisplay` und Verwandte erfolgt
  ausschließlich über `NSClassFromString` in `Sources/VirtualDisplayBridge`.
  Private Symbole werden nicht gelinkt.

## Projektumfang

Die App macht genau eines: eine Quelle erfassen, das Bild spiegeln bzw. drehen
und es vollflächig auf einem Zielmonitor ausgeben – bei möglichst geringem
Ressourcenverbrauch.

Ausdrücklich **nicht** Teil des Projekts sind Texteditor, Skriptverwaltung,
Laufschrift, Fernsteuerung und Aufzeichnung. Für solche Funktionen gibt es
spezialisierte Teleprompter-Anwendungen.

## Fehler melden

Bitte nutze die [Issue-Vorlagen](https://github.com/trsdn/teleprompter-mirror-macos/issues/new/choose).
Sicherheitsrelevante Funde bitte **nicht** als Issue anlegen, sondern wie in
[SECURITY.md](SECURITY.md) beschrieben melden.

## Umgang miteinander

Für alle Projektbereiche gilt der [Verhaltenskodex](CODE_OF_CONDUCT.md).
