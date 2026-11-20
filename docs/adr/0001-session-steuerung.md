# ADR 0001: Vorlesen pro Session steuern

Status: angenommen · 2026-11-20 · ab Version 0.4.0

## Kontext

Bisher gab es nur einen globalen Schalter: Entweder wurden alle Claude-Code-Sessions vorgelesen oder keine. Wer mehrere Agenten parallel laufen lässt, will aber einzelne Sessions oder ganze Projekte ausblenden, oder umgekehrt nur ausgewählte hören. Das soll schnell im Overlay gehen, vor allem der Fall „Standard ist stumm, diese eine Session will ich jetzt hören“.

Der Stop-Hook bekommt pro Antwort `session_id`, `cwd`, `transcript_path` und `last_assistant_message`, aber keinen Session-Titel. `/clear` erzeugt eine neue Session-ID ohne Verweis auf die alte. Der Verlauf in `transcript_path` ist beim Stop-Hook nicht zuverlässig vollständig.

## Entscheidung

1. **Standard plus Ausnahmen statt zweier Modi.** Eine Einstellung „Neue Sessions: vorlesen / stumm“. „Blacklist“ und „Opt-in“ sind damit derselbe Mechanismus mit unterschiedlichem Standard. Nach dem Update gilt „vorlesen“, es ändert sich also nichts.
2. **Zwei Ebenen von Ausnahmen:** pro Session und pro Projekt. Projekt-Regeln überstehen `/clear`. Rangfolge: `AGENT_SPEAK` → Session-Ausnahme → Projekt-Regel → Standard.
3. **Projekt = Git-Repository samt Worktrees,** sonst der Ordner samt Unterordnern. Sessions laufen oft in Worktrees mit eigenen Pfaden; eine Regel für das Repo muss dort trotzdem greifen. Der Hook ermittelt das Repo ohne `git`-Aufruf aus `.git` bzw. `commondir`.
4. **Der große Overlay-Schalter bleibt die Ruhe-Taste** (vorübergehend alles stumm, Regeln bleiben unverändert). Darunter kommt eine **Session-Zeile** für die zuletzt fertige Session: ein Klick schaltet sie um; wird eine stumme Session mit ungehörter Antwort freigegeben, wird diese sofort vorgelesen. Ein Pfeil daneben öffnet eine Liste mit bis zu 8 Sessions der letzten 24 Stunden.
5. **Stumme Sessions kosten nichts.** Der Hook prüft die Regeln vor `claude -p`. Statt zusammenzufassen speichert er nur die letzte Antwort als „ungehört“ (eigene Datei, nicht aus dem Verlauf). Zusammengefasst wird erst beim Anhören. Das gilt auch, solange die Ruhe-Taste aktiv ist.
6. **Hinweis auf Ungehörtes:** ein dezenter Punkt am eingeklappten Griff, kein Ton. Er verschwindet, sobald das Overlay geöffnet wird; die Punkte an den einzelnen Sessions bleiben, bis die Antwort gehört oder ersetzt wird.
7. **Beschriftung** einer Session: Projektname und Anfang des ersten Prompts (aus dem Verlauf, nach bestem Bemühen), sonst Anfang der letzten Antwort.
8. **Session-Ausnahmen verfallen** nach 7 Tagen ohne Aktivität der Session.
9. **`AGENT_SPEAK=on|off`** als Umgebungsvariable hat Vorrang und wird in der App nur angezeigt (Schloss).
10. **Weitere Bedienorte:** Untermenü „Sessions“ in der Menüleiste (pro Session: vorlesen, ungehörte Antwort vorlesen, Projekt-Regel) und ein Bereich „Sessions“ in den Einstellungen (Standard, Projekt-Regeln, Session-Ausnahmen). Projekt-Regeln werden nicht im Overlay gesetzt, damit es dort bei einem Klick bleibt.

## Umsetzung

Dateien in `~/.claude/hooks/speak-summary/`:

| Datei | Schreibt | Inhalt |
|---|---|---|
| `config` | App | u. a. `NEW_SESSIONS=on\|off` |
| `rules.json` | App | `{"sessions": {"<id>": "on\|off"}, "projects": {"<pfad>": "on\|off"}}` |
| `sessions/<id>.json` | Hook | Projekt, Beschriftung, zuletzt gesehen, ungehört ja/nein, `AGENT_SPEAK`-Sperre |
| `sessions/<id>.reply` | Hook | ungehörte Antwort (nur solange ungehört) |
| `unheard` | Hook, App löscht | Punkt am eingeklappten Griff |
| `muted` | App | Ruhe-Taste |

Eine Datei pro Session, damit gleichzeitig fertig werdende Sessions sich nicht gegenseitig überschreiben. `rules.json` schreibt nur die App. Neue Aufrufe des Hook-Skripts: `--speak-session <id>` (ungehörte Antwort zusammenfassen und vorlesen) und `--project-root <pfad>`.

## Folgen

- Stumme Sessions verursachen keine Kosten für Zusammenfassungen.
- Subagenten lösen weiterhin keinen Stop-Hook aus und werden nicht vorgelesen.
- Session-Titel aus der Desktop-App oder `/rename` sind für den Hook nicht sichtbar; die Beschriftung ist eine Annäherung.
- Das Format des Verlaufs ist intern und kann sich ändern; fällt das Lesen des ersten Prompts aus, bleibt die Beschriftung aus der letzten Antwort.
