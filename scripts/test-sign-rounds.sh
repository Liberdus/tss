#!/usr/bin/env bash
# Runs time-windowed signing scenarios for a 7-party threshold-3 TSS setup.
# This harness assumes:
# - the repository contains the sign discovery timeout changes
# - party homes already exist at testing/.test1 ... testing/.test7
# - each party uses vault_name=default
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TSS_BIN="${TSS_BIN:-${ROOT}/tss}"
ROUNDS="${1:-1}"
MAX_SCENARIOS="${2:-0}"   # 0 = run all
PARTIES=7
THRESHOLD=3
MIN_SIGN=$((THRESHOLD + 1))
PASS=0
FAIL=0
RESULTS_LOG="${SCRIPT_DIR}/test-sign-rounds.log"
PARTY_TIMEOUT=30
PASSWORD="${PASSWORD:-123456789}"
CHANNEL_PASSWORD="${CHANNEL_PASSWORD:-123456789}"
MESSAGE_DEC="${MESSAGE_DEC:-81878784180467215339657199009968320418167612298391878172028460193657732373998}"
DISCOVERY_TIMEOUT="${DISCOVERY_TIMEOUT:-5s}"
VAULT_NAME="${VAULT_NAME:-default}"
LOG_LEVEL="${LOG_LEVEL:-info}"

> "$RESULTS_LOG"
for i in $(seq 1 "$PARTIES"); do
  > "${SCRIPT_DIR}/test-party${i}.log"
done

SCENARIOS=(
  "0 0 0 0 0 0 0"
  "0 1 2 3 4 5 5"
  "0 0 5 5 5 5 5"
  "0 1 0 2 0 3 0"
  "3 0 1 5 2 4 0"
  "0 5 0 5 0 5 0"
  "1 3 5 0 2 4 1"
  "0 0 0 0 0 0 6"
  "0 0 0 0 0 14 0"
  "6 0 0 0 0 0 0"
  "0 0 0 0 0 7 14"
  "0 0 0 0 0 10 20"
  "8 12 0 0 0 0 0"
  "0 0 6 0 0 17 0"
  "6 0 0 0 7 0 0"
  "0 0 0 0 0 15 20"
  "0 0 0 0 6 12 18"
  "6 6 6 0 0 0 0"
  "0 6 0 6 0 6 0"
  "0 0 0 0 8 14 20"
  "0 0 0 6 17 20 0"
  "0 0 0 0 7 14 20"
  "0 0 6 8 10 0 0"
  "6 8 0 0 0 0 17"
  "6 6 6 6 0 0 0"
  "6 0 6 0 6 0 6"
  "0 0 0 6 8 12 17"
  "6 7 8 9 0 0 0"
  "0 0 0 6 7 17 20"
  "0 0 6 6 14 17 20"
  "6 6 6 6 6 0 0"
  "0 2 4 6 10 14 20"
  "6 12 0 0 0 17 20"
  "0 6 8 12 14 17 20"
)

log() {
  echo "$@" | tee -a "$RESULTS_LOG"
}

run_timed() {
  local secs=$1
  shift
  "$@" &
  local pid=$!
  (sleep "$secs" && kill "$pid" 2>/dev/null) &
  local killer=$!
  wait "$pid" 2>/dev/null || true
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
}

run_party() {
  local party=$1
  local channel_id=$2

  run_timed "$PARTY_TIMEOUT" "$TSS_BIN" sign \
    --home "${ROOT}/testing/.test${party}" \
    --vault_name "$VAULT_NAME" \
    --password "$PASSWORD" \
    --channel_password "$CHANNEL_PASSWORD" \
    --channel_id "$channel_id" \
    --log_level "$LOG_LEVEL" \
    --message "$MESSAGE_DEC" \
    --sign_discovery_timeout "$DISCOVERY_TIMEOUT"
}

run_scenario() {
  local round=$1
  shift
  local delays=("$@")

  local expiry channel_id
  expiry=$(( $(date +%s) + 1800 ))
  channel_id=$(printf '%03X%08X' "$round" "$expiry")

  local offsets=()
  for i in $(seq 1 "$PARTIES"); do
    offsets+=( "$(wc -l < "${SCRIPT_DIR}/test-party${i}.log")" )
    echo "--- Round ${round} ---" >> "${SCRIPT_DIR}/test-party${i}.log"
  done

  local pids=()
  for i in $(seq 1 "$PARTIES"); do
    local d="${delays[$((i-1))]}"
    (sleep "$d"; run_party "$i" "$channel_id" 2>&1) >> "${SCRIPT_DIR}/test-party${i}.log" &
    pids+=( $! )
  done

  wait "${pids[@]}" || true

  local ok=0
  local failed_parties=""
  for i in $(seq 1 "$PARTIES"); do
    local plog="${SCRIPT_DIR}/test-party${i}.log"
    local off="${offsets[$((i-1))]}"
    if tail -n +$((off+1)) "$plog" 2>/dev/null | grep -Eq "sign(ing)? finished!"; then
      ok=$((ok+1))
    else
      failed_parties="${failed_parties} P${i}"
    fi
  done

  if [ "$ok" -ge "$MIN_SIGN" ]; then
    log "  PASS ($ok/${PARTIES} signed)${failed_parties:+ - failed:${failed_parties}}"
    PASS=$((PASS+1))
  else
    log "  FAIL ($ok/${PARTIES} signed) - failed:${failed_parties}"
    FAIL=$((FAIL+1))
    for i in $(seq 1 "$PARTIES"); do
      local plog="${SCRIPT_DIR}/test-party${i}.log"
      local off="${offsets[$((i-1))]}"
      if ! tail -n +$((off+1)) "$plog" 2>/dev/null | grep -Eq "sign(ing)? finished!"; then
        log "    [P${i} last lines]:"
        tail -n +$((off+1)) "$plog" 2>/dev/null | tail -5 | sed 's/^/      /' | tee -a "$RESULTS_LOG"
      fi
    done
  fi
}

cd "$ROOT"

SEPARATOR="================================================================"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

{
  echo "$SEPARATOR"
  echo "  TSS Sign Bootstrap Test - $TIMESTAMP"
  echo "$SEPARATOR"
} | tee -a "$RESULTS_LOG"

log "Parties: ${PARTIES}  Threshold: ${THRESHOLD}  Min-sign: ${MIN_SIGN}"
log "Party timeout: ${PARTY_TIMEOUT}s"
log "Discovery timeout: ${DISCOVERY_TIMEOUT}"
log ""

ROUND_COUNTER=0
SCENARIO_COUNTER=0

for scenario in "${SCENARIOS[@]}"; do
  if [ "$MAX_SCENARIOS" -gt 0 ] && [ "$SCENARIO_COUNTER" -ge "$MAX_SCENARIOS" ]; then
    break
  fi
  SCENARIO_COUNTER=$((SCENARIO_COUNTER+1))
  read -r -a delays <<< "$scenario"

  header=""
  for i in $(seq 1 "$PARTIES"); do
    header="${header} P${i}=${delays[$((i-1))]}s"
  done

  {
    echo ""
    echo "----------------------------------------------------------------"
    echo "  Scenario:${header}"
    echo "----------------------------------------------------------------"
  } | tee -a "$RESULTS_LOG"

  for r in $(seq 1 "$ROUNDS"); do
    ROUND_COUNTER=$((ROUND_COUNTER+1))
    run_scenario "$ROUND_COUNTER" "${delays[@]}"
  done
  log ""
done

{
  echo ""
  echo "$SEPARATOR"
  echo "  Results: PASS=$PASS  FAIL=$FAIL  total=$((PASS+FAIL))"
  echo "$SEPARATOR"
} | tee -a "$RESULTS_LOG"
