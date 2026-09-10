/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Runs directly in Node. */

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { execFileSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "../..");
const INPUTS = [
  "package.json",
  "package-lock.json",
  "render_plonk_verifier.js",
  "data/ZiSK_plonk_verification_key.json",
];
const ARTIFACT = "out/PlonkVerifier.sol/PlonkVerifier.json";
const CONFIG = `[profile.default]
src = "src"
out = "out"
solc_version = "0.8.28"
evm_version = "prague"
optimizer = true
optimizer_runs = 9999999
cbor_metadata = false
bytecode_hash = "none"
`;

function hash(data) {
  return createHash("sha256").update(data).digest("hex");
}

function assertExternal(directory) {
  let existing = path.resolve(directory);
  while (!fs.existsSync(existing)) existing = path.dirname(existing);
  for (let current = fs.realpathSync(existing); ; current = path.dirname(current)) {
    if (fs.existsSync(path.join(current, ".git"))) {
      throw new Error("ZISK_BACKEND_CACHE must be outside a Git checkout");
    }
    if (current === path.dirname(current)) break;
  }
}

function prepared(directory, recipe) {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(directory, "manifest.json"), "utf8"));
    return (
      manifest.recipe === recipe &&
      manifest.source === hash(fs.readFileSync(path.join(directory, "src/PlonkVerifier.sol"))) &&
      manifest.artifact === hash(fs.readFileSync(path.join(directory, ARTIFACT)))
    );
  } catch {
    return false;
  }
}

function run(program, args, options = {}) {
  return execFileSync(program, args, { encoding: "utf8", stdio: ["inherit", "pipe", "inherit"], ...options });
}

function backendEnvironment() {
  return Object.fromEntries(
    Object.entries(process.env).filter(([key]) => !key.startsWith("FOUNDRY_") && !key.startsWith("DAPP_"))
  );
}

function prepare() {
  const pin = fs.readFileSync(path.join(ROOT, ".github/foundry-versions.env"), "utf8");
  const version = pin.match(/^FOUNDRY_VERSION=v(.+)$/m)[1];
  const commit = pin.match(/^FOUNDRY_COMMIT=(.+)$/m)[1];
  const installed = run("forge", ["--version"]);
  if (!installed.includes(`Version: ${version}`) || !installed.includes(commit)) {
    throw new Error(`Install upstream Foundry v${version} before preparing the backend`);
  }
  const recipe = hash(
    Buffer.concat([
      Buffer.from(CONFIG + pin),
      fs.readFileSync(__filename),
      ...INPUTS.map((file) => fs.readFileSync(path.join(__dirname, file))),
    ])
  );
  const cache =
    process.env.ZISK_BACKEND_CACHE ||
    path.join(
      process.env.RUNNER_TEMP || process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache"),
      "zksync-os",
      "zisk-backend"
    );
  assertExternal(cache);
  fs.mkdirSync(cache, { recursive: true });
  const directory = path.join(fs.realpathSync(cache), recipe);
  if (prepared(directory, recipe)) return path.join(directory, ARTIFACT);
  if (fs.existsSync(directory)) {
    throw new Error(`Backend cache is incomplete or modified: ${directory}. Remove that entry and retry.`);
  }
  const staging = fs.mkdtempSync(path.join(fs.realpathSync(cache), ".prepare-"));
  try {
    for (const file of INPUTS) {
      const target = path.join(staging, file);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.copyFileSync(path.join(__dirname, file), target);
    }
    fs.mkdirSync(path.join(staging, "src"));
    fs.writeFileSync(path.join(staging, "foundry.toml"), CONFIG);
    process.stderr.write(run("npm", ["ci", "--no-audit", "--no-fund"], { cwd: staging }));
    process.stderr.write(
      run(
        process.execPath,
        ["render_plonk_verifier.js", "data/ZiSK_plonk_verification_key.json", "src/PlonkVerifier.sol"],
        { cwd: staging }
      )
    );
    process.stderr.write(run("forge", ["build", "--root", staging], { env: backendEnvironment() }));
    fs.writeFileSync(
      path.join(staging, "manifest.json"),
      JSON.stringify(
        {
          recipe,
          source: hash(fs.readFileSync(path.join(staging, "src/PlonkVerifier.sol"))),
          artifact: hash(fs.readFileSync(path.join(staging, ARTIFACT))),
        },
        null,
        2
      ) + "\n"
    );
    // Another preparation may have completed while we were building.
    if (!prepared(directory, recipe)) fs.renameSync(staging, directory);
    return path.join(directory, ARTIFACT);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = rest[0] === "--" ? rest.slice(1) : rest;
  if (!["prepare", "deploy", "test"].includes(command) || (command === "prepare" && args.length)) {
    throw new Error("Usage: node tools/verifier-gen/zisk-backend.js prepare|deploy|test [-- arguments]");
  }
  if (command === "deploy" && !args.includes("--broadcast")) {
    throw new Error("Pass --broadcast and the usual forge create RPC/signer options to deploy");
  }
  const artifact = prepare();
  if (command === "prepare") {
    console.log(artifact);
  } else if (command === "deploy") {
    const directory = path.resolve(artifact, "../../..");
    const result = JSON.parse(
      run("forge", ["create", "src/PlonkVerifier.sol:PlonkVerifier", "--root", directory, "--json", ...args], {
        cwd: directory,
        env: backendEnvironment(),
      })
    );
    if (!/^0x[0-9a-fA-F]{40}$/.test(result.deployedTo)) throw new Error("Deployment returned no contract address");
    console.log(`zisk_plonk_verifier_addr = "${result.deployedTo}"`);
  } else {
    const bytecode = JSON.parse(fs.readFileSync(artifact, "utf8")).bytecode.object;
    if (!/^0x(?:[0-9a-fA-F]{2})+$/.test(bytecode)) throw new Error("Backend artifact has no creation bytecode");
    run("yarn", ["--cwd", path.join(ROOT, "l1-contracts"), "test:foundry", ...args], {
      stdio: "inherit",
      env: {
        ...process.env,
        ZISK_PLONK_BYTECODE: bytecode,
        ZISK_REQUIRE_REAL_PROOFS: "true",
      },
    });
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error.status ? `Command failed (exit ${error.status})` : error.message);
    process.exitCode = 1;
  }
}

module.exports = { assertExternal, prepared };
