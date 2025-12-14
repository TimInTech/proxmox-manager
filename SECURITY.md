# Security Policy

## Supported Versions

<!-- markdownlint-disable MD060 -->
| Version | Supported |
| ------- | --------- |
| main    | ✅        |
<!-- markdownlint-enable MD060 -->

All unreleased changes merged into `main` are expected to pass the automated
sanity workflows described in `.github/workflows/`.

## Reporting a Vulnerability

1. **Öffnen Sie ein öffentliches GitHub Issue** in diesem Repository. Wählen
   Sie einen Titel, der die Schwachstelle eindeutig aber nicht zu präzise
   beschreibt, um eine sofortige Ausnutzung zu erschweren.
2. Fügen Sie eine klare Beschreibung hinzu: Schritte zur Reproduktion,
   erwartetes vs. tatsächliches Verhalten, potenzieller Impact sowie
   (falls vorhanden) ein möglicher Mitigation/Korrektur-Vorschlag.
3. Sie erhalten eine Bestätigung innerhalb von 72 Stunden (Kommentar oder
   Label). Ziel: Innerhalb von 14 Tagen einen Fix oder eine Gegenmaßnahme
   bereitstellen.
4. Der Fortschritt (Analyse, Patch, Release) wird transparent im Issue
   dokumentiert. Nach Merge eines Fixes erfolgt die Veröffentlichung im
   nächsten regulären Release.
5. Falls die Schwachstelle bereits aktiv ausnutzbar erscheint, kann das
   Maintainer-Team Teilinformationen kurzfristig zurückhalten (z. B.
   Exploit-Snippets), bis ein Fix veröffentlicht wurde.

Durch diese öffentliche Meldung akzeptieren Sie das erhöhte Risiko einer
frühen Ausnutzung durch Dritte. Bitte tätigen Sie keine Tests, die die
Integrität oder Verfügbarkeit produktiver Systeme gefährden.
