# mdwatch

Job event watcher for SLURM. It polls your jobs once a minute, writes one JSON file per state change, runs your hook scripts on each event, and can push notifications to your phone through [ntfy](https://ntfy.sh). It works for any kind of job, needs no root access and no daemon, and depends only on bash, the SLURM client tools, python3 and coreutils.

Agents and scripts can ask "what happened?" (`mdwatch events`) or block until a job ends (`mdwatch wait`) instead of polling `squeue` in a loop.

## Install

```bash
git clone https://github.com/roncofaber/mdwatch.git
mdwatch/bin/mdwatch install
mdwatch status
```

`install` creates the config and state directories, links `~/.local/bin/mdwatch`, and schedules `mdwatch watch` every minute: a cron entry, or a systemd user timer where crontab is not allowed. For the timer to keep running after you log out, the cluster must allow `loginctl enable-linger $USER`. `mdwatch remove` unschedules it and keeps your events.

## Commands

| Command | Purpose |
|---|---|
| `mdwatch events [N]` | last N events, one line each |
| `mdwatch show JOBID [LINES]` | the job's latest event, workdir, and the tail of its stdout/stderr |
| `mdwatch wait JOBID... [--timeout S]` | block until the jobs end; exit 0 if all finished, 1 otherwise, 124 on timeout |
| `mdwatch status` | configuration and scheduler state |
| `mdwatch watch` | one poll pass (the scheduler runs this) |
| `mdwatch install` / `remove` | schedule or unschedule the watcher |

## Events

| Event | When |
|---|---|
| `SUBMITTED` | job first seen pending |
| `STARTED` | job begins running |
| `REQUEUED` | running job went back to pending |
| `NEAR_TIMEOUT` | elapsed time passed `MDWATCH_WALLTIME_WARN` percent of the limit (default 90) |
| `STALLED` | running job produced no output for the stall window (opt-in, see below) |
| `FINISHED`, `FAILED`, `TIMEOUT`, `CANCELLED`, `OUT_OF_MEMORY`, `NODE_FAIL`, `PREEMPTED`, `BOOT_FAIL`, `DEADLINE` | terminal state from accounting |

Array tasks are tracked individually (`1234_7`). Jobs that start and end between two polls are still caught from accounting. Events live in `~/.local/state/mdwatch/events/`; a terminal event looks like:

```json
{
  "timestamp": "2026-09-23T12:36:37Z",
  "cluster": "local",
  "user": "alice",
  "jobid": "1234567",
  "name": "relax_run",
  "state": "FINISHED",
  "exitcode": "0:0",
  "node": "node042",
  "elapsed": "08:12:44",
  "timelimit": "12:00:00",
  "time_used": "68%",
  "cpus": "24",
  "cpu_efficiency": "91%",
  "max_rss": "2.2G",
  "req_mem": "60G",
  "workdir": "/scratch/alice/relax",
  "stdout": "/scratch/alice/relax/slurm-1234567.out",
  "stderr": "/scratch/alice/relax/slurm-1234567.out"
}
```

Empty fields are omitted. `time_used`, `cpu_efficiency` and `max_rss` help you size future `--time` and `--mem` requests.

## Per-job options

Put options in the job comment; mdwatch reads the `mdwatch:` token and ignores the rest:

```bash
sbatch --comment=mdwatch:stall=30,notify=high job.sh
```

| Option | Effect |
|---|---|
| `off` | ignore this job entirely |
| `stall=MIN` | emit `STALLED` if no file under the workdir or the job's stdout/stderr changed for MIN minutes |
| `watch=PATH` | also count changes under PATH as activity |
| `notify=off` / `notify=high` | suppress, or always send at high priority |
| any `key=value` | passed to hooks in the event's `tags` field (e.g. `agent=off`) |

Set `MDWATCH_STALL_MINUTES` to apply a stall window to every job.

## Hooks

Every executable in `~/.config/mdwatch/hooks.d/` runs on each event with the event JSON on stdin and its path in `MDWATCH_EVENT_FILE`. Hooks run detached with a timeout (`MDWATCH_HOOK_TIMEOUT`, default 30 s), so a slow hook never delays the poll. To receive only some states, add a line near the top of the hook:

```bash
# mdwatch-states: FAILED TIMEOUT OUT_OF_MEMORY
```

Examples in `examples/`:

- `log-to-file.sh`: one line per event in `hooks.log` (installed by default).
- `ntfy.sh`: standalone ntfy push, if you want different formatting from the built-in one.
- `opencode-agent.sh`: starts a headless [opencode](https://opencode.ai) agent that diagnoses failed or stalled jobs. It runs read-only in the job's workdir (it can read files and run `sacct`, `squeue` and `mdwatch show`, but cannot edit, submit or cancel), writes its log to `~/.local/state/mdwatch/agent_logs/`, and pushes its final `DIAGNOSIS:` line to ntfy. Agents run one at a time (opencode keeps its sessions in one SQLite database, which breaks under concurrent writers on NFS homes); each agent is told about other jobs that failed in the last 10 minutes, and a job already named in a sibling's diagnosis is skipped, so a batch of chains failing for one reason produces one diagnosis. Timers and cron do not load your shell profile, so it sources `MDWATCH_AGENT_ENV` (default `~/.secrets.env`) for API keys; set the model with `MDWATCH_AGENT_MODEL`.

## Configuration

`~/.config/mdwatch/config.env`; every setting is optional:

```bash
MDWATCH_CLUSTERS=           # squeue/sacct -M value; empty = local cluster
MDWATCH_NTFY_TOPIC=         # enables pushes; choose an unguessable topic name
MDWATCH_NTFY_URL=https://ntfy.sh
MDWATCH_NTFY_STATES="STARTED REQUEUED NEAR_TIMEOUT STALLED FINISHED FAILED TIMEOUT ..."
MDWATCH_WALLTIME_WARN=90    # percent of the time limit for NEAR_TIMEOUT
MDWATCH_STALL_MINUTES=0     # default stall window; 0 = only jobs tagged stall=N
MDWATCH_KEEP_HOURS=48       # forget finished jobs after this long
MDWATCH_EVENT_DAYS=60       # delete older event files
```

Notifications from one poll are batched into a single push.

## Site notes: LBL Lawrencium (LRC)

These notes apply only to the Lawrencium cluster at Berkeley Lab; the tool itself is site-independent.

- `crontab` and `scrontab` are disabled for regular users, so `install` falls back to the systemd user timer. Linger is enabled for users, so the timer survives logout.
- `/usr/bin/python3` is Python 3.6, which is enough for mdwatch.
- For the agent hook, LBL's CBorg gateway serves free models; configure a CBorg provider in opencode and set `MDWATCH_AGENT_MODEL` to it (for example `cborg/lbl/cborg-coder-max`).

## Development

```bash
tests/run.sh    # scenario tests against fake squeue/sacct/scontrol
```
