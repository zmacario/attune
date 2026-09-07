#!/bin/bash
# Watches a running Attune for the things that only show up over hours.
#
# The app is meant to sit in the menu bar for weeks. Nothing in the ordinary tests would
# notice a slow leak: a file descriptor per log-stream restart, a timer that is rescheduled
# but never cancelled, a ring buffer that is not as circular as it looks. Those show as a
# trend, not as a failure, so this samples and reports the trend.
#
# Usage: tools/test-soak.sh [minutes] [seconds between samples]
set -euo pipefail
cd "$(dirname "$0")/.."

MINUTES="${1:-60}"
INTERVAL="${2:-60}"
SAMPLES=$(( MINUTES * 60 / INTERVAL ))

PID="$(pgrep -f "/Applications/Attune.app/Contents/MacOS" | head -1 || true)"
[ -n "$PID" ] || { echo "Attune is not running — open it first" >&2; exit 1; }

printf "watching pid %s for %s minutes, sampling every %ss\n\n" "$PID" "$MINUTES" "$INTERVAL"
# CPU is shown per window rather than cumulative. Cumulative hides its own shape: a burst
# looks like a slightly steeper line, and it took subtracting neighbouring rows by hand to
# notice the menu being open had cost twenty times the idle rate.
printf "%8s  %10s  %8s  %6s  %10s\n" "elapsed" "footprint" "threads" "fds" "cpu/window"

sample() {
    local footprint threads fds cpu
    footprint="$(footprint -p "$PID" 2>/dev/null | grep -o 'Footprint: [0-9.]* MB' | grep -o '[0-9.]*' | head -1)"
    threads="$(ps -M -p "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
    fds="$(lsof -p "$PID" 2>/dev/null | wc -l | tr -d ' ')"
    cpu="$(ps -o time= -p "$PID" 2>/dev/null | tr -d ' ')"
    echo "${footprint:-0} ${threads:-0} ${fds:-0} ${cpu:-0}"
}

# Seconds of CPU, so windows can be compared.
cpu_seconds() {
    ps -o time= -p "$PID" 2>/dev/null | tr -d ' ' \
        | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }'
}
# How hard the app was worked. "Nothing grew" means little if nothing happened.
tracks_since() {
    /usr/bin/log show --predicate 'subsystem == "com.macario.attune"' --last "$1" --info --debug 2>/dev/null \
        | grep -c "snapshot: state=playing" || true
}

read -r first_mem first_threads first_fds _ <<<"$(sample)"
previous_cpu="$(cpu_seconds)"
printf "%8s  %7s MB  %8s  %6s  %10s\n" "0m" "$first_mem" "$first_threads" "$first_fds" "start"

worst_mem="$first_mem" worst_fds="$first_fds" worst_threads="$first_threads"
for i in $(seq 1 "$SAMPLES"); do
    perl -e "select(undef,undef,undef,$INTERVAL)"
    kill -0 "$PID" 2>/dev/null || { echo "the app exited during the soak" >&2; exit 1; }
    read -r mem threads fds _ <<<"$(sample)"
    now_cpu="$(cpu_seconds)"
    printf "%8s  %7s MB  %8s  %6s  %9.2fs\n" "$(( i * INTERVAL / 60 ))m" "$mem" "$threads" "$fds" \
        "$(awk -v a="$now_cpu" -v b="$previous_cpu" 'BEGIN{print a-b}')"
    previous_cpu="$now_cpu"
    awk -v a="$mem" -v b="$worst_mem" 'BEGIN{exit !(a>b)}' && worst_mem="$mem"
    [ "$fds" -gt "$worst_fds" ] && worst_fds="$fds"
    [ "$threads" -gt "$worst_threads" ] && worst_threads="$threads"
done

echo
printf "footprint %s MB -> peak %s MB\n" "$first_mem" "$worst_mem"
printf "descriptors %s -> peak %s\n" "$first_fds" "$worst_fds"
printf "threads %s -> peak %s\n" "$first_threads" "$worst_threads"
printf "tracks played during the soak: %s\n" "$(tracks_since "${MINUTES}m")"

# Thresholds are deliberately loose. This is looking for a trend, not for jitter: the
# footprint moves a little with the menu being opened, and libdispatch grows and reclaims
# worker threads on its own.
fail=0
awk -v a="$worst_mem" -v b="$first_mem" 'BEGIN{exit !(a > b * 1.5 && a > b + 5)}' \
    && { echo "FAIL: the footprint grew by more than half" >&2; fail=1; }
[ "$worst_fds" -gt $(( first_fds + 20 )) ] && { echo "FAIL: descriptors kept climbing" >&2; fail=1; }
[ "$worst_threads" -gt $(( first_threads + 12 )) ] && { echo "FAIL: threads kept climbing" >&2; fail=1; }
[ "$fail" -eq 0 ] && echo "soak ok"
exit "$fail"
