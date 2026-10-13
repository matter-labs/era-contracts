#!/bin/bash
# Kill test Anvil instances on known ports and run the recurring registry-driven upgrade test.
# Use ANVIL_INTEROP_PORT_OFFSET to avoid port conflicts.
for port in 9545 4050 4051 4052 4053 4054; do
  lsof -ti :$port 2>/dev/null | xargs kill -9 2>/dev/null
done
sleep 1

cd "$(dirname "$0")"
npx ts-node run-recurring-upgrade-test.ts > /tmp/registry-upgrade-test-output.txt 2>&1
EXIT_CODE=$?
echo "EXIT CODE: $EXIT_CODE"
tail -40 /tmp/registry-upgrade-test-output.txt
exit $EXIT_CODE
