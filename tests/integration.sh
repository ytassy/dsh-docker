#!/bin/sh
# End-to-end integration test of the built DSH image.
#
# Runs on the host with Docker available. Every step is sequential and the
# container is always removed at the end, so it is safe to run locally and in
# GitHub Actions. Any unexpected result aborts with a non-zero status.
#
# Usage: tests/integration.sh [image]           (default: dsh-docker:test)
#
# Host port defaults to 39080 (deliberately unusual: never clashes with a DSH
# instance you may already run on 3080/3081). Override with TEST_PORT.
set -eu

IMAGE="${1:-dsh-docker:test}"
PORT="${TEST_PORT:-39080}"
NAME="dshtest-dsh-integration-$$"
VOL="dshtest-dsh-vol-$$"
WORK="$(mktemp -d)"

FAILS=0
ok() { printf 'PASS  %s\n' "$*"; }
ko() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Wait until DSH printed its tokenized URL in the container logs.
wait_token() {
  i=0
  while [ "$i" -lt 90 ]; do
    line="$(docker logs "$NAME" 2>&1 | grep -o 'http://[^ ]*token=[A-Za-z0-9_-]*' | head -1 || true)"
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
      return 1
    fi
    sleep 2
    i=$((i + 1))
  done
  return 1
}

cookie_from() { # $1 = curl cookie jar
  awk '/dsh-auth/{print $6"="$7}' "$1" | tr -d '\r' | tail -1
}

echo "== image: $IMAGE   host port: $PORT   container: $NAME"

# ---------------------------------------------------------------- 1. start
docker run -d --name "$NAME" \
  -p "127.0.0.1:${PORT}:3080" \
  -v "${VOL}:/home/dsh/.dsh" \
  -v "${WORK}/workspace:/workspace" \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --pids-limit 1024 \
  --memory 1536m \
  "$IMAGE" >/dev/null
ok "container started"

URL="$(wait_token)" || { echo "--- logs"; docker logs "$NAME"; exit 1; }
TOK="${URL##*token=}"
ok "DSH printed tokenized URL: http://<container>:3080/?token=..."

# ------------------------------------------------------- 2. process checks
pid1="$(docker exec "$NAME" cat /proc/1/comm || true)"
[ "$pid1" = "tini" ] && ok "PID 1 is tini (signal forwarding)" || ko "PID 1 is '$pid1', expected tini"

dsh_uid="$(docker exec "$NAME" sh -c "pid=\$(pgrep -f 'bin.js web' | head -1); awk '/^Uid:/{print \$2}' /proc/\$pid/status")"
[ "$dsh_uid" = "1000" ] && ok "DSH process runs as uid 1000 (non-root)" || ko "DSH runs as uid '$dsh_uid'"
docker exec "$NAME" sh -c 'id -u | grep -qx 1000' && ok "container user is uid 1000" || ko "container user is not uid 1000"
docker exec "$NAME" sh -c 'grep -q "^NoNewPrivs:.1" /proc/self/status' \
  && ok "no_new_privs is enforced" || ko "no_new_privs is not set"
caps="$(docker exec "$NAME" grep -E '^(CapEff|CapBnd|CapAmb):' /proc/1/status | awk '{print $2}' | tr '\n' ' ')"
[ "$caps" = "0000000000000000 0000000000000000 0000000000000000 " ] \
  && ok "all Linux capabilities dropped (CapEff/CapBnd/CapAmb = 0)" \
  || ko "capabilities remain: $caps"
docker exec "$NAME" sh -c 'grep -q " 0100007F:0C08 " /proc/net/tcp' \
  && ko "DSH listens on loopback (host could never reach it)" \
  || ok "DSH does not listen on loopback only"

# ----------------------------------------------- 3. HTTP reachable from host
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
[ "$code" = "401" ] && ok "unauthenticated GET / -> 401 (native DSH auth enforced)" || ko "unauthenticated GET / -> $code"

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/?token=wrong-token" || true)"
[ "$code" = "401" ] && ok "wrong token -> 401" || ko "wrong token -> $code"

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/?token=${TOK}" -c "$WORK/cj" || true)"
[ "$code" = "303" ] && ok "valid token -> 303 + session cookie" || ko "valid token -> $code"

body="$(curl -s -b "$WORK/cj" "http://127.0.0.1:${PORT}/" || true)"
echo "$body" | grep -qi '<!doctype html>' && ok "Web UI index served with cookie" || ko "Web UI index not served"

code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example.com' -b "$WORK/cj" "http://127.0.0.1:${PORT}/api/" || true)"
[ "$code" = "403" ] && ok "foreign Host header on /api -> 403 (browser-trust fence)" || ko "foreign Host header on /api -> $code"

COOKIE="$(cookie_from "$WORK/cj")"

# --------------------------------------------------- 4. WebSocket handshake
ws() { # $1=Host  $2=cookie  -> prints status code of the upgrade/response
  HOST_HDR="$1" COOKIE_HDR="$2" PORT="$PORT" node -e '
    const http = require("http")
    const req = http.request({
      host: "127.0.0.1", port: Number(process.env.PORT), path: "/api/remote.mux",
      headers: {
        Host: process.env.HOST_HDR,
        Connection: "Upgrade", Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
        ...(process.env.COOKIE_HDR ? { Cookie: process.env.COOKIE_HDR } : {}),
      },
    })
    const done = (c) => { console.log(c); process.exit(0) }
    req.on("upgrade", (res, sock) => { sock.destroy(); done(res.statusCode) })
    req.on("response", (res) => { res.resume(); done(res.statusCode) })
    req.on("error", (e) => { console.log("ERR " + e.message); process.exit(0) })
    setTimeout(() => { console.log("TIMEOUT"); process.exit(0) }, 5000)
    req.end()'
}
ws_host="127.0.0.1:${PORT}"
r="$(ws "$ws_host" "")"
[ "$r" = "401" ] && ok "WebSocket without cookie -> 401" || ko "WebSocket without cookie -> $r"
r="$(ws "$ws_host" "$COOKIE")"
[ "$r" = "101" ] && ok "WebSocket with cookie -> 101 Switching Protocols" || ko "WebSocket with cookie -> $r"

# --------------------------------------------------------- 5. tool versions
docker exec "$NAME" git --version >/dev/null 2>&1 && ok "git: $(docker exec "$NAME" git --version)" || ko "git missing"
docker exec "$NAME" node --version | grep -q '^v24\.' && ok "node: $(docker exec "$NAME" node --version)" || ko "unexpected node version"
docker exec "$NAME" dsh --version | grep -q '^0.2.2-rc.5$' && ok "dsh: $(docker exec "$NAME" dsh --version)" || ko "unexpected dsh version"
docker exec "$NAME" sh -c 'curl --version | head -1' >/dev/null && ok "curl: present" || ko "curl missing"

# ------------------------------------------------------- 6. health + restart
HEALTH=""
i=0
while [ "$i" -lt 30 ]; do
  HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$NAME" 2>/dev/null || true)"
  [ "$HEALTH" = "healthy" ] && break
  sleep 2
  i=$((i + 1))
done
[ "$HEALTH" = "healthy" ] && ok "HEALTHCHECK reports healthy" || ko "HEALTHCHECK status: '$HEALTH'"

docker exec "$NAME" sh -c 'mkdir -p /workspace/probe /home/dsh/.dsh/marker && echo persisted > /workspace/probe/file.txt && echo home > /home/dsh/.dsh/marker/file.txt'
docker restart "$NAME" >/dev/null
URL2="$(wait_token)" || { docker logs "$NAME"; exit 1; }
TOK2="${URL2##*token=}"
[ -n "$TOK2" ] && ok "container restarted and DSH printed a fresh token" || ko "no token after restart"
[ "$(docker exec "$NAME" cat /workspace/probe/file.txt 2>/dev/null)" = "persisted" ] && ok "/workspace data survives restart" || ko "/workspace data lost"
[ "$(docker exec "$NAME" cat /home/dsh/.dsh/marker/file.txt 2>/dev/null)" = "home" ] && ok "DSH_HOME data survives restart" || ko "DSH_HOME data lost"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/?token=${TOK2}" || true)"
[ "$code" = "303" ] && ok "HTTP reachable and authenticating again after restart" || ko "HTTP after restart -> $code"

# --------------------------------------- 7. volume persistence across a new container
docker rm -f "$NAME" >/dev/null
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:3080" -v "${VOL}:/home/dsh/.dsh" -v "${WORK}/workspace:/workspace" --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 1024 --memory 1536m "$IMAGE" >/dev/null
URL3="$(wait_token)" || { docker logs "$NAME"; exit 1; }
TOK3="${URL3##*token=}"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/?token=${TOK3}" -c "$WORK/cj3" || true)"
# The previous cookie (same authority) must still authenticate: DSH keeps its
# signing key and browser sessions in DSH_HOME, which lives on the volume.
body="$(curl -s -b "$WORK/cj" "http://127.0.0.1:${PORT}/" || true)"
echo "$body" | grep -qi '<!doctype html>' && ok "recreated container: old DSH_HOME volume keeps working (sessions/profiles/login)" || ko "recreated container: volume data not reused"

# ------------------------------------------------- 8. root is refused
set +e
out="$(docker run --rm --user 0 "$IMAGE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] && echo "$out" | grep -q "refusing to run as root" && ok "running as root is refused" || ko "root run was not refused (rc=$rc)"

# ------------------------------------------------ 9. graceful shutdown (SIGTERM)
docker stop -t 20 "$NAME" >/dev/null
docker logs "$NAME" > "$WORK/final.log" 2>&1 || true
docker inspect -f '{{.State.ExitCode}}' "$NAME" | grep -qx 0 \
  && ok "clean shutdown on SIGTERM (exit code 0)" || ko "shutdown exit code: $(docker inspect -f '{{.State.ExitCode}}' "$NAME")"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "ALL INTEGRATION CHECKS PASSED"
else
  echo "$FAILS CHECK(S) FAILED"
  exit 1
fi
