#!/usr/bin/env bash
set -euo pipefail

PROFILING_INTERVAL=5

parse_output_dir() {
  local args=("$@")
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--output" && $((i+1)) -lt ${#args[@]} ]]; then
      echo "${args[$((i+1))]}"
      return
    fi
  done
  echo "output/default"
}

OUTPUT_DIR=$(parse_output_dir "$@")
mkdir -p "$OUTPUT_DIR"

PROFILE_LOG="${OUTPUT_DIR}/memory_profile.csv"
TIMING_LOG="${OUTPUT_DIR}/timing.txt"

echo "timestamp,pid,rss_mb,vms_mb" > "$PROFILE_LOG"

echo "=== MeQTrack Pipeline Profiling ===" | tee "$TIMING_LOG"
echo "Start time: $(date -Iseconds)" | tee -a "$TIMING_LOG"
echo "Arguments: $*" | tee -a "$TIMING_LOG"
echo "---" | tee -a "$TIMING_LOG"

START_TIME=$(date +%s)

Rscript methylation_pipeline.R "$@" &
R_PID=$!

echo "Pipeline PID: $R_PID" | tee -a "$TIMING_LOG"

monitor_memory() {
  local pid=$1
  local log=$2
  while kill -0 "$pid" 2>/dev/null; do
    TS=$(date +%s)
    RSS=$(ps -o rss= -p "$pid" 2>/dev/null || echo "0")
    VMS=$(ps -o vsz= -p "$pid" 2>/dev/null || echo "0")
    RSS_MB=$(echo "$RSS" | awk '{printf "%.1f", $1/1024}')
    VMS_MB=$(echo "$VMS" | awk '{printf "%.1f", $1/1024}')
    echo "${TS},${pid},${RSS_MB},${VMS_MB}" >> "$log"

    CHILD_PIDS=$(pgrep -P "$pid" 2>/dev/null || true)
    for cpid in $CHILD_PIDS; do
      CRSS=$(ps -o rss= -p "$cpid" 2>/dev/null || echo "0")
      CVMS=$(ps -o vsz= -p "$cpid" 2>/dev/null || echo "0")
      CRSS_MB=$(echo "$CRSS" | awk '{printf "%.1f", $1/1024}')
      CVMS_MB=$(echo "$CVMS" | awk '{printf "%.1f", $1/1024}')
      echo "${TS},${cpid},${CRSS_MB},${CVMS_MB}" >> "$log"
    done

    sleep "$PROFILING_INTERVAL"
  done
}

monitor_memory "$R_PID" "$PROFILE_LOG" &
MONITOR_PID=$!

wait "$R_PID" 2>/dev/null
EXIT_CODE=$?

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$(echo "$ELAPSED" | awk '{printf "%.1f", $1/60}')

PEAK_RSS=$(awk -F, 'NR>1 && $3+0>0 {if($3>max)max=$3} END{printf "%.1f", max}' "$PROFILE_LOG")

echo "---" | tee -a "$TIMING_LOG"
echo "End time: $(date -Iseconds)" | tee -a "$TIMING_LOG"
echo "Wall-clock: ${ELAPSED}s (${ELAPSED_MIN} min)" | tee -a "$TIMING_LOG"
echo "Exit code: $EXIT_CODE" | tee -a "$TIMING_LOG"
echo "Peak RSS: ${PEAK_RSS} MB" | tee -a "$TIMING_LOG"
echo "Memory profile: $PROFILE_LOG" | tee -a "$TIMING_LOG"

exit "$EXIT_CODE"
