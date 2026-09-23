#!/usr/bin/env bash
# mdwatch hook: fire a headless opencode agent turn on job failures.
#
# The agent investigates the failure autonomously (no human message needed).
# Runs detached so the 30 s hook timeout does not apply; logs to
# ~/.local/state/mdwatch/agent_logs/. The event JSON heads the log, and a
# fallback DIAGNOSIS line is appended if the turn ends without printing one.
#
# Guards:
# - reacts to FAILED/TIMEOUT/OUT_OF_MEMORY/NODE_FAIL only (extend the case to
#   also react to FINISHED/CANCELLED)
# - once per jobid (agent_handled marker prevents reaction loops)
# - --auto approves non-denied permissions so the headless turn is not killed
#   by auto-rejections; the prompt rules (no resubmit, no paid partitions)
#   keep it in bounds

source "${MDWATCH_CONFIG:-$HOME/.config/mdwatch/config.env}" 2>/dev/null || true
event=$(cat) || true

state=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<< "$event" 2>/dev/null) || exit 0
case "$state" in
    FAILED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL) ;;
    *) exit 0 ;;
esac
jobid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["jobid"])' <<< "$event" 2>/dev/null)
name=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' <<< "$event" 2>/dev/null)

marker_dir="${MDWATCH_STATE_DIR:-$HOME/.local/state/mdwatch}/agent_handled"
log_dir="${MDWATCH_STATE_DIR:-$HOME/.local/state/mdwatch}/agent_logs"
mkdir -p "$marker_dir" "$log_dir"
[[ -f "$marker_dir/$jobid" ]] && exit 0
touch "$marker_dir/$jobid"

opencode_bin="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"
[[ -x "$opencode_bin" ]] || opencode_bin="$(command -v opencode || true)"
[[ -n "$opencode_bin" ]] || exit 0

workdir="${MDWATCH_AGENT_WORKDIR:-$HOME}"
logfile="$log_dir/$(date -u +%FT%H%M)Z_${jobid}_$state.log"

prompt="mdwatch event: SLURM job $jobid ('$name') ended with state $state. "
prompt+="Investigate: find the job output/log if you can identify the project, "
prompt+="diagnose the likely cause (input error, timeout, memory, node failure), "
prompt+="and write a concise diagnosis. Do NOT resubmit anything and do NOT touch "
prompt+="paid partitions. Do NOT inspect mdwatch's own state or hooks directories "
prompt+="(that wastes the turn). If a tool call is rejected by permissions, move on "
prompt+="immediately. ALWAYS end by printing a 'DIAGNOSIS:' line with whatever you "
prompt+="found, even if partial."

printf '%s\n' "$event" > "$logfile"
setsid nohup bash -c '
    timeout 900 "$1" run --auto "$2"
    grep -aq "DIAGNOSIS:" "$3" || printf "DIAGNOSIS: no explicit diagnosis; the turn ended at a permission rejection or timeout, event JSON above.\n" >> "$3"
' _ "$opencode_bin" "$prompt" "$logfile" >> "$logfile" 2>&1 < /dev/null &
echo "$! > $logfile"
