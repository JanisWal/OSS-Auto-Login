# OSS Auto-Login für Safari (macOS)

Meldet dich in Safari bei der **Online-Schule Saarland (OSS)** automatisch wieder an,
wenn du rausgeworfen wirst, und bringt dich danach zu der Seite zurück, auf der du
warst. Dein Passwort kann **verschlüsselt** auf dem Mac gespeichert werden und ist
nur mit **Touch ID** wieder abrufbar.

Das Programm besteht aus einer einzigen Datei: `OSS-Auto-Login.command`

---

## Inhalt

1. [Einrichtung](#1-einrichtung)
2. [Befehle im Terminal](#2-befehle-im-terminal)
3. [Was im Alltag passiert](#3-was-im-alltag-passiert)
4. [Technischer Aufbau](#4-technischer-aufbau)
5. [Sicherheit](#5-sicherheit)
6. [Grenzen](#6-grenzen)
7. [Hinweis](#7-hinweis)

---

## 1. Einrichtung

1. **Die Datei `OSS-Auto-Login.command` doppelklicken.**
   Warnt macOS, Rechtsklick auf die Datei, dann **Öffnen**.
2. **Zwei Fenster beantworten:** die OSS-Adresse (ist schon eingetragen) und dein
   Benutzername. Danach schließt sich das Fenster von selbst.
3. **In Safari zwei Einstellungen setzen:**
   - *Safari → Einstellungen → Erweitert:* Haken bei **„Funktionen für Webentwickler anzeigen“**.
   - *Menü „Entwickler“:* Haken bei **„JavaScript aus Apple-Events erlauben“**.

Mehr ist nicht nötig. Adresse und Benutzername musst du nicht erneut eingeben.

Beim ersten erfolgreichen Login wird dein Passwort verschlüsselt gespeichert, sofern
Touch ID eingerichtet ist.

---

## 2. Befehle im Terminal

Das Terminal brauchst du nur für Sonderfälle.

### Aufbau eines Befehls

```bash
./OSS-Auto-Login.command BEFEHL
```

- `./OSS-Auto-Login.command` ist der **feste Teil**. Er startet das Programm.
  Das `./` bedeutet „die Datei hier im aktuellen Ordner“.
- `BEFEHL` ist der **austauschbare Teil**, zum Beispiel `status` oder `touchid off`.
- Zwischen Dateiname und Befehl steht **genau ein Leerzeichen**. Kein Schrägstrich
  und kein Punkt dazwischen, und nichts direkt hinter den Dateinamen setzen.

### Vorher in den richtigen Ordner wechseln

Das Terminal startet im Persönlichen Ordner. Die Datei liegt im Ordner
`OSS Auto-Login`. Deshalb zuerst:

```bash
cd "$HOME/OSS Auto-Login"
```

Die Anführungszeichen sind wegen des Leerzeichens im Ordnernamen nötig.

### Das Terminal öffnen

**Befehl-Taste + Leertaste**, „Terminal“ tippen, **Enter**. Befehle stehen hinter dem
`%` und werden mit Enter bestätigt.

### Alle Befehle anzeigen

```bash
./OSS-Auto-Login.command help
```

### Die Befehle

| Befehl | Was er macht |
| --- | --- |
| `status` | Zeigt, ob der Dienst aktiv oder pausiert ist, ob ein Passwort im Langzeitspeicher liegt, den Stand von `store` und `touchid` und die letzten Ereignisse. |
| `check` | Zeigt, was Safari gerade meldet (offene OSS-Tabs und ihr Zustand). |
| `pause` / `resume` | Hält das automatische Anmelden an bzw. schaltet es wieder ein. |
| `password` | Vergisst das Passwort im Arbeitsspeicher sofort. Der Langzeitspeicher bleibt. |
| `store on` | Hält das Passwort zusätzlich **im Arbeitsspeicher**, zwischen den Anmeldungen. |
| `store off` | Hält das Passwort **nicht** im Arbeitsspeicher (Standard). Es wird bei Bedarf aus dem Langzeitspeicher geholt. |
| `touchid on` | Touch ID wird beim Einsetzen des gespeicherten Passworts zuerst gefragt (Standard). |
| `touchid off` | Das gespeicherte Passwort wird ohne Touch ID eingesetzt, solange der Mac entsperrt ist. Das gespeicherte Passwort wird dabei gelöscht. |
| `logout` | Beendet die Sitzungen von OSS-Portal und Anmeldedienst sofort. |
| `reset` | Entfernt alles und richtet neu ein. Fragt vorher nach; `reset --yes` überspringt die Frage. |
| `uninstall` | Entfernt alles, auch das gespeicherte Passwort. Fragt vorher nach; `uninstall --yes` überspringt die Frage. |
| `help` | Zeigt alle Befehle mit kurzer Erklärung. |

Startest du die Datei ohne Befehl (also nur `./OSS-Auto-Login.command`), passiert
dasselbe wie beim Doppelklick: Ist noch nichts eingerichtet, werden die Fragen
gestellt. Ist alles eingerichtet, wird der Dienst auf den Stand der Datei gebracht,
falls sich die Datei geändert hat.

---

## 3. Was im Alltag passiert

**Du klickst auf „Anmelden“.**
Mit gespeichertem Passwort fragt macOS **zuerst nach Touch ID**. Der Fingerabdruck
hat Vorrang. Danach wird das Passwort eingesetzt.
Brichst du die Touch-ID-Abfrage ab oder schlägt sie fehl, erscheint ein Fenster zum
**Eintippen** des OSS-Passworts.
*Touch ID und das Eingabefeld erscheinen nicht gleichzeitig. macOS zeigt die
Touch-ID-Abfrage als eigenes Fenster ohne Textfeld.*

**Du wirst rausgeworfen (Sitzung abgelaufen).**
Mit `store off` (Standard) fragt macOS erneut nach Touch ID und setzt das Passwort ein.
Mit `store on` ist das Passwort noch im Arbeitsspeicher, dann meldet sich das Programm
ohne Abfrage an. In beiden Fällen bringt es dich zu der Seite zurück, auf der du warst.

**Du meldest dich bewusst ab.**
Das Passwort wird aus dem Arbeitsspeicher entfernt, die Sitzungen von OSS-Portal und
Anmeldedienst werden beendet. Der verschlüsselte Langzeitspeicher bleibt erhalten.
Die nächste Anmeldung braucht Touch ID oder das Passwort.

**Zwei Fehlversuche hintereinander.**
Es erscheint ein Fenster für ein neues Passwort. „Abbrechen“ behält das bisherige.

**Mac-Neustart.**
Der Arbeitsspeicher ist danach leer. Der verschlüsselte Langzeitspeicher bleibt. Die
erste Anmeldung braucht nur Touch ID.

**Bildschirmsperre und Ruhezustand** löschen nichts.

---

## 4. Technischer Aufbau

### Dateien

```
~/OSS Auto-Login/
└── OSS-Auto-Login.command         das Programm (diese Datei)

~/.oss-autologin/                   Daten des Programms (versteckt)
├── oss-autologin.sh               Arbeitskopie, die der Dienst ausführt
├── config                         Adresse, Benutzername, Einstellungen (ohne Passwort)
├── log.txt                        kurzes Protokoll (ohne Passwörter)
├── ossvault                       kleines Hilfsprogramm, auf dem Mac gebaut
├── se.key                         Verweis auf den Schlüssel im Chip
├── se.pub                         öffentlicher Teil des Schlüssels (nicht geheim)
└── secret.bin                     das verschlüsselte Passwort

~/Library/LaunchAgents/local.oss-autologin.plist
                                    startet den Dienst bei jeder Anmeldung am Mac
```

### Ablauf

- Der Dienst läuft als Hintergrundprozess von macOS. Etwa alle zwei Sekunden prüft er
  die offenen Safari-Tabs mit der OSS-Adresse und merkt sich deren Zustand
  (Anmeldeseite, Abmelde-Seite, Zwischenseite oder normale Seite).
- Safari wird über AppleScript gesteuert. Das Ausfüllen des Formulars geschieht mit
  JavaScript in der Seite, nur auf der Anmeldeseite des OSS-Anmeldedienstes.
- Ein zweiter kleiner Prozess prüft nur dann etwa alle 0,15 Sekunden, wenn eine
  OSS-Seite offen ist. So werden auch kurz sichtbare Abmelde-Seiten erkannt.

### Verschlüsselter Langzeitspeicher

- Beim Einrichten erzeugt der **Chip des Macs (Secure Enclave)** einen Schlüssel.
  Der private Teil verlässt den Chip nie.
- Das Passwort wird mit einem einmaligen Schlüssel verschlüsselt (**AES-GCM, 256 Bit**).
  Dieser einmalige Schlüssel wird mit dem öffentlichen Teil des Chip-Schlüssels
  verschlüsselt (**P-256 Key Agreement, HKDF**). Ergebnis: `secret.bin`.
- Zum Entschlüsseln braucht der Chip den privaten Schlüssel. Mit `touchid on` verlangt
  macOS dafür den Fingerabdruck.
- Mit `touchid off` ist der Schlüssel ohne Fingerabdruck-Sperre. Dann entschlüsselt der
  Chip, solange der Mac entsperrt ist.

### Arbeitsspeicher

- Der Langzeitspeicher ist immer die Grundlage. Der Arbeitsspeicher wird nur zum
  Einsetzen genutzt, und mit `store on` zusätzlich zwischen den Anmeldungen.
- **`store off` (Standard):** Nach dem Einsetzen wird das Passwort sofort aus dem
  Arbeitsspeicher entfernt.
- **`store on`:** Das Passwort bleibt im Arbeitsspeicher, bis du dich bewusst abmeldest,
  den Dienst neu startest oder den Mac neu startest.
- Eine bewusste Abmeldung löscht den Arbeitsspeicher, nie den Langzeitspeicher.

### Gemerkte Seiten

- Die letzten 10 besuchten OSS-Seiten liegen nur im Arbeitsspeicher, nie in einer
  Datei und nie im Protokoll.
- Gemerkt werden nur `https`-Adressen der OSS-Domain. Anmelde-, Abmelde- und
  Shibboleth-Adressen werden nicht gemerkt, ebenso fremde Seiten.

### Protokoll

- `log.txt` hält nur die letzten 200 Zeilen und enthält keine Passwörter.

---

## 5. Sicherheit

### Was gemacht wurde

- Das Passwort liegt verschlüsselt auf der Festplatte. Der Schlüssel steckt im Chip und
  verlässt ihn nicht. Ohne diesen Chip ist `secret.bin` nutzlos, auch auf einem anderen Mac.
- Mit `touchid on` wird ohne Fingerabdruck nichts entschlüsselt.
- Passwörter stehen nicht im Protokoll, nicht in der Konfiguration und nicht als
  Befehlsargument. Das Passwort wird über die Standardeingabe an den Helfer übergeben.
- Dateien und Ordner sind nur für dich lesbar (Rechte `600` bzw. `700`).
- Eine bewusste Abmeldung beendet die Sitzungen bei OSS. Die nächste Anmeldung braucht
  Touch ID oder das Passwort.
- Das Programm beendet nur Sitzungen der OSS-Domain. Fremde Seiten werden nicht
  angefasst. Tabs werden über eine eindeutige Markierung gefunden, nie über ihre Position.
- Höchstens zwei automatische Versuche hintereinander. Danach wird nachgefragt, das
  schützt vor einer Kontosperre bei falschem Passwort.

### Was man bedenken sollte

- **Entsperrter Mac und `touchid off`:** Ein Klick auf „Anmelden“ reicht, um das
  gespeicherte Passwort einzusetzen. Wer am Mac sitzt, kann sich dann bei OSS anmelden.
  Deshalb: Mac sperren, wenn du weggehst.
- **`store on`:** Das Passwort liegt dann unverschlüsselt im Arbeitsspeicher des
  Dienstes. Ein Programm mit deinen Rechten, das Speicher auslesen kann, könnte es dort
  finden. Das ist der größte Unterschied zu `store off`.
- **Schadsoftware** mit deinen Rechten könnte den Touch-ID-Dialog auslösen. Der
  Fingerabdruck muss trotzdem von dir kommen. Lege den Finger nur auf, wenn du selbst
  gerade bei OSS anmeldest.
- **Wer das OSS-Passwort kennt,** kann es im Eingabefenster eintippen. Das Programm
  schützt das Passwort nicht vor Menschen, die es kennen.
- **Der Fingerabdruck wirkt nur** für Finger, die im Mac eingerichtet sind.
- **Safari** fragt eventuell, ob es das Passwort speichern soll. Lehne das ab, sonst liegt
  es zusätzlich im iCloud-Schlüsselbund.
- **Die Safari-Einstellung „JavaScript aus Apple-Events erlauben“** gibt Programmen mit
  Automatisierungsrecht Zugriff auf den Inhalt von Safari. Erlaube sie nur Programmen,
  denen du vertraust.
- **Ein Mac ohne Touch ID** kann das Passwort nicht verschlüsselt speichern. Dort wird es
  bei jeder Anmeldung eingetippt.

### Ehrlich gesagt

- Das ist ein **Kompromiss zwischen Bequemlichkeit und Schutz**, kein vollständiger
  Schutz. Ein Schadprogramm mit vollen Rechten auf deinem Benutzer kann mehr, als dieses
  Programm verhindern kann.
- Das Programm ist ein Projekt ohne Prüfung durch Dritte und ohne Gewähr (siehe
  [LICENSE](LICENSE)).

---

## 6. Grenzen

- Nur Safari, nur macOS, nur ein Konto.
- Ändert OSS den Aufbau der Anmeldeseite oder die Abmelde-Adressen
  (`psc…/saml2/logout` und `idp…/idp/profile/Logout`), muss das Programm angepasst werden.
- Der Verlauf der gemerkten Seiten ist an die Tab-Nummer gebunden. Verschieben sich die
  Nummern durch das Schließen eines Tabs, kann die Rückkehr auf eine andere, vorher
  besuchte OSS-Seite führen.
- Die Rückkehr stellt nur die Adresse wieder her. Nicht abgeschickte Eingaben in
  Formularen gehen verloren.
- Erscheint ein Dialog, wird das Safari-Fenster grau, weil das Programm den Dialog nach
  vorn holt. Das ist normales macOS-Verhalten. Ein Klick ins Fenster macht es wieder aktiv.

---

## 7. Hinweis

> **Lehrkräfte sollten das Tool aufgrund sensibler Daten nicht verwenden.**
