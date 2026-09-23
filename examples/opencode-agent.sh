#!/usr/bin/env bash
# mdwatch hook: fire a headless opencode agent turn on job failures.
#
# The agent investigates the failure autonomously (no human message needed).
# Runs detached so the 30 s hook timeout does not apply; logs to
# ~/.local/state/mdwatch/agent_logs/.
#
# Guards:
# - reacts to FAILED/TIMEOUT/OUT_OF_MEMORY/NODE_FAIL only (extend the case to
#   also react to FINISHED/CANCELLED)
# - once per jobid (agent_handled marker prevents reaction loops)
# - the prompt tells the agent to diagnose and NOT to resubmit blindly; paid
#   partitions are never touched (cluster skill autonomy rules)

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
prompt+="paid partitions. Some tool calls may be auto-rejected by permissions in "
prompt+="headless mode: never retry a rejected call more than once, and ALWAYS end "
prompt+="by printing a 'DIAGNOSIS:' line with whatever you found, even if partial."

setsid nohup timeout 900 bash -lc "$opencode_bin run \"$(printf '%s' "$prompt" | sed 's/"/\\"/g')\"" \
    > "$logfile" 2>&1 < /dev/null &
echo "$! > $logfile"
