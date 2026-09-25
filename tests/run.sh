#!/usr/bin/env bash
# Scenario tests for mdwatch against fake SLURM clients. Usage: tests/run.sh [path/to/mdwatch]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
MDWATCH="$(readlink -f "${1:-$here/../bin/mdwatch}")"
source "$here/fakebin.sh"

pass=0 fail=0
setup() {
    T=$(mktemp -d)
    export FAKE_DIR="$T/fake" MDWATCH_STATE_DIR="$T/state" MDWATCH_CONFIG="$T/config.env"
    export MDWATCH_HOOKS_DIR="$T/hooks" HOME="$T/home" MDWATCH_USER=tester
    mkdir -p "$FAKE_DIR/out" "$MDWATCH_HOOKS_DIR" "$HOME"
    make_fakebin "$T/bin"
    export PATH="$T/bin:$ORIG_PATH"
    : > "$FAKE_DIR/squeue.txt"; : > "$FAKE_DIR/sacct.txt"
}
watch() { "$MDWATCH" watch >/dev/null 2>&1; }
events() { ls "$MDWATCH_STATE_DIR/events" 2>/dev/null | sed 's/^[0-9TZ-]*_//; s/\.json$//' | sort | tr '\n' ' '; }
check() {
    if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"
    else fail=$((fail + 1)); echo "FAIL $1"; echo "     expected: $3"; echo "     got:      $2"; fi
}
ORIG_PATH="$PATH"

# pending job gives SUBMITTED only; STARTED when it runs; FINISHED with efficiency
setup
echo "101|PENDING|sim||0:00|1:00:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"
watch
check "pending emits SUBMITTED" "$(events)" "101_SUBMITTED "
echo "101|RUNNING|sim|n1|5:00|1:00:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"
watch
check "running emits STARTED once" "$(events)" "101_STARTED 101_SUBMITTED "
watch
check "no duplicate events" "$(events)" "101_STARTED 101_SUBMITTED "
: > "$FAKE_DIR/squeue.txt"
echo "101|COMPLETED|sim|00:30:00|n1|0:0|$T/w|$T/w/o|$T/w/e|01:00:00|01:00:00|4|4G|" > "$FAKE_DIR/sacct.txt"
echo "101.batch|2G" > "$FAKE_DIR/rss.txt"
watch
check "completion emits FINISHED" "$(events)" "101_FINISHED 101_STARTED 101_SUBMITTED "
f=$(ls "$MDWATCH_STATE_DIR"/events/*101_FINISHED.json)
check "cpu efficiency" "$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); print(e["cpu_efficiency"], e["time_used"], e["max_rss"])' "$f")" "50% 50% 2.0G"
watch
check "terminal event not repeated" "$(events)" "101_FINISHED 101_STARTED 101_SUBMITTED "

# array tasks get their own terminal events
setup
printf '%s\n' "200_1|RUNNING|arr|n1|1:00|10:00|$T/w|(null)" "200_2|RUNNING|arr|n2|1:00|10:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"
watch
: > "$FAKE_DIR/squeue.txt"
printf '%s\n' "200_1|COMPLETED|arr|00:02:00|n1|0:0|$T/w|||00:10:00|00:02:00|1|1G|" "200_2|FAILED|arr|00:02:00|n2|1:0|$T/w|||00:10:00|00:02:00|1|1G|" > "$FAKE_DIR/sacct.txt"
watch
check "array tasks finish individually" "$(events)" "200_1_FINISHED 200_1_STARTED 200_2_FAILED 200_2_STARTED "

# job that lived and died between polls
setup
watch
echo "300|OUT_OF_MEMORY|oom|00:00:05|n1|0:125|$T/w|||00:10:00|00:00:05|1|1G|" > "$FAKE_DIR/sacct.txt"
watch
check "short-lived job caught from accounting" "$(events)" "300_OUT_OF_MEMORY "

# walltime warning
setup
echo "400|RUNNING|long|n1|55:00|1:00:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"
watch; watch
check "NEAR_TIMEOUT once at 90%" "$(events)" "400_NEAR_TIMEOUT 400_STARTED "

# stall detection from the job comment; activity clears it
setup
mkdir -p "$T/w"; touch -d '-30 min' "$FAKE_DIR/out/500.out"
echo "500|RUNNING|hang|n1|40:00|5:00:00|$T/w|mdwatch:stall=10" > "$FAKE_DIR/squeue.txt"
watch; watch
check "STALLED once when output is idle" "$(events)" "500_STALLED 500_STARTED "
touch "$FAKE_DIR/out/500.out"; watch
check "activity clears the stall without an event" "$(events)" "500_STALLED 500_STARTED "

# mdwatch:off ignores the job entirely
setup
echo "600|RUNNING|quiet|n1|1:00|1:00:00|$T/w|mdwatch:off" > "$FAKE_DIR/squeue.txt"
watch
check "mdwatch:off is ignored" "$(events)" ""

# requeue
setup
echo "700|RUNNING|rq|n1|1:00|1:00:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"; watch
echo "700|PENDING|rq||0:00|1:00:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"; watch
check "running back to pending is REQUEUED" "$(events)" "700_REQUEUED 700_STARTED "

# hooks: state filter and detached execution
setup
cat > "$MDWATCH_HOOKS_DIR/10-fail.sh" <<'H'
#!/usr/bin/env bash
# mdwatch-states: FAILED
cat >> "$FAKE_DIR/hook.log"
H
cat > "$MDWATCH_HOOKS_DIR/20-slow.sh" <<'H'
#!/usr/bin/env bash
sleep 5
H
chmod +x "$MDWATCH_HOOKS_DIR"/*.sh
echo "800|PENDING|h||0:00|1:00:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"; watch
: > "$FAKE_DIR/squeue.txt"
echo "800|FAILED|h|00:00:01|n1|1:0|$T/w|||00:10:00|0:01|1|1G|" > "$FAKE_DIR/sacct.txt"
start=$SECONDS; watch; took=$((SECONDS - start)); sleep 2
check "slow hook does not block the poll" "$(( took < 4 ))" "1"
check "hook state filter" "$(grep -c '"state"' "$FAKE_DIR/hook.log")" "1"

# notifications are batched per poll
setup
echo 'MDWATCH_NTFY_TOPIC=t' > "$MDWATCH_CONFIG"
printf '%s\n' "900|RUNNING|a|n1|1:00|1:00:00|$T/w|(null)" "901|RUNNING|b|n1|1:00|1:00:00|$T/w|mdwatch:notify=off" "902|RUNNING|c|n1|1:00|1:00:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"
watch
check "one push for a burst, notify=off respected" "$(grep -c ^CALL "$FAKE_DIR/curl.log") $(grep -c "2 job events" "$FAKE_DIR/curl.log")" "1 1"

# wait returns the terminal state
setup
echo "950|FAILED|w|00:00:01|n1|1:0|$T/w|||00:10:00|0:01|1|1G|" > "$FAKE_DIR/sacct.txt"
out=$("$MDWATCH" wait 950 --timeout 5); rc=$?
check "wait reports failure" "$out rc=$rc" "950 FAILED rc=1"

# finished jobs are forgotten after MDWATCH_KEEP_HOURS
setup
echo "MDWATCH_KEEP_HOURS=0" > "$MDWATCH_CONFIG"
mkdir -p "$MDWATCH_STATE_DIR"; echo "1000|FINISHED||1|" > "$MDWATCH_STATE_DIR/known_jobs"
watch
check "known_jobs is pruned" "$(wc -c < "$MDWATCH_STATE_DIR/known_jobs")" "0"

# pre-0.3 known_jobs format ("jobid STATE") is migrated without re-emitting
setup
mkdir -p "$MDWATCH_STATE_DIR"; printf '%s\n' "1100 RUNNING" "1101 FINISHED" > "$MDWATCH_STATE_DIR/known_jobs"
echo "1100|RUNNING|old|n1|1:00|1:00:00|$T/w|(null)" > "$FAKE_DIR/squeue.txt"
watch
check "old state format migrates silently" "$(events)" ""

echo "$pass passed, $fail failed"
(( fail == 0 ))
