// Runs in the l1-state container: puts the sandbox's L1 state at /state/l1-state.json.gz for Anvil.
//
// The state is too large for the main branch, so it lives on the atomic-interop-demo-assets branch of
// era-contracts. It is downloaded once from a fixed commit, checked against its sha256 and kept in the
// l1-state volume. A docker/l1-state.json.gz made by generate-l1-state.sh is used instead when present.
import { createHash } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";

const ASSETS_COMMIT = "9387da85d900d9a0fac103e64580f02f134e37e9";
const URL = `https://raw.githubusercontent.com/matter-labs/era-contracts/${ASSETS_COMMIT}/l1-state.json.gz`;
const SHA256 = "e67c10858eac1e0f1b94c977ee300d93d2526ab9ef6c4af6584973b1c526b76e";
const LOCAL = "/local/l1-state.json.gz";
const OUT = "/state/l1-state.json.gz";

const sha256 = (data) => createHash("sha256").update(data).digest("hex");
const fail = (message) => {
  console.error(message);
  process.exit(1);
};

if (existsSync(LOCAL)) {
  writeFileSync(OUT, readFileSync(LOCAL));
  console.log("using docker/l1-state.json.gz");
} else if (existsSync(OUT) && sha256(readFileSync(OUT)) === SHA256) {
  console.log("L1 state already downloaded");
} else {
  console.log("downloading the L1 state (21 MB)...");
  const res = await fetch(URL).catch((e) => fail(`download failed: ${e.cause?.message ?? e.message} (${URL})`));
  if (!res.ok) fail(`download failed: ${res.status} ${res.statusText} (${URL})`);
  const data = Buffer.from(await res.arrayBuffer());
  const actual = sha256(data);
  if (actual !== SHA256) fail(`unexpected L1 state: sha256 ${actual}, expected ${SHA256}`);
  writeFileSync(`${OUT}.tmp`, data);
  renameSync(`${OUT}.tmp`, OUT);
  console.log("L1 state downloaded");
}
