#!/usr/bin/env bash
#
# test-install.sh — smoke-test the omp-saia-gwdg installer.
#
# Runs src/add-saia-omp.sh against a throwaway HOME / PI_CODING_AGENT_DIR /
# OMP_AGENT_ENV_FILE so it never touches ~/.omp/agent or the real .env, and never
# installs omp (omp is assumed present). Verifies the generated models.yml and
# config.yml, that the key is persisted to the fake .env, and that the fake SAIA
# endpoint answers. Then checks the automatic key swap: with two keys, the first
# one revoked, omp is pointed at the local saia-keyring proxy and a request
# through it fails over to the second key. The proxy is started with
# SAIA_KEYRING_SERVICE=none, so no systemd unit or real shell rc is touched.
#
#   bash test/test-install.sh
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WORK="$(mktemp -d)"
export HOME="$WORK/home"
export PI_CODING_AGENT_DIR="$WORK/agent"
export OMP_AGENT_ENV_FILE="$WORK/agent/.env"
export SAIA_KEYRING_SERVICE=none
mkdir -p "$HOME" "$PI_CODING_AGENT_DIR"

cleanup() {
  [[ -n "${FAKE_PID:-}" ]] && kill "$FAKE_PID" 2>/dev/null || true
  if [[ -n "${KR_PORT:-}" ]]; then
    curl -s "http://127.0.0.1:$KR_PORT/_keyring/health" \
      | python3 -c 'import json,os,sys; os.kill(json.load(sys.stdin)["pid"], 15)' 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Start the fake SAIA ──────────────────────────────────────────────
FAKE_DEAD_KEYS=dead-key SEEN_FILE="$WORK/seen" COUNT_FILE="$WORK/count" \
  python3 ./fake-saia.py >"$WORK/port" 2>"$WORK/fake.log" &
FAKE_PID=$!
for _ in $(seq 40); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
PORT="$(cat "$WORK/port")"
[[ -n "$PORT" ]] || { echo "FAIL: fake-saia did not start" >&2; cat "$WORK/fake.log" >&2; exit 1; }
echo "fake-saia on port $PORT"

# ── Run the installer source against the fake ────────────────────────
SAIA_API_KEY=dummy bash ../src/add-saia-omp.sh >"$WORK/install.log" 2>&1 || {
  echo "FAIL: add-saia-omp.sh exited non-zero" >&2
  cat "$WORK/install.log" >&2
  exit 1
}

fail() { echo "FAIL: $1" >&2; echo "--- install.log ---" >&2; cat "$WORK/install.log" >&2; exit 1; }

MODELS_YML="$PI_CODING_AGENT_DIR/models.yml"
CONFIG_YML="$PI_CODING_AGENT_DIR/config.yml"
ENV_FILE="$OMP_AGENT_ENV_FILE"

[[ -f "$MODELS_YML" ]] || fail "models.yml not written"
grep -q "baseUrl: https://chat-ai.academiccloud.de/v1" "$MODELS_YML" \
  || fail "base URL missing"
grep -q "api: openai-completions" "$MODELS_YML" \
  || fail "api type missing"
grep -q "apiKey: SAIA_API_KEY" "$MODELS_YML" \
  || fail "env-var apiKey missing"
grep -q "id: deepseek-v4-flash-0731" "$MODELS_YML" \
  || fail "default model not in models list"
grep -q "id: qwen3-coder-next" "$MODELS_YML" \
  || fail "model list not written"

[[ -f "$CONFIG_YML" ]] || fail "config.yml not written"
grep -q "default: gwdg-saia/deepseek-v4-flash-0731" "$CONFIG_YML" \
  || fail "default model missing"

[[ -f "$ENV_FILE" ]] || fail ".env not written"
grep -q "SAIA_API_KEY='dummy'" "$ENV_FILE" \
  || fail "key not persisted to .env"

# ── Verify the fake endpoint answers (models list) ───────────────────
MODELS_JSON="$(curl -s -H "Authorization: Bearer dummy" "http://127.0.0.1:$PORT/v1/models")"
echo "$MODELS_JSON" | grep -q "fake-model" || fail "fake endpoint did not list models"

echo "PASS: models.yml + config.yml written, key persisted, fake endpoint answered"

# ── SAIA_BASE_URL override (used by the benchmark's local gateway) ─────
OV="$WORK/override"; mkdir -p "$OV/home"
HOME="$OV/home" PI_CODING_AGENT_DIR="$OV/agent" OMP_AGENT_ENV_FILE="$OV/agent/.env" \
  SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" SAIA_API_KEY=dummy bash ../src/add-saia-omp.sh \
  >"$WORK/override.log" 2>&1 || fail "installer failed with SAIA_BASE_URL set"
grep -q "baseUrl: http://127.0.0.1:$PORT/v1" "$OV/agent/models.yml" \
  || fail "SAIA_BASE_URL not written to models.yml"
echo "PASS: SAIA_BASE_URL override"

# ── Automatic key swap: two keys, the first one revoked ───────────────
KR="$WORK/keyring"; mkdir -p "$KR/home"
KR_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
HOME="$KR/home" PI_CODING_AGENT_DIR="$KR/agent" OMP_AGENT_ENV_FILE="$KR/agent/.env" \
  SAIA_KEYRING_PORT="$KR_PORT" SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" SAIA_API_KEY=dead-key \
  bash ../src/add-saia-omp.sh --keyring --extra-keys good-key >"$WORK/keyring.log" 2>&1 \
  || { cat "$WORK/keyring.log" >&2; fail "installer failed with --keyring"; }
grep -q "baseUrl: http://127.0.0.1:$KR_PORT/v1" "$KR/agent/models.yml" \
  || { cat "$WORK/keyring.log" >&2; fail "models.yml not pointed at the keyring proxy"; }
KR_CFG="$KR/home/.config/saia-keyring/keyring.json"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$KR_CFG")" == 0o600 ]] \
  || fail "keyring.json is not chmod 600"
: >"$WORK/seen"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer dead-key" \
  "http://127.0.0.1:$KR_PORT/v1/models")"
[[ "$CODE" == 200 ]] || fail "request through the keyring proxy returned $CODE"
[[ "$(paste -sd, "$WORK/seen")" == "dead-key,good-key" ]] \
  || fail "proxy did not fail over from the revoked key (saw: $(paste -sd, "$WORK/seen"))"
echo "PASS: automatic key swap (revoked key -> next key through the local proxy)"
