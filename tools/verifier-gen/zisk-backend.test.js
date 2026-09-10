/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Runs directly in Node. */

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { assertExternal, prepared } = require("./zisk-backend");

test("rejects checkout outputs, including paths through symlinks", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "zisk-cache-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, "checkout"));
  fs.writeFileSync(path.join(root, "checkout/.git"), "gitdir: elsewhere");
  fs.symlinkSync(path.join(root, "checkout"), path.join(root, "linked"));
  assert.throws(() => assertExternal(path.join(root, "checkout/cache/missing")), /outside a Git checkout/);
  assert.throws(() => assertExternal(path.join(root, "linked/cache")), /outside a Git checkout/);
  assert.doesNotThrow(() => assertExternal(path.join(root, "external/cache")));
});

test("only reuses a complete cache for the requested recipe with unchanged files", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "zisk-cache-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, "src"));
  fs.mkdirSync(path.join(root, "out/PlonkVerifier.sol"), { recursive: true });
  const artifact = path.join(root, "out/PlonkVerifier.sol/PlonkVerifier.json");
  const source = path.join(root, "src/PlonkVerifier.sol");
  fs.writeFileSync(source, "source");
  fs.writeFileSync(artifact, "artifact");
  assert.equal(prepared(root, "recipe"), false);
  const hash = (value) => createHash("sha256").update(value).digest("hex");
  fs.writeFileSync(
    path.join(root, "manifest.json"),
    JSON.stringify({ recipe: "recipe", source: hash("source"), artifact: hash("artifact") })
  );
  assert.equal(prepared(root, "recipe"), true);
  assert.equal(prepared(root, "different recipe"), false);
  fs.writeFileSync(artifact, "modified");
  assert.equal(prepared(root, "recipe"), false);
  fs.writeFileSync(artifact, "artifact");
  fs.writeFileSync(source, "modified");
  assert.equal(prepared(root, "recipe"), false);
  fs.unlinkSync(source);
  assert.equal(prepared(root, "recipe"), false);
});
