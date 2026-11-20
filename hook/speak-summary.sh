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
#   speak-summary.sh --mute|--unmute|--stop|--version
#
# Konfiguration: ~/.claude/hooks/speak-summary/config (wird von der Agent-Speak-App gepflegt)
# Eigener Prompt: ~/.claude/hooks/speak-summary/prompt.txt (optional; {{LAENGE}}/{{LENGTH}} wird ersetzt)
# ElevenLabs-Key im Schlüsselbund, Dienst "elevenlabs-api-key".
#
# Statusdateien (liest die App, um das Overlay zu animieren):
#   muted        -> Vorlesen ist aus
#   summarizing  -> Zusammenfassung läuft gerade
#   player.pid   -> Ansage läuft gerade (PID von afplay/say)
#   last.txt     -> zuletzt gesprochener Text

HOOK_VERSION=4

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

run() {
  local reply text
  reply=$(extract_last_reply "$1")
  [ -n "$reply" ] || exit 0
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

mkdir -p "$DIR"

case "${1:-}" in
  --version) echo "$HOOK_VERSION"; exit 0 ;;
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

[ -f "$DIR/muted" ] && exit 0

# Hook-Modus: stdin lesen, Rest im Hintergrund, damit Claude Code nicht blockiert.
input=$(cat)
( run "$input" ) </dev/null >/dev/null 2>>"$LOG" &
disown
exit 0
