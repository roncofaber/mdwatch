#!/usr/bin/env bash
# mdwatch hook: fire a headless opencode agent turn on job failures.
# mdwatch-states: FAILED TIMEOUT OUT_OF_MEMORY NODE_FAIL BOOT_FAIL STALLED
#
# The agent investigates the failure autonomously (no human message needed).
# Runs detached so the 30 s hook timeout does not apply; logs to
# ~/.local/state/mdwatch/agent_logs/. The event JSON heads the log, and a
# fallback DIAGNOSIS line is appended if the turn ends without printing one.
# The DIAGNOSIS line is pushed to ntfy when MDWATCH_NTFY_TOPIC is set.
#
# Guards:
# - mdwatch only delivers the states on the mdwatch-states line above; edit it
#   to react to more (e.g. FINISHED for completion summaries)
# - skipped for jobs submitted with --comment=mdwatch:agent=off
# - one agent at a time (flock): parallel opencode runs share one SQLite
#   database, which fails on NFS home directories. Failures that arrive while
#   an agent is running are handed to it as related events, and a failure
#   already covered by a recent diagnosis of a sibling job is skipped.
# - once per jobid (agent_handled marker prevents reaction loops)
# - runs a dedicated read-only "mdwatch" agent: reads anywhere, runs only
#   inspection commands, cannot edit files, submit, cancel or fetch the web
#
# Config (config.env):
#   MDWATCH_AGENT_MODEL   opencode provider/model; default: opencode's configured model
#   MDWATCH_AGENT_ENV     file sourced for API keys (default ~/.secrets.env);
#                         systemd timers and cron do not load shell profiles

# shellcheck disable=SC1090
source "${MDWATCH_CONFIG:-$HOME/.config/mdwatch/config.env}" 2>/dev/null || true
event=$(cat) || true

field() {
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$event" "$1" 2>/dev/null
}

state=$(field state) || exit 0
[[ " $(field tags) " == *" agent=off "* ]] && exit 0
jobid=$(field jobid)
name=$(field name)
workdir=$(field workdir)
stdout=$(field stdout)
stderr=$(field stderr)

state_dir="${MDWATCH_STATE_DIR:-$HOME/.local/state/mdwatch}"
marker_dir="$state_dir/agent_handled"
log_dir="$state_dir/agent_logs"
mkdir -p "$marker_dir" "$log_dir"
[[ -f "$marker_dir/$jobid" ]] && exit 0
touch "$marker_dir/$jobid"

opencode_bin="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"
[[ -x "$opencode_bin" ]] || opencode_bin="$(command -v opencode || true)"
[[ -n "$opencode_bin" ]] || exit 0

# shellcheck disable=SC1090
source "${MDWATCH_AGENT_ENV:-$HOME/.secrets.env}" 2>/dev/null || true
export MDWATCH_NTFY_TOPIC MDWATCH_NTFY_URL
PATH="$HOME/.local/bin:$(dirname "$(readlink -f "$0")"):$PATH"
export PATH
model_args=()
[[ -n "${MDWATCH_AGENT_MODEL:-}" ]] && model_args=(-m "$MDWATCH_AGENT_MODEL")
[[ -d "$workdir" ]] || workdir="${MDWATCH_AGENT_WORKDIR:-$HOME}"
logfile="$log_dir/$(date -u +%FT%H%M)Z_${jobid}_$state.log"

export OPENCODE_CONFIG_CONTENT='{
  "agent": {
    "mdwatch": {
      "description": "Read-only SLURM failure diagnosis",
      "mode": "primary",
      "steps": 40,
      "permission": {
        "read": "allow",
        "glob": "allow",
        "grep": "allow",
        "external_directory": "allow",
        "edit": "deny",
        "webfetch": "deny",
        "websearch": "deny",
        "task": "deny",
        "question": "deny",
        "bash": {
          "*": "deny",
          "cat *": "allow", "head *": "allow", "tail *": "allow",
          "ls": "allow", "ls *": "allow", "find *": "allow", "stat *": "allow",
          "grep *": "allow", "rg *": "allow", "wc *": "allow", "du *": "allow",
          "diff *": "allow", "file *": "allow", "readlink *": "allow",
          "sacct *": "allow", "squeue *": "allow", "sinfo *": "allow",
          "scontrol show *": "allow",
          "mdwatch show *": "allow", "mdwatch events*": "allow",
          "module avail*": "allow", "module show *": "allow"
        }
      }
    }
  }
}'

related=$(find "$state_dir/events" -maxdepth 1 -name '*.json' -mmin -10 2>/dev/null \
    | grep -E '_(FAILED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|STALLED)\.json$' \
    | grep -v "_${jobid}_" | sed -E 's|.*/[0-9T-]+Z_([0-9]+(_[0-9]+)?)_([A-Z_]+)\.json$|\1 \3|' | sort -u | head -n 20 | tr '\n' ',' | sed 's/,$//')

prompt="mdwatch event: SLURM job $jobid ('$name') reported state $state. "
prompt+="Working directory: $workdir. Stdout: ${stdout:-unknown}. Stderr: ${stderr:-unknown}. "
prompt+="Event JSON: $(tr -d '\n' <<< "$event"). "
[[ -n "$related" ]] && prompt+="Other jobs that failed in the last 10 minutes: $related. If they share this cause, say so and name them in the diagnosis instead of treating this job in isolation. "
prompt+="Read the job output and the relevant inputs/logs in the working directory "
prompt+="(mdwatch show $jobid prints the event and output tails), and diagnose the likely "
prompt+="cause (input error, missing file, timeout, memory, node failure). You are read-only: "
prompt+="do not try to edit, resubmit or cancel anything. Do NOT inspect mdwatch's own state "
prompt+="or hooks directories. If a tool call is rejected, move on immediately. ALWAYS end with "
prompt+="one line starting 'DIAGNOSIS:' that states the cause and the suggested fix in one sentence."

printf '%s\n' "$event" > "$logfile"
setsid nohup bash -c '
    opencode="$1" prompt="$2" log="$3" jobid="$5" lock="$6"
    cd "$4" || exit 1
    shift 6
    exec 8>"$lock"
    flock -w 3600 8 || { echo "DIAGNOSIS: skipped; another mdwatch agent held the lock for an hour." >> "$log"; exit 0; }
    covered=$(grep -l -a "DIAGNOSIS:.*$jobid" "$(dirname "$log")"/*.log 2>/dev/null | grep -v "$log" | head -n 1)
    if [[ -n "$covered" ]]; then
        echo "DIAGNOSIS: covered by $(basename "$covered"): $(grep -a "DIAGNOSIS:" "$covered" | tail -n 1 | sed "s/^.*DIAGNOSIS: *//")" >> "$log"
        exit 0
    fi
    timeout 900 "$opencode" run --agent mdwatch "$@" "$prompt"
    grep -aq "DIAGNOSIS:" "$log" || printf "DIAGNOSIS: no explicit diagnosis; the turn ended early (see log above).\n" >> "$log"
    if [[ -n "${MDWATCH_NTFY_TOPIC:-}" ]]; then
        diag=$(grep -a "DIAGNOSIS:" "$log" | tail -n 1 | sed "s/\x1b\[[0-9;]*m//g")
        curl -s -m 10 -H "Title: mdwatch agent: job $jobid" -H "Tags: mag" -d "$diag" \
            "${MDWATCH_NTFY_URL:-https://ntfy.sh}/$MDWATCH_NTFY_TOPIC" >/dev/null || true
    fi
' _ "$opencode_bin" "$prompt" "$logfile" "$workdir" "$jobid" "$state_dir/agent.lock" ${model_args[@]+"${model_args[@]}"} >> "$logfile" 2>&1 < /dev/null 9>&- &
