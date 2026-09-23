# mdwatch

SLURM job event watcher with a local hook system. Polls the queue for a user's
jobs, diffs against the last known state, and on every state transition writes
an event JSON file and runs the hook scripts in `hooks.d/` with the event on
stdin. Optional ntfy.sh push built in. Cron-driven: set up once, then chill.

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
(config + hooks), writes a commented default config if missing, and adds a
5-minute cron entry marked `# MDWATCH`. `mdwatch remove` takes the cron entry
out again (state and events are kept).

## Commands

| Command | Purpose |
|---|---|
| `mdwatch watch` | one poll pass (cron runs this every 5 min) |
| `mdwatch events [N]` | show the last N events |
| `mdwatch status` | configuration and watcher state |
| `mdwatch install` / `mdwatch remove` | manage the cron entry |
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
  "elapsed": "08:12:44"
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

## Configuration

`~/.config/mdwatch/config.env`:

```bash
MDWATCH_USER=roncoroni
MDWATCH_CLUSTERS=              # e.g. "etna" for squeue -M; empty = local cluster
MDWATCH_NTFY_TOPIC=            # enables the built-in ntfy push
MDWATCH_NTFY_URL=https://ntfy.sh
```

## Use with agents

The `lbl-hpc-cluster` skill references this tool: agents call `mdwatch events`
instead of sleep-polling `squeue`, and can drop a hook into `hooks.d/` to
trigger reactions autonomously. Event JSON is the interface - one schema for
simulations finishing, failing, timing out, or anything else SLURM reports.
