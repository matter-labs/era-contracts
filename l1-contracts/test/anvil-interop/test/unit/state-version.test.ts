import * as assert from "assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { DeploymentRunner } from "../../src/deployment-runner";
import { createSuite } from "./harness";

const { test, run } = createSuite("state-version");
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "state-version-"));
const configDir = path.join(tmpRoot, "config");
fs.mkdirSync(configDir, { recursive: true });

function runnerWithVersion(stateVersion?: string): DeploymentRunner {
  fs.writeFileSync(path.join(configDir, "anvil-config.json"), JSON.stringify({ stateVersion }));
  return new DeploymentRunner(tmpRoot);
}

test("accepts a canonical snapshot version", () => {
  assert.equal(runnerWithVersion("v0.34.0").getStateVersion(), "v0.34.0");
});

test("rejects missing and path-like snapshot versions", () => {
  assert.throws(() => runnerWithVersion().getStateVersion(), /must match/);
  assert.throws(() => runnerWithVersion("../v0.34.0").getStateVersion(), /must match/);
  assert.throws(() => runnerWithVersion("v0.34").getStateVersion(), /must match/);
});

run();
fs.rmSync(tmpRoot, { recursive: true, force: true });
