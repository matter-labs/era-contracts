import * as assert from "assert/strict";
import { spawnSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { createSuite } from "./harness";

const { test, run } = createSuite("cleanup");

function runCleanup(listenerPid?: number) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "anvil-cleanup-"));
  const directory = path.join(root, "l1-contracts/test/anvil-interop");
  const signalLog = path.join(root, "signals");
  const mocks = path.join(root, "mocks.sh");
  try {
    fs.mkdirSync(path.join(directory, "config"), { recursive: true });
    fs.copyFileSync(path.resolve(__dirname, "../../cleanup.sh"), path.join(directory, "cleanup.sh"));
    fs.writeFileSync(path.join(directory, "config/anvil-config.json"), JSON.stringify({ chains: [{ port: 10000 }] }));
    fs.writeFileSync(signalLog, "");
    // Isolate process selection: record signals and disable port discovery without touching real processes.
    fs.writeFileSync(
      mocks,
      `kill() {
  if [ "$1" != "-0" ]; then
    printf '%s\\n' "$*" >> "$SIGNAL_LOG"
    if [ "$2" = "$LISTENER_PID" ]; then touch "$STOPPED"; fi
  fi
}
lsof() {
  if [ "$2" = ":10100" ] && [ -n "$LISTENER_PID" ] && [ ! -f "$STOPPED" ]; then
    echo "$LISTENER_PID"
  else
    return 1
  fi
}
sleep() { :; }
`
    );
    const result = spawnSync("bash", [path.join(directory, "cleanup.sh")], {
      env: {
        ...process.env,
        BASH_ENV: mocks,
        SIGNAL_LOG: signalLog,
        LISTENER_PID: listenerPid?.toString() ?? "",
        STOPPED: path.join(root, "stopped"),
        ANVIL_INTEROP_PORT_OFFSET: "100",
        ANVIL_INTEROP_RUN_SUFFIX: "",
      },
      encoding: "utf8",
    });
    return {
      status: result.status,
      signals: fs.readFileSync(signalLog, "utf8").trim().split("\n").filter(Boolean),
    };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("stops only the configured offset listener", () => {
  const listenerPid = 2147483646;
  const result = runCleanup(listenerPid);
  assert.equal(result.status, 0);
  assert.deepEqual(result.signals, [`-TERM ${listenerPid}`]);
});

test("sends no signals when configured ports are empty", () => {
  const result = runCleanup();
  assert.equal(result.status, 0);
  assert.deepEqual(result.signals, []);
});

run();
