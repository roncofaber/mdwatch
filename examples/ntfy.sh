#!/usr/bin/env bash
# example hook: push mdwatch events to an ntfy.sh topic
#
# The built-in push (MDWATCH_NTFY_TOPIC) covers most needs; use this hook for
# custom formatting. Copy it into ~/.config/mdwatch/hooks.d/ and set the topic.
# mdwatch-states: FAILED TIMEOUT OUT_OF_MEMORY NODE_FAIL STALLED FINISHED

event=$(cat) || true
topic="${MDWATCH_NTFY_TOPIC:?set MDWATCH_NTFY_TOPIC to an unguessable topic}"

state=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<< "$event" 2>/dev/null) || exit 0
jobid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["jobid"])' <<< "$event" 2>/dev/null)
name=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' <<< "$event" 2>/dev/null)

case "$state" in
    FAILED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|CANCELLED) priority="high" ;;
    STARTED) priority="min" ;;
    *) priority="default" ;;
esac

curl -s -m 10 \
    -H "Title: mdwatch: $state" \
    -H "Priority: $priority" \
    -H "Tags: $([ "$state" = FINISHED ] && echo white_check_mark || echo warning)" \
    -d "job $jobid ($name): $state" \
    "${MDWATCH_NTFY_URL:-https://ntfy.sh}/$topic" >/dev/null
