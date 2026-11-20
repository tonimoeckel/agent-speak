# Glossar

Begriffe, wie sie in Agent Speak (App, Hook, Doku) verwendet werden.

**Ansage**
Der vorgelesene Text zu einer Antwort von Claude Code. Entsteht aus der letzten Antwort per `claude -p` (Zusammenfassung) und wird mit ElevenLabs oder der Systemstimme gesprochen.

**Session**
Eine Claude-Code-Sitzung, erkannt an ihrer `session_id` aus dem Stop-Hook. Ein `--resume` behält die ID, `/clear` beginnt eine neue Session. Einen Titel bekommt der Hook nicht mit.

**Beschriftung**
Wie eine Session in App und Menü angezeigt wird: Projektname und der Anfang des ersten Prompts. Lässt sich der erste Prompt nicht lesen, der Anfang der letzten Antwort.

**Projekt**
Das Git-Repository, in dem eine Session läuft, einschließlich aller seiner Worktrees. Außerhalb von Git der Ordner, in dem die Session gestartet wurde, samt Unterordnern.

**Standard**
Die Einstellung „Neue Sessions: vorlesen / stumm“ (`NEW_SESSIONS` in der config). Gilt für jede Session, für die keine Ausnahme greift. Voreinstellung: vorlesen.

**Ausnahme**
Eine Regel, die vom Standard abweicht: für eine einzelne Session (Session-Ausnahme) oder für ein Projekt (Projekt-Regel). Gespeichert in `rules.json`.

**Rangfolge**
Welche Regel gilt, wenn mehrere passen. Es gewinnt die speziellere:
`AGENT_SPEAK` → Session-Ausnahme → Projekt-Regel → Standard.

**`AGENT_SPEAK`**
Umgebungsvariable (`on` oder `off`) beim Start von `claude` oder im `env` einer Projekt-`settings.local.json`. Hat Vorrang vor allem anderen. In der App wird die Session mit Schloss angezeigt und lässt sich dort nicht umschalten.

**Ruhe-Taste**
Der große Schalter im Overlay (früher „Vorlesen an/aus“). Macht vorübergehend alles stumm, ohne Standard oder Ausnahmen zu ändern. Technisch die Datei `muted`.

**Ungehörte Antwort**
Die letzte Antwort einer Session, die nicht vorgelesen wurde, weil die Session stumm war oder die Ruhe-Taste aktiv war. Sie wird nur gespeichert, nicht zusammengefasst; das passiert erst, wenn du sie anhörst. Am eingeklappten Overlay zeigt ein Punkt, dass es Ungehörtes gibt.

**Letzte Session**
Die Session, die zuletzt fertig geworden ist, egal ob sie vorgelesen wurde. Auf sie bezieht sich die Session-Zeile im Overlay.
