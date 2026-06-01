# FHEM-FileManager

Browser-basierter Dateimanager für FHEM — Dateien per Webbrowser hochladen und herunterladen.

---

## Voraussetzungen

- FHEM ab Version 6.x
- Perl-Kernmodule (keine zusätzlichen Abhängigkeiten)

---

## Installation

### Manuell

Datei `FHEM/98_FileManager.pm` in das FHEM-Modulverzeichnis kopieren:

```bash
cp FHEM/98_FileManager.pm /opt/fhem/FHEM/
```

Dann in FHEM:
```
reload 98_FileManager
```

### Über FHEM Update (controls_FileManager.txt)

In `fhem.cfg` oder der FHEM-Oberfläche:
```
update add https://raw.githubusercontent.com/ahlers2mi/fhem-filemanager/main/controls_FileManager.txt
update
```

---

## Einrichtung

### Gerät definieren

```
define myFM FileManager /opt/fhem/upload
```

Danach ist der Dateimanager erreichbar unter:
```
http://<fhem-ip>:8083/fhem/FileManager/myFM
```

---

## Attribute

| Attribut | Werte | Beschreibung |
|---|---|---|
| `allowedExtensions` | z.B. `.txt,.csv,.png` | Nur diese Dateiendungen dürfen hochgeladen werden |
| `disable` | `0`, `1` | Modul deaktivieren |

---

## Get-Befehle

```
get myFM list       # Dateien im Verzeichnis auflisten
get myFM version    # Modulversion anzeigen
```

---

## Readings

| Reading | Beschreibung |
|---|---|
| `state` | `active` oder `disabled` |
| `lastUploadFile` | Dateiname des zuletzt hochgeladenen Files |
| `lastUploadTime` | Zeitstempel des letzten Uploads |
| `lastUploadSize` | Dateigröße des letzten Uploads |
| `lastDownloadFile` | Dateiname des zuletzt heruntergeladenen Files |
| `lastDownloadTime` | Zeitstempel des letzten Downloads |

---

## Changelog

| Version | Änderung |
|---|---|
| 1.4.0 | Fix: POST-Body aus `$arg`, Methode aus Request-Line ermitteln |
| 1.3.0 | Debug-Version |
| 1.2.0 | Fix: FHEMWEB speichert Upload in `FORM{file}` + `FORM{"file.name"}` |
| 1.1.0 | Fix: `/FileManager` Prefix-Key für FHEMWEB Routing (404-Fix) |
| 1.0.0 | Erstversion |

---

## Lizenz

GNU General Public License v2 — siehe [FHEM-Lizenzhinweise](https://fhem.de).
