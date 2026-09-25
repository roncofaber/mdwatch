#!/usr/bin/env bash
# mdwatch hook: append every event as one line to the state directory's hooks.log
event=$(tr -d '\n' | tr -s ' ') || exit 0
echo "$(date -u +%FT%T) $event" >> "${MDWATCH_STATE_DIR:-$HOME/.local/state/mdwatch}/hooks.log"
