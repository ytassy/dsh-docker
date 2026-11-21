#!/bin/sh
# DSH container entrypoint.
#
# Starts `dsh web` (the official browser UI) or `dsh headless` (one-shot task,
# for scripts/cron), with a bind address DSH accepts.
#
# Why this script exists: `dsh web --host` accepts only ONE CONCRETE local IPv4
# or IPv6 address and rejects wildcards such as 0.0.0.0 / :: ("binding every
# interface would expose remote code execution to the network"). Behind Docker's
# NAT, publishing a port from the host forwards traffic to the container's own
# interface address, so the reliable and secure choice is to bind exactly that
# address - not a loopback address, which the host could never reach.
#
# Usage: docker-entrypoint.sh [web|headless] [dsh app arguments...]
#
# Environment:
#   DSH_LISTEN_HOST     concrete IPv4/IPv6 literal to bind ("auto" = container address)
#   DSH_LISTEN_PORT     port to bind (default 3080, container side only)
#   DSH_TRUSTED_HOSTS   space-separated host[:port] values accepted by DSH's
#                       browser-trust fence (needed behind a reverse proxy)
#   DSH_PUBLIC_URL      URL advertised by DSH (reverse proxy / Tailscale FQDN)
set -eu

# DSH executes code; it must never run as root. No setuid helper ships in the
# image, so `user: root` (or `--user 0`) fails loudly here instead of silently
# running an agent as root.
if [ "$(id -u)" = "0" ]; then
  echo "dsh: refusing to run as root. Remove 'user: root'/'--user 0' and let the container use uid 1000 (dsh)." >&2
  exit 1
fi

command_name="${1:-web}"

case "$command_name" in
  web)
    shift || true
    if [ -z "${DSH_LISTEN_HOST:-}" ] || [ "${DSH_LISTEN_HOST}" = "auto" ]; then
      host="$(hostname -i 2>/dev/null | awk '{print $1}')"
      case "$host" in
        ""|0.0.0.0|::)
          echo "dsh: could not determine the container IPv4 address (hostname -i); set DSH_LISTEN_HOST" >&2
          exit 1
          ;;
      esac
    else
      host="${DSH_LISTEN_HOST}"
    fi
    port="${DSH_LISTEN_PORT:-3080}"

    set -- web --no-open --host "$host" --port "$port" "$@"
    if [ -n "${DSH_PUBLIC_URL:-}" ]; then
      set -- "$@" --public-url "$DSH_PUBLIC_URL"
    fi
    for th in ${DSH_TRUSTED_HOSTS:-}; do
      set -- "$@" --trusted-host "$th"
    done
    echo "dsh: starting web on http://${host}:${port} (healthy behind Docker NAT; open the tokenized URL printed below)"
    exec dsh "$@"
    ;;
  headless)
    shift || true
    exec dsh headless "$@"
    ;;
  *)
    # Anything else is passed to dsh unchanged (e.g. "tui", "--version", ...).
    exec dsh "$@"
    ;;
esac
