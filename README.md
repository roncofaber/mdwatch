# mdwatch

SLURM job event watcher with a local hook system. Polls the queue for a user's
jobs, diffs against the last known state, and on every state transition writes
an event JSON file and runs the hook scripts in `hooks.d/` with the event on
stdin. Optional ntfy.sh push built in. Runs every minute from cron, or from a
systemd user timer where crontab is not permitted: set up once, then chill.

No sleep-polling loops in agent sessions or terminal tabs: `mdwatch events`
answers "what happened" in one instant call, and hooks fire within the cron
interval without anyone watching.

## Install

```bash
git clone git@github.com:roncofaber/mdwatch.git
cd mdwatch
bin/mdwatch install
bin/mdwatch status
```

`install` creates `~/.local/state/mdwatch/` (state + events), `~/.config/mdwatch/`
(config + hooks), writes a commented default config if missing, links
`~/.local/bin/mdwatch`, and adds a 1-minute cron entry marked `# MDWATCH`. When
crontab is not permitted it installs a systemd user timer instead (enable
linger with `loginctl enable-linger` so it survives logout). `mdwatch remove`
takes the scheduler out again (state and events are kept).

## Commands

| Command | Purpose |
|---|---|
| `mdwatch watch` | one poll pass (cron runs this every 1 min) |
| `mdwatch events [N]` | show the last N events |
| `mdwatch show JOBID [LINES]` | event JSON, workdir and tails of the job's stdout/stderr |
| `mdwatch status` | configuration and watcher state |
| `mdwatch install` / `mdwatch remove` | manage the cron entry or systemd timer |
| `mdwatch version` | version |

## Events

Every transition produces a JSON file in `~/.local/state/mdwatch/events/`:

```json
{
  "timestamp": "2026-09-23T12:36:37Z",
  "cluster": "etna",
  "jobid": "26292466",
  "name": "nacl_chain_1pair",
  "state": "FINISHED",
  "exitcode": "0:0",
  "node": "n0046.etna0",
  "elapsed": "08:12:44",
  "workdir": "/global/scratch/users/roncoroni/run",
  "stdout": "/global/scratch/users/roncoroni/run/slurm-nacl_chain_1pair-26292466.out",
  "stderr": ""
}
```

States: `STARTED`, `FINISHED`, `FAILED`, `TIMEOUT`, `CANCELLED`,
`OUT_OF_MEMORY`, `NODE_FAIL`, `PREEMPTED`, `BOOT_FAIL`, `DEADLINE`.

## Hooks

Every executable in `~/.config/mdwatch/hooks.d/` runs on every event, with the
event JSON on stdin and a 30 s timeout. Example: push failures to your phone
via ntfy:

```bash
cp examples/ntfy.sh ~/.config/mdwatch/hooks.d/10-ntfy.sh
chmod +x ~/.config/mdwatch/hooks.d/10-ntfy.sh
```

Hooks are the webhook equivalent on a cluster login node: anything that can
read stdin can react - a notification, a slack/teams relay, or a headless
`opencode run "<event context>"` agent turn.

### Headless agent diagnosis

`examples/opencode-agent.sh` starts a detached `opencode run` on FAILED,
TIMEOUT, OUT_OF_MEMORY and NODE_FAIL events, once per job. It runs in the
job's workdir as a read-only agent (reads anywhere, only inspection commands
such as `cat`, `tail`, `sacct`, `mdwatch show`; no edits, submits or cancels),
logs to `~/.local/state/mdwatch/agent_logs/`, and pushes its final
`DIAGNOSIS:` line to ntfy when a topic is set.

```bash
cp examples/opencode-agent.sh ~/.config/mdwatch/hooks.d/20-opencode-agent.sh
chmod +x ~/.config/mdwatch/hooks.d/20-opencode-agent.sh
```

Timers and cron do not load your shell profile, so the hook sources
`MDWATCH_AGENT_ENV` (default `~/.secrets.env`) for the provider API key.
Select the model with `MDWATCH_AGENT_MODEL` (default
`cborg/lbl/cborg-coder-max`, which must exist in your opencode config) and the
states with `MDWATCH_AGENT_STATES`.

## Configuration

`~/.config/mdwatch/config.env`:

```bash
MDWATCH_USER=roncoroni
MDWATCH_CLUSTERS=              # e.g. "etna" for squeue -M; empty = local cluster
MDWATCH_NTFY_TOPIC=            # enables the built-in ntfy push
MDWATCH_NTFY_URL=https://ntfy.sh
MDWATCH_AGENT_MODEL=           # opencode provider/model for the agent hook
MDWATCH_AGENT_ENV=             # file with API keys, default ~/.secrets.env
MDWATCH_AGENT_STATES=          # default "FAILED TIMEOUT OUT_OF_MEMORY NODE_FAIL"
```

## Use with agents

The `lbl-hpc-cluster` skill references this tool: agents call `mdwatch events`
instead of sleep-polling `squeue`, and can drop a hook into `hooks.d/` to
trigger reactions autonomously. Event JSON is the interface - one schema for
simulations finishing, failing, timing out, or anything else SLURM reports.
