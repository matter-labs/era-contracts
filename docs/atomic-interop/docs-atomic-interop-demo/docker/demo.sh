#!/bin/sh
# Runs in the demo container: copies the example project, installs it and runs scripts/demo.ts.
# The project folder is mounted at /src without write access, so nothing is written to it.
set -e
cp -R /src/package.json /src/package-lock.json /src/scripts /src/contracts /app/
echo "Installing the example's dependencies..."
npm ci --silent --no-audit --no-fund
exec npx tsx scripts/demo.ts
