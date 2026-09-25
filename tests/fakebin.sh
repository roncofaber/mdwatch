# shellcheck shell=bash
# Fake SLURM clients for tests. Each reads a fixture file from $FAKE_DIR:
#   squeue.txt   rows as printed by squeue -h -o '%i|%T|%j|%N|%M|%l|%Z|%k'
#   sacct.txt    rows jobid|state|name|elapsed|node|exit|workdir|stdout|stderr|limit|totalcpu|ncpus|reqmem|comment
#   rss.txt      rows jobid|maxrss (steps allowed, e.g. 12.batch|2G)
make_fakebin() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/squeue" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_DIR/squeue.txt" 2>/dev/null
SH
    cat > "$bin/sacct" <<'SH'
#!/usr/bin/env bash
args=" $* "
ids=""; prev=""
for a in "$@"; do [[ "$prev" == -j ]] && ids="$a"; prev="$a"; done
if [[ "$args" == *"-o JobID,MaxRSS "* ]]; then cat "$FAKE_DIR/rss.txt" 2>/dev/null; exit 0; fi
if [[ "$args" == *"-o JobID,State "* ]]; then
    [[ "$args" == *" -S "* ]] && awk -F'|' '{print $1 "|" $2}' "$FAKE_DIR/sacct.txt" 2>/dev/null
    exit 0
fi
if [[ "$args" == *"-o State "* ]]; then
    awk -F'|' -v id="$ids" '$1==id {print $2}' "$FAKE_DIR/sacct.txt" 2>/dev/null; exit 0
fi
if [[ "$args" == *"-o WorkDir,StdOut,StdErr "* ]]; then
    awk -F'|' -v id="$ids" '$1==id {print $7 "|" $8 "|" $9}' "$FAKE_DIR/sacct.txt" 2>/dev/null; exit 0
fi
awk -F'|' -v ids=",$ids," 'index(ids, "," $1 ",")' "$FAKE_DIR/sacct.txt" 2>/dev/null
SH
    cat > "$bin/scontrol" <<'SH'
#!/usr/bin/env bash
echo "JobId=${@: -1} StdOut=$FAKE_DIR/out/${@: -1}.out StdErr=$FAKE_DIR/out/${@: -1}.out"
SH
    cat > "$bin/curl" <<'SH'
#!/usr/bin/env bash
printf "CALL %s\n" "$*" >> "$FAKE_DIR/curl.log"
SH
    chmod +x "$bin"/*
}
