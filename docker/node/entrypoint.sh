#!/bin/sh
# Installs the project's dependencies into the node_modules volume (Linux
# builds, separate from the host's node_modules), then runs the command.
# Reinstalls only when package.json / package-lock.json change.
set -e

stamp=node_modules/.kleoshq-deps-hash
hash=$(cat package.json package-lock.json 2>/dev/null | sha256sum | cut -d' ' -f1)

if [ "$(cat "$stamp" 2>/dev/null)" != "$hash" ]; then
  echo "[entrypoint] installing dependencies (npm ci ${NPM_CI_FLAGS})"
  # A lock file out of sync with package.json makes `npm ci` refuse: fall back
  # to a plain install that leaves the project's lock file untouched.
  # shellcheck disable=SC2086
  npm ci --no-audit --no-fund --loglevel=error ${NPM_CI_FLAGS} 2>/dev/null || {
    echo "[entrypoint] package-lock.json is out of sync with package.json, using npm install --no-package-lock"
    npm install --no-audit --no-fund --no-package-lock ${NPM_CI_FLAGS}
  }
  echo "$hash" > "$stamp"
fi

exec "$@"
