# Sourced by interactive bash shells (docker exec -it <container> bash).
# Updates the process timezone from TZ so `date` matches the container's TZ
# without restarting anything (Debian reads /etc/localtime at startup).
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
  if [ -w /etc/localtime ] || [ -w /etc ]; then
    cp -f "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null || true
    echo "${TZ}" > /etc/timezone 2>/dev/null || true
  fi
fi
