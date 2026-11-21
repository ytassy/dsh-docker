# syntax=docker/dockerfile:1
#
# DeepSeek Harness (DSH) - minimal Docker image
# ============================================
#
# - Base: official Node.js image, Debian slim variant, pinned by digest.
#   DSH 0.2.2-rc.5 declares "engines": { "node": ">=24.9.0" }, so Node 24 is required.
# - DSH itself is installed from the official npm package @deepseek-ai/dsh
#   at an exact version and resolved through package-lock.json
#   (npm ci), so a rebuild installs the same dependency tree.
# - Runs as the unprivileged user "dsh" (uid 1000, gid 1000).
# - Contains only what DSH needs to run: Node.js, git (DSH agents use git), curl
#   (for the HEALTHCHECK), tini (PID 1, PID 1 signal forwarding) and iproute2
#   (the entrypoint discovers the container's interface address, because DSH
#   refuses to bind 0.0.0.0). Nothing else, no Chromium, no PHP/Composer
#   (those live in the "dev" variant, see docker/dev/Dockerfile).
#
# Build:
#   docker build -t dsh:local .
#
# Pinned base image (node:24-bookworm-slim, Resolved-Digest from the official index).
FROM node:24-bookworm-slim@sha256:dc26ae92c9fb15cf6b1d63e20f0944b2efe0f115b20e00be48fb23fceb061c54

LABEL org.opencontainers.image.title="DeepSeek Harness (DSH)" \
      org.opencontainers.image.description="DeepSeek Harness official web UI, installed from npm, non-root" \
      org.opencontainers.image.source="https://github.com/deepseek-ai/deepseek-harness" \
      org.opencontainers.image.licenses="MIT"

# --- System packages -------------------------------------------------------
# Debian archive access is pinned for reproducible rebuilds: the base image
# records the snapshot of the day it was built in a comment in
# /etc/apt/sources.list.d/debian.sources, so both archives are rewritten to that
# snapshot, reduced to bookworm + bookworm-security (bookworm-updates moves),
# and the security archive's Release window is relaxed because that snapshot
# one day no longer satisfies its short freshness window. Site packages are
# ignored (/etc/apt/apt.conf.d/docker-*).
ARG DEBIAN_SNAPSHOT=20261104T212339Z
RUN set -eux; \
    sed -i -E \
      -e "s|^URIs: http://deb.debian.org/debian-security|URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/|" \
      -e "s|^URIs: http://deb.debian.org/debian|URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/|" \
      -e "s|^Suites: bookworm bookworm-updates$|Suites: bookworm|" \
      /etc/apt/sources.list.d/debian.sources; \
    printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99dsh-snapshot; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      iproute2 \
      tini; \
    rm -rf /var/lib/apt/lists/* /var/log/apt/* /var/cache/apt/*

# --- DSH from the official npm package -------------------------------------
# Installed globally as root at BUILD time (never at runtime), into a prefix the
# unprivileged user can read and execute but not modify.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false
RUN npm install -g --no-fund --no-audit npm@11
COPY package.json package-lock.json /opt/dsh/
RUN npm ci --prefix /opt/dsh --omit=dev --no-fund --no-audit \
 && mkdir -p /opt/dsh/bin \
 && ln -s /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js /opt/dsh/bin/dsh \
 && chmod -R a-w /opt/dsh && chmod -R a+rX /opt/dsh
ENV PATH=/opt/dsh/bin:/opt/dsh/node_modules/.bin:${PATH}

# --- Unprivileged user ------------------------------------------------------
# uid/gid 1000 matches the default "users" group on Synology DSM, which keeps
# the bind-mounted /dsh volumes usable without ACL surgery.
RUN set -eux; \
    usermod --login dsh --home /home/dsh --move-home node; \
    groupmod --new-name dsh node; \
    install -d -o dsh -g dsh -m 0755 /home/dsh/.dsh /workspace; \
    test "$(id -u dsh)" = 1000; test "$(id -g dsh)" = 1000

# Every process in the container runs as this unprivileged user. There is no
# root and no setuid helper after this point.
USER dsh:dsh

# DSH persists everything under $DSH_HOME (default: ~/.dsh):
#   .credentials.yaml, profiles/, storages/, logs/ ...
ENV DSH_HOME=/home/dsh/.dsh \
    HOME=/home/dsh \
    LANG=C.UTF-8 \
    TZ=Europe/Paris

# --- Runtime ----------------------------------------------------------------
COPY Dockerfile /opt/dsh/IMAGE-Dockerfile
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY docker/zz-dsh-tz.sh /etc/profile.d/zz-dsh-tz.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh /etc/profile.d/zz-dsh-tz.sh

# Project workspace: isolated from the rest of the system, own volume.
WORKDIR /workspace

# DSH listens on this port inside the container (publish it from the host).
# It binds the container's own interface address on purpose: 0.0.0.0 is refused.
ENV DSH_LISTEN_PORT=3080
EXPOSE 3080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

# tini forwards SIGTERM/SIGINT to DSH and reaps zombies (DSH runs shell tools).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["web"]
