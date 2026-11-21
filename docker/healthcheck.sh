#!/bin/sh
# Liveness check used by HEALTHCHECK.
#
# DSH binds one concrete interface address and fences every request on the Host
# header. There is no unauthenticated "ping" route: a signed-out GET / answers
# 401 and /api answers 401 as well. So a healthy DSH is exactly one that answers
# *something* over HTTP on the listen address. "Connection refused" (DSH not
# listening yet, or crashed) makes curl exit with status 7 and fails the check.
set -eu

host="$(hostname -i 2>/dev/null | awk '{print $1}')"
port="${DSH_LISTEN_PORT:-3080}"
code="$(curl --silent --output /dev/null --max-time 3 --write-out '%{http_code}' "http://${host}:${port}/" || true)"

case "$code" in
  2??|3??|401|403|404)
    exit 0
    ;;
  *)
    echo "healthcheck: dsh did not answer on http://${host}:${port}/ (curl code: ${code:-none})" >&2
    exit 1
    ;;
esac
