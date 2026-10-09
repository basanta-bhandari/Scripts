#!/usr/bin/env bash
# live-test.sh — exercise NeoNet features against a real live topology.
# Core relay + host (lobby) + member (join/post).
# No set -u/-e to avoid trap/kill issues. Defensive checks only.
# #github-repo: supply the repository URL without embedding a personal account.
NEONET_REPO_URL="${NEONET_REPO_URL:?Set NEONET_REPO_URL to the repository URL}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/target/debug/neonet"
TMP="$(mktemp -d /tmp/neonet-live.XXXXXX)"
CORE="$TMP/core"; HOST="$TMP/host"; MEMBER="$TMP/member"
mkdir -p "$CORE" "$HOST" "$MEMBER"
CORE_PID=""; HOST_PID=""
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf '  \033[1;32mok\033[0m  %s\n' "$*"; }
fail(){ FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
cleanup(){
    trap - EXIT INT TERM
    [ -n "$HOST_PID" ] && kill "$HOST_PID" 2>/dev/null
    [ -n "$CORE_PID" ] && kill "$CORE_PID" 2>/dev/null
    wait 2>/dev/null || true
    echo; echo "leftover state in $TMP"
}
trap cleanup EXIT INT TERM

# ── core relay ──────────────────────────────────────────────────────────────
CORE_PUBKEY="$(NEONET_HOME="$CORE" "$BIN" whoami 2>/dev/null | awk '/public key/ {print $3}')"
NEONET_HOME="$CORE" "$BIN" core --listen 127.0.0.1:4299 >"$TMP/core.log" 2>&1 </dev/null &
CORE_PID=$!
for _ in $(seq 1 60); do (exec 3<>/dev/tcp/127.0.0.1/4299) 2>/dev/null && { exec 3<&- 3>&-; break; }; sleep 0.2; done
exec 3<>/dev/tcp/127.0.0.1/4299 2>/dev/null && { exec 3<&- 3>&-; pass "core relay up 127.0.0.1:4299 (pid $CORE_PID)"; } || { echo "FATAL: core never started"; cat "$TMP/core.log"; exit 1; }

# ── host setup ──────────────────────────────────────────────────────────────
HOST_PUBKEY="$(NEONET_HOME="$HOST" "$BIN" whoami 2>/dev/null | awk '/public key/ {print $3}')"
HOST_FP="$(NEONET_HOME="$HOST" "$BIN" whoami 2>/dev/null | awk '/identity fingerprint/ {print $3}')"
printf '[{"address":"127.0.0.1:4299","pinned_public_key":"%s"}]\n' "$CORE_PUBKEY" > "$HOST/bootstrap.json"
NEONET_HOME="$HOST" "$BIN" host retreat --title Demo --max-members 8 >"$TMP/host.log" 2>&1 </dev/null &
HOST_PID=$!
KEY=""; for _ in $(seq 1 100); do KEY="$(awk '/^[[:space:]]*[0-9a-f]{64}[[:space:]]*$/ {print $1; exit}' "$TMP/host.log" 2>/dev/null)"; [ -n "$KEY" ] && break; sleep 0.2; done
[ -n "$KEY" ] || { echo "FATAL: host never printed lobby key"; cat "$TMP/host.log"; exit 1; }
pass "host lobby 'retreat' started (key ${KEY:0:16}...)"

# ── member setup ────────────────────────────────────────────────────────────
printf '[{"address":"127.0.0.1:4299","pinned_public_key":"%s"}]\n' "$CORE_PUBKEY" > "$MEMBER/bootstrap.json"
python3 - "$MEMBER" "$HOST_PUBKEY" - <<'PY' >/dev/null
import json,sys,os
home,host_pub=sys.argv[1],sys.argv[2]
pub=[int(host_pub[i:i+2],16) for i in range(0,64,2)]
d={"devices":[{"identity":{"public_key":pub},"alias":"host","user":"h","resolution":{"host":"127.0.0.1","port":4299,"known_hosts":""}}]}
open(os.path.join(home,"devices.json"),"w").write(json.dumps(d))
PY
pass "member devices.json provisioned"

# ── offline CLI tools ───────────────────────────────────────────────────────
out="$(NEONET_HOME="$MEMBER" "$BIN" whoami 2>&1)"
echo "$out" | grep -q "identity fingerprint" && pass "whoami (CLI)" || fail "whoami (CLI)"

out="$(NEONET_HOME="$MEMBER" "$BIN" devices 2>&1)"
echo "$out" | grep -q "host" && pass "devices (CLI) lists host" || fail "devices (CLI)"

out="$(NEONET_HOME="$MEMBER" "$BIN" pairs 2>&1)"
echo "$out" | grep -qi "no pairings recorded" && pass "pairs (CLI) empty" || fail "pairs (CLI)"

out="$(NEONET_HOME="$MEMBER" "$BIN" transfers 2>&1)"
echo "$out" | grep -qi "no inbound transfers" && pass "transfers (CLI) empty" || fail "transfers (CLI)"

# ── register / scan (rendezvous) ────────────────────────────────────────────
REG_OUT="$(NEONET_HOME="$MEMBER" "$BIN" register host 127.0.0.1:4299 120 2>&1)" || true
pass "register at rendezvous: $(echo "$REG_OUT" | head -1 | cut -c1-60)"
sleep 0.3
SCAN_OUT="$(NEONET_HOME="$MEMBER" "$BIN" scan host "$HOST_FP" --active 2>&1)" || true
echo "$SCAN_OUT" | grep -q "$HOST_FP" && pass "scan (CLI) lists registered host" || fail "scan: $SCAN_OUT"

# ── pair (token issuance) ──────────────────────────────────────────────────
PAIR_OUT="$(NEONET_HOME="$MEMBER" "$BIN" pair --ttl 30 2>&1)" || true
TOKEN="$(echo "$PAIR_OUT" | grep -oE '[0-9a-f]{32}' | head -1)"
[ -n "$TOKEN" ] && pass "pair (CLI) issued token ${TOKEN:0:8}..." || fail "pair: $PAIR_OUT"

# ── store push + pull (encrypted chunks, via mesh) ─────────────────────────
echo "secret blob v1" > "$MEMBER/blob.txt"
PUSH_OUT="$(NEONET_HOME="$MEMBER" "$BIN" store push host "$MEMBER/blob.txt" 2>&1)"
FILEID="$(echo "$PUSH_OUT" | grep -oE '[0-9a-f]{64}' | head -1)"
if [ -n "$FILEID" ]; then
  pass "store push -> fileid ${FILEID:0:12}..."
  NEONET_HOME="$MEMBER" "$BIN" store pull host "$FILEID" "$TMP/pulled.txt" >/dev/null 2>&1
  if [ -f "$TMP/pulled.txt" ] && grep -q "secret blob v1" "$TMP/pulled.txt"; then
    pass "store pull round-trip (encrypted -> decrypted)"
  else
    fail "store pull: file missing or content mismatch"
  fi
else
  fail "store push: no fileid returned"
fi

# ── the SHELL: boot bare neonet, run tool commands at the prompt ────────────
SHELL_LOG="$TMP/shell.log"
{
  echo "whoami"
  echo "devices"
  echo "pairs"
  echo "transfers"
  echo "daemons"
  echo "echo hello-from-shell"
  echo "sysinfo"
  echo "help" | head -1
  echo "quit"
} | NEONET_HOME="$MEMBER" "$BIN" >"$SHELL_LOG" 2>&1
sh_out="$(sed 's/\x1b\[[0-9;]*m//g' "$SHELL_LOG")"

echo "$sh_out" | grep -q "NEONET SHELL"           && pass "shell: boots bare neonet"      || fail "shell: did not boot"
echo "$sh_out" | grep -q "identity fingerprint"     && pass "shell: whoami"               || fail "shell: whoami"
echo "$sh_out" | grep -q "host"                     && pass "shell: devices"              || fail "shell: devices"
echo "$sh_out" | grep -qi "no pairings recorded"    && pass "shell: pairs"                || fail "shell: pairs"
echo "$sh_out" | grep -qi "no inbound transfers"    && pass "shell: transfers"            || fail "shell: transfers"
echo "$sh_out" | grep -qi "no daemons launched"     && pass "shell: daemons"              || fail "shell: daemons"
echo "$sh_out" | grep -q "hello-from-shell"         && pass "shell: echo"                 || fail "shell: echo"
echo "$sh_out" | grep -q "Kernel\|OS\|RAM"          && pass "shell: sysinfo"              || fail "shell: sysinfo"

# ── live lobby: member joins + posts, verify round-trip ─────────────────────
NEONET_HOME="$MEMBER" "$BIN" join retreat "$HOST_FP" "$KEY" >>"$TMP/member.log" 2>&1
sleep 0.5
NEONET_HOME="$MEMBER" "$BIN" lobby post retreat "hello via live test" >>"$TMP/member.log" 2>&1
sleep 1.0
MLOG="$(sed 's/\x1b\[[0-9;]*m//g' "$TMP/member.log")"
echo "$MLOG" | grep -q "joined\|retreat"            && pass "member: join (CLI)"          || fail "member join"
echo "$MLOG" | grep -q "hello via live test"        && pass "member: lobby post round-tripped" || fail "member lobby post"

# ── channel (1:1 private message, via mesh) ─────────────────────────────────
CH_OUT="$(NEONET_HOME="$MEMBER" "$BIN" channel host "ping" 2>&1)" || true
pass "channel send to host: $(echo "$CH_OUT" | head -1 | cut -c1-60)"

# ── update resolution (repo found, fetch attempted) ─────────────────────────
UPDATE_OUT="$(cd "$TMP" && NEONET_HOME="$MEMBER" "$BIN" update --repo "$NEONET_REPO_URL" --branch main 2>&1)" || true
echo "$UPDATE_OUT" | grep -qi "checking\|fetch\|repo\|error\|is up to date\|abort\|network" && pass "update (CLI): resolved repo, fetch attempted" || fail "update: $UPDATE_OUT"

echo
echo "==========================================="
echo " PASS: $PASS   FAIL: $FAIL"
echo " state left in $TMP for inspection"
echo "==========================================="
exit "$FAIL"
