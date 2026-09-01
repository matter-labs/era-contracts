#!/bin/bash
# Kill test Anvil instances on known ports and run the v31->v32 upgrade test
# Restrict to LISTENing sockets so clients merely connected to these ports are never killed
# (see cleanup.sh for the PID-aware variant used by the interop tests).
for port in 9545 4050 4051 4052 4053 4054; do
  lsof -ti :$port -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 2>/dev/null
done
sleep 1

cd "$(dirname "$0")"
npx ts-node run-upgrade-test.ts > /tmp/upgrade-test-output.txt 2>&1
EXIT_CODE=$?
echo "EXIT CODE: $EXIT_CODE"
tail -30 /tmp/upgrade-test-output.txt
exit $EXIT_CODE
