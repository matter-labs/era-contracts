import * as assert from "assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { compareStateDirectories } from "../../compare-chain-states";
import { createSuite } from "./harness";

const { test, run } = createSuite("compare-chain-states");
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "compare-chain-states-"));
const DIAMOND = "0x00000000000000000000000000000000000000d1";
const OTHER = "0x00000000000000000000000000000000000000e1";
const word = (value: bigint | number) => `0x${BigInt(value).toString(16).padStart(64, "0")}`;

type Storage = Record<string, string>;

function writeFixture(root: string, version: string, diamondStorage: Storage, otherStorage: Storage = {}): void {
  const dir = path.join(root, version);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(
    path.join(dir, "addresses.json"),
    JSON.stringify({ chainAddresses: [{ chainId: 10, diamondProxy: DIAMOND }] })
  );
  fs.writeFileSync(
    path.join(dir, "31337.json"),
    JSON.stringify({
      accounts: {
        [DIAMOND]: { storage: diamondStorage },
        [OTHER]: { storage: otherStorage },
      },
    })
  );
}

function fixturePair(committedStorage: Storage, generatedStorage: Storage): [string, string] {
  const root = fs.mkdtempSync(path.join(tmpRoot, "case-"));
  const committed = path.join(root, "committed");
  const generated = path.join(root, "generated");
  writeFixture(committed, "v0.34.0", committedStorage);
  writeFixture(generated, "v0.34.0", generatedStorage);
  return [committed, generated];
}

test("rejects a generated-only fixture version", () => {
  const [committed, generated] = fixturePair({}, {});
  writeFixture(generated, "v0.35.0", {});
  assert.deepEqual(compareStateDirectories(committed, generated), ["Missing version directory in committed: v0.35.0"]);
});

test("rejects a committed-only fixture version", () => {
  const [committed, generated] = fixturePair({}, {});
  writeFixture(committed, "v0.33.0", {});
  assert.deepEqual(compareStateDirectories(committed, generated), ["Missing version directory in generated: v0.33.0"]);
});

test("compares fixed diamond state, including explicit zero writes", () => {
  const [committed, generated] = fixturePair({ [word(33)]: word(32), [word(58)]: word(0) }, { [word(33)]: word(33) });
  const diffs = compareStateDirectories(committed, generated).join("\n");
  assert.match(diffs, /storage differs in 2 slot\(s\)/);
  assert.match(diffs, new RegExp(`slot ${word(33)}`));
  assert.match(diffs, new RegExp(`slot ${word(58)}`));
});

test("ignores only the diamond's volatile timestamp and dynamic priority-tree state", () => {
  const dynamicSlot = word(10_000);
  const fixedShape = { [word(54)]: word(3), [word(55)]: word(3), [word(56)]: word(3) };
  const [committed, generated] = fixturePair(
    { ...fixedShape, [word(67)]: word(76), [dynamicSlot]: word(1) },
    { ...fixedShape, [word(67)]: word(88), [dynamicSlot]: word(2) }
  );
  assert.deepEqual(compareStateDirectories(committed, generated), []);
});

test("compares diamond tree shape and facet membership", () => {
  const facetsLength = BigInt("0xc8fcad8db84d3cc18b4c41d551ea0ee66dd599cde068d998e57d5e09332c131d");
  const facetsStart = BigInt("0xc0d727610ea16241eff4447d08bb1b4595f7d2ec4515282437a13b7d0df4b922");
  const [committed, generated] = fixturePair(
    { [word(54)]: word(3), [word(facetsLength)]: word(1), [word(facetsStart)]: word(1) },
    { [word(54)]: word(4), [word(facetsLength)]: word(1), [word(facetsStart)]: word(2) }
  );
  assert.match(compareStateDirectories(committed, generated).join("\n"), /storage differs in 2 slot\(s\)/);
});

test("continues comparing arbitrary storage on non-diamond accounts", () => {
  const root = fs.mkdtempSync(path.join(tmpRoot, "case-"));
  const committed = path.join(root, "committed");
  const generated = path.join(root, "generated");
  writeFixture(committed, "v0.34.0", {}, { [word(10_000)]: word(1) });
  writeFixture(generated, "v0.34.0", {}, { [word(10_000)]: word(2) });
  assert.match(compareStateDirectories(committed, generated).join("\n"), new RegExp(OTHER));
});

run();
fs.rmSync(tmpRoot, { recursive: true, force: true });
