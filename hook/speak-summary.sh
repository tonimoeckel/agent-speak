#!/usr/bin/env bash
# Agent Speak – Claude Code Stop-Hook
# Liest nach jeder Antwort von Claude Code eine kurze Zusammenfassung vor.
# Braucht Claude eine Entscheidung, werden Hintergrund und Empfehlung mit vorgelesen.
#
#   speak-summary.sh              -> Hook-Modus (liest Hook-JSON von stdin)
#   speak-summary.sh --test "…"   -> Text direkt zusammenfassen und vorlesen
#   speak-summary.sh --replay     -> letzte Ansage noch einmal vorlesen
#   speak-summary.sh --voices     -> ElevenLabs-Stimmen auflisten (ID + Name)
#   speak-summary.sh --default-prompt [de|en] -> Standard-Prompt ausgeben
#   speak-summary.sh --speak-session <id> -> ungehörte Antwort einer Session zusammenfassen und vorlesen
#   speak-summary.sh --project-root <pfad> -> Projekt (Git-Repo samt Worktrees) zu einem Ordner ausgeben
#   speak-summary.sh --mute|--unmute|--stop|--version
#
# Konfiguration: ~/.claude/hooks/speak-summary/config (wird von der Agent-Speak-App gepflegt)
# Eigener Prompt: ~/.claude/hooks/speak-summary/prompt.txt (optional; {{LAENGE}}/{{LENGTH}} wird ersetzt)
# ElevenLabs-Key im Schlüsselbund, Dienst "elevenlabs-api-key".
#
# Session-Steuerung (siehe docs/adr/0001-session-steuerung.md):
#   rules.json          -> Ausnahmen pro Session und Projekt (schreibt die App)
#   sessions/<id>.json  -> zuletzt gesehene Sessions (schreibt der Hook)
#   sessions/<id>.reply -> ungehörte Antwort einer stummen Session
#   unheard             -> es gibt Ungehörtes (Punkt am Overlay)
#   AGENT_SPEAK=on|off  -> Umgebungsvariable, hat Vorrang vor allen Regeln
#
# Statusdateien (liest die App, um das Overlay zu animieren):
#   muted        -> Ruhe-Taste: vorübergehend alles stumm
#   summarizing  -> Zusammenfassung läuft gerade
#   player.pid   -> Ansage läuft gerade (PID von afplay/say)
#   last.txt     -> zuletzt gesprochener Text

HOOK_VERSION=5

set -u
export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Rekursion verhindern: der Zusammenfassungs-Aufruf von `claude -p` löst selbst wieder Stop aus.
[ -n "${SPEAK_SUMMARY_CHILD:-}" ] && exit 0

DIR="$HOME/.claude/hooks/speak-summary"
SPEAK_LANGUAGE="system"        # system | de | en  (Sprache der Ansagen)
TTS_ENGINE="auto"              # auto | elevenlabs | say
ELEVENLABS_VOICE_ID=""
ELEVENLABS_MODEL="eleven_flash_v2_5"
ELEVENLABS_SPEED="1.0"         # 0.7 … 1.2
SAY_VOICE=""                   # leer = Standardstimme der Sprache
SAY_RATE="190"
SUMMARY_MODEL="haiku"
SUMMARY_LENGTH="normal"        # kurz | normal | ausfuehrlich
NEW_SESSIONS="on"              # on | off  (Standard für Sessions ohne Ausnahme)
CLAUDE_BIN=""
[ -f "$DIR/config" ] && . "$DIR/config"
[ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="claude"

# Sprache: fest eingestellt oder erste bevorzugte Systemsprache (alles außer Deutsch -> Englisch)
resolve_lang() {
  case "$1" in
    de|en) echo "$1" ;;
    *) case "$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | tr -d ' "')" in
         de*) echo de ;;
         *)   echo en ;;
       esac ;;
  esac
}
LANG_CODE=$(resolve_lang "$SPEAK_LANGUAGE")
if [ -z "$SAY_VOICE" ]; then
  if [ "$LANG_CODE" = en ]; then SAY_VOICE="Samantha"; else SAY_VOICE="Anna"; fi
fi

LOG="$DIR/last.log"
SESS="$DIR/sessions"
PIDFILE="$DIR/player.pid"
SUMFILE="$DIR/summarizing"

el_key() { security find-generic-password -s elevenlabs-api-key -w 2>/dev/null; }

stop_playback() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
  rm -f "$PIDFILE"
}

PROMPT_DE='Du bekommst die letzte Antwort eines KI-Coding-Assistenten an einen Entwickler. Schreibe daraus einen Text zum Vorlesen auf Deutsch.
Regeln:
- {{LAENGE}}, gesprochene Sprache, kein Markdown, keine Aufzählungszeichen.
- Keine Dateipfade, URLs, Code, Befehle oder IDs vorlesen; nenne sie höchstens sinngemäß („die Konfigurationsdatei“).
- Zuerst in ein bis zwei Sätzen: was erledigt wurde bzw. das Ergebnis.
- Nur wenn die Antwort eine Entscheidung, Freigabe oder Antwort vom Entwickler braucht: Sag „Du musst entscheiden:“, erkläre den Hintergrund in einem Satz und sag dann „Meine Empfehlung:“ mit dem empfohlenen nächsten Schritt.
- Braucht es keine Entscheidung, aber gibt es einen klaren nächsten Schritt, nenne ihn in einem Satz.
Gib ausschließlich den Vorlesetext aus.'

PROMPT_EN='You receive the latest reply from an AI coding assistant to a developer. Turn it into a text to be read aloud in English.
Rules:
- {{LENGTH}}, spoken language, no Markdown, no bullet points.
- Do not read out file paths, URLs, code, commands or IDs; at most refer to them in plain words ("the config file").
- First, in one or two sentences: what was done, or the result.
- Only if the reply needs a decision, approval or answer from the developer: say "You need to decide:", explain the background in one sentence, then say "My recommendation:" followed by the recommended next step.
- If no decision is needed but there is a clear next step, name it in one sentence.
Output only the text to be read aloud.'

default_prompt() {
  if [ "${1:-$LANG_CODE}" = en ]; then printf '%s' "$PROMPT_EN"; else printf '%s' "$PROMPT_DE"; fi
}

# Satz für die gewählte Länge, in der Sprache der Ansage
length_rule() {
  case "$LANG_CODE:$SUMMARY_LENGTH" in
    en:kurz)         echo "At most 2 short sentences" ;;
    en:ausfuehrlich) echo "At most 7 sentences, with a bit more context" ;;
    en:*)            echo "At most 4 short sentences" ;;
    *:kurz)          echo "Höchstens 2 kurze Sätze" ;;
    *:ausfuehrlich)  echo "Höchstens 7 Sätze, gern mit etwas mehr Kontext" ;;
    *)               echo "Höchstens 4 kurze Sätze" ;;
  esac
}

build_prompt() {
  local p len
  p=$(default_prompt)
  [ -s "$DIR/prompt.txt" ] && p=$(cat "$DIR/prompt.txt")
  len=$(length_rule)
  p="${p//\{\{LAENGE\}\}/$len}"
  printf '%s' "${p//\{\{LENGTH\}\}/$len}"
}

extract_last_reply() {
  local input="$1" msg tp
  msg=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null)
  if [ -z "$msg" ]; then
    tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
    [ -f "$tp" ] || return
    # Alle Text-Blöcke des Assistenten seit dem letzten echten User-Prompt
    msg=$(tail -n 600 "$tp" | jq -rs '
      . as $all
      | ([range(0; length)]
          | map(select($all[.].type == "user"
              and (($all[.].message.content | type) == "string"
                   or any($all[.].message.content[]?; .type == "text"))))
          | last) as $i
      | $all[(($i // -1) + 1):]
      | map(select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text)
      | join("\n\n")' 2>/dev/null)
  fi
  printf '%s' "$msg" | head -c 15000
}

summarize() {
  printf '%s' "$1" | SPEAK_SUMMARY_CHILD=1 "$CLAUDE_BIN" -p --model "$SUMMARY_MODEL" "$(build_prompt)" 2>>"$LOG"
}

play() { "$@" & echo $! > "$PIDFILE"; wait $!; rm -f "$PIDFILE"; }

# Gespeicherte Stimm-Einstellungen holen und nur das Tempo überschreiben
# (ein Teil-Objekt würde Stabilität usw. auf API-Standardwerte zurücksetzen).
voice_settings() {
  local key="$1" speed="$ELEVENLABS_SPEED" vs
  case "$speed" in ''|*[!0-9.]*|1|1.0|1.00) echo 'null'; return ;; esac
  vs=$(curl -sf --max-time 3 "https://api.elevenlabs.io/v1/voices/$ELEVENLABS_VOICE_ID/settings" \
        -H @<(printf 'xi-api-key: %s' "$key") 2>/dev/null)
  [ -n "$vs" ] || vs='{}'
  printf '%s' "$vs" | jq -c --argjson s "$speed" '(if type == "object" then . else {} end) + {speed: $s}' 2>/dev/null \
    || jq -nc --argjson s "$speed" '{speed: $s}'
}

speak_elevenlabs() {
  local text="$1" key out body vs
  [ -n "$ELEVENLABS_VOICE_ID" ] || return 1
  key=$(el_key) || return 1
  out="$DIR/last.mp3"
  vs=$(voice_settings "$key")
  body=$(jq -n --arg t "$text" --arg m "$ELEVENLABS_MODEL" --argjson vs "${vs:-null}" \
    '{text: $t, model_id: $m} + (if $vs then {voice_settings: $vs} else {} end)')
  curl -sf -X POST "https://api.elevenlabs.io/v1/text-to-speech/$ELEVENLABS_VOICE_ID?output_format=mp3_44100_128" \
    -H @<(printf 'xi-api-key: %s' "$key") -H "Content-Type: application/json" \
    -d "$body" -o "$out" 2>>"$LOG" || { echo "ElevenLabs-Fehler, nutze Systemstimme" >>"$LOG"; return 1; }
  play afplay "$out"
}

speak_say() { play say -v "$SAY_VOICE" -r "$SAY_RATE" "$1"; }

speak() {
  case "$TTS_ENGINE" in
    say) speak_say "$1" ;;
    *)   speak_elevenlabs "$1" || speak_say "$1" ;;
  esac
}

# Antworttext zusammenfassen und vorlesen
speak_reply() {
  local reply="$1" text
  touch "$SUMFILE"
  text=$(summarize "$reply")
  rm -f "$SUMFILE"
  if [ -z "$text" ]; then
    if [ "$LANG_CODE" = en ]; then text="Claude is done."; else text="Claude ist fertig."; fi
  fi
  printf '%s\n' "$text" >"$DIR/last.txt"
  stop_playback   # eine neue Antwort unterbricht die alte Ansage
  speak "$text"
}

run() {
  local reply
  reply=$(extract_last_reply "$1")
  [ -n "$reply" ] || exit 0
  speak_reply "$reply"
}

# ---------- Session-Steuerung ----------

# Projekt = Git-Repository samt Worktrees (ohne git-Aufruf), sonst der Ordner selbst
project_root() {
  local d="$1" gd cd
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    if [ -d "$d/.git" ]; then echo "$d"; return; fi
    if [ -f "$d/.git" ]; then
      gd=$(sed -n 's/^gitdir: //p' "$d/.git" | head -1)
      case "$gd" in /*) ;; *) gd="$d/$gd" ;; esac
      if [ -f "$gd/commondir" ]; then
        cd=$(head -1 "$gd/commondir")
        case "$cd" in /*) ;; *) cd="$gd/$cd" ;; esac
        cd=$( (cd "$cd/.." 2>/dev/null && pwd) )
        [ -n "$cd" ] && { echo "$cd"; return; }
      fi
      echo "$d"; return
    fi
    d=$(dirname "$d")
  done
  echo "$1"
}

env_rule() {
  case "$(printf '%s' "${AGENT_SPEAK:-}" | tr 'A-Z' 'a-z')" in
    on|1|true|yes)  echo on ;;
    off|0|false|no) echo off ;;
  esac
}

# Rangfolge: AGENT_SPEAK -> Session-Ausnahme -> Projekt-Regel (längster Pfad) -> Standard
decide() {
  local sid="$1" cwd="$2" root="$3" locked="$4" r=""
  [ -n "$locked" ] && { echo "$locked"; return; }
  if [ -s "$DIR/rules.json" ]; then
    r=$(jq -r --arg s "$sid" --arg c "$cwd" --arg p "$root" '
      (.sessions[$s] // null) as $sr
      | ([(.projects // {}) | to_entries[]
          | select(.key == $p or .key == $c or ($c | startswith(.key + "/")))]
         | sort_by(.key | length) | last | .value?) as $pr
      | ($sr // $pr // empty)' "$DIR/rules.json" 2>/dev/null)
  fi
  case "$r" in
    on|off) echo "$r" ;;
    *) if [ "$NEW_SESSIONS" = off ]; then echo off; else echo on; fi ;;
  esac
}

# Erster echter Prompt aus dem Verlauf (nach bestem Bemühen, das Format ist intern)
first_prompt() {
  [ -f "$1" ] || return
  head -n 300 "$1" | jq -rs '
    map(select(.type == "user") | .message.content
        | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | first // "") end
        | select(type == "string" and length > 0 and (startswith("<") | not)))
    | first // empty | gsub("\\s+"; " ") | .[0:80]' 2>/dev/null
}

snippet() { printf '%s' "$1" | jq -Rrs 'gsub("[*_#`>]"; "") | gsub("\\s+"; " ") | ltrimstr(" ") | .[0:80]'; }

write_session() {
  local sid="$1" cwd="$2" root="$3" tp="$4" reply="$5" pending="$6" locked="$7" f label src
  f="$SESS/$sid.json"
  label=$(jq -r 'select(.labelSource == "prompt") | .label // empty' "$f" 2>/dev/null)
  src=prompt
  [ -n "$label" ] || label=$(first_prompt "$tp")
  if [ -z "$label" ]; then label=$(snippet "$reply"); src=reply; fi
  jq -n --arg id "$sid" --arg cwd "$cwd" --arg root "$root" --arg project "$(basename "$root")" \
        --arg label "$label" --arg src "$src" --argjson seen "$(date +%s)" \
        --argjson pending "$pending" --arg locked "$locked" \
    '{id: $id, cwd: $cwd, root: $root, project: $project, label: $label, labelSource: $src,
      lastSeen: $seen, pending: $pending, locked: $locked}' >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

hook_main() {
  local input="$1" sid cwd tp reply root locked rule pending=false
  reply=$(extract_last_reply "$input")
  [ -n "$reply" ] || return
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  case "$sid" in *[!A-Za-z0-9_-]*) sid="" ;; esac
  if [ -z "$sid" ]; then                       # ohne Session-ID wie früher
    [ -f "$DIR/muted" ] || speak_reply "$reply"
    return
  fi
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
  root=$(project_root "${cwd:-$HOME}")
  locked=$(env_rule)
  rule=$(decide "$sid" "$cwd" "$root" "$locked")

  mkdir -p "$SESS"
  find "$SESS" -type f -mtime +7 -delete 2>/dev/null   # verfallene Sessions aufräumen
  if [ -f "$DIR/muted" ] || [ "$rule" = off ]; then
    printf '%s' "$reply" >"$SESS/$sid.reply"            # nur merken, nicht zusammenfassen
    pending=true
    touch "$DIR/unheard"
  else
    rm -f "$SESS/$sid.reply"
  fi
  write_session "$sid" "$cwd" "$root" "$tp" "$reply" "$pending" "$locked"
  [ "$pending" = false ] && speak_reply "$reply"
}

mkdir -p "$DIR"

case "${1:-}" in
  --version) echo "$HOOK_VERSION"; exit 0 ;;
  --project-root) project_root "${2:-$PWD}"; exit 0 ;;
  --speak-session)
    sid="${2:-}"
    case "$sid" in ''|*[!A-Za-z0-9_-]*) exit 1 ;; esac
    [ -s "$SESS/$sid.reply" ] || exit 0
    reply=$(cat "$SESS/$sid.reply")
    rm -f "$SESS/$sid.reply"
    if [ -f "$SESS/$sid.json" ]; then
      jq '.pending = false' "$SESS/$sid.json" >"$SESS/$sid.json.tmp.$$" && mv "$SESS/$sid.json.tmp.$$" "$SESS/$sid.json"
    fi
    speak_reply "$reply"
    exit 0 ;;
  --default-prompt) default_prompt "$(resolve_lang "${2:-$SPEAK_LANGUAGE}")"; echo; exit 0 ;;
  --mute)    touch "$DIR/muted"; stop_playback; echo "Vorlesen aus."; exit 0 ;;
  --unmute)  rm -f "$DIR/muted"; echo "Vorlesen an."; exit 0 ;;
  --stop)    stop_playback; exit 0 ;;
  --replay)
    [ -s "$DIR/last.txt" ] || exit 0
    stop_playback
    speak "$(cat "$DIR/last.txt")"
    exit 0 ;;
  --voices)
    key=$(el_key) || { echo "Kein Key im Schlüsselbund (Dienst: elevenlabs-api-key)."; exit 1; }
    curl -sf https://api.elevenlabs.io/v1/voices -H @<(printf 'xi-api-key: %s' "$key") \
      | jq -r '.voices[] | "\(.voice_id)  \(.name)  [\(.labels.language // .labels.accent // "-")]"'
    exit 0 ;;
  --test)
    if [ "$LANG_CODE" = en ]; then
      sample="I fixed the login bug and the tests are green. Should I open a pull request, or refactor the error handling first?"
    else
      sample="Ich habe den Login-Bug behoben, die Tests laufen grün. Soll ich einen Pull Request erstellen oder erst noch die Fehlerbehandlung refactoren?"
    fi
    run "$(jq -n --arg m "${2:-$sample}" '{last_assistant_message: $m}')"
    exit 0 ;;
esac

# Hook-Modus: stdin lesen, Rest im Hintergrund, damit Claude Code nicht blockiert.
# Die Ruhe-Taste (muted) prüft hook_main: stumme Antworten werden als ungehört vermerkt.
input=$(cat)
( hook_main "$input" ) </dev/null >/dev/null 2>>"$LOG" &
disown
exit 0
