# Sicherheitsrichtlinie

## Unterstützte Versionen

Sicherheitskorrekturen erscheinen für die jeweils neueste Veröffentlichung.
Ältere Versionen werden nicht gepflegt.

## Schwachstelle melden

Bitte melde Schwachstellen **nicht** über ein öffentliches Issue.

Nutze stattdessen die private Meldefunktion von GitHub:
[Security Advisory melden](https://github.com/trsdn/teleprompter-mirror-macos/security/advisories/new).

Hilfreich für die Analyse sind:

- betroffene App-Version und macOS-Version,
- eine Beschreibung der Auswirkung,
- eine möglichst knappe Reproduktion.

Du erhältst in der Regel innerhalb von sieben Tagen eine Rückmeldung.

## Sicherheitsrelevanter Kontext

Für die Bewertung von Meldungen ist folgender Aufbau relevant:

- Die App benötigt die Berechtigung **Bildschirmaufnahme**. Aufgenommene Bilder
  werden ausschließlich lokal verarbeitet und auf einem Monitor angezeigt. Es
  gibt keine Netzwerkkommunikation, keine Telemetrie und keine Speicherung von
  Bildinhalten auf der Festplatte.
- Im Modus **Virtueller Monitor** startet die App eine zweite Instanz derselben
  signierten Binary als headless Display-Host. Gestartet wird ausschließlich der
  eigene Bundle-Pfad; es werden keine externen Programme ausgeführt.
- Der Zugriff auf die privaten CoreGraphics-Klassen erfolgt dynamisch über
  `NSClassFromString`, ohne Linken privater Symbole.
- Einstellungen liegen unverändert in den `UserDefaults` der App. Es werden
  keine Zugangsdaten oder personenbezogenen Daten gespeichert.
- Die Bundles werden mit „Developer ID“ und aktivierter Hardened Runtime
  signiert.
