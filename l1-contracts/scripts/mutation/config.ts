// Settings for `yarn l1 mutation` (docs/mutation-testing.md).

export const PROFILE = "mutation";
// `--operators statement` keeps forge's require, delete-expression and assignment mutators.
export const STATEMENT_EXCLUDED_OPERATORS = ["assembly", "binary-op", "elim-delegate", "unary-op"];

export const EXCEPTIONS_FILE = "mutation-exceptions.json";
// Under `cache/` so it is ignored; tests resolve `<project>/../configs`, so it also holds that sibling.
export const WORK_DIR = "cache/mutation-work";

// Declarations, generated code, test helpers and the Gateway are not mutated.
export const TARGET_EXCLUDES: RegExp[] = [
  /^contracts\/dev-contracts\//,
  /^contracts\/script-interfaces\//,
  /^contracts\/vendor\//,
  /\/(interfaces|chain-interfaces)\//,
  /\/I[A-Z]\w*\.sol$/,
  /Errors\.sol$/,
  /^contracts\/common\/Config\.sol$/,
  /^contracts\/state-transition\/verifiers\/(ZKsyncOSVerifierPlonk|ZiskVerifier)\.sol$/,
  /Gateway/,
];

// Suites that cannot run in forge's mutant workspaces.
export const TEST_EXCLUDES: string[] = [
  "test/foundry/l1/integration/", // ffi: blake2s via node and `cast selectors`
  "test/foundry/l1/invariant/", // ffi in setup; a campaign per mutant also dominates the run time
  "test/foundry/l1/unit/concrete/upgrades/", // ffi
  "test/foundry/l1/unit/concrete/Upgrades/", // ffi
  "test/foundry/l1/unit/concrete/deploy-scripts/", // ffi
  "test/foundry/l1/unit/concrete/GatewayCTMDeployer/", // reads `<project>/../l1-contracts/out`
];

// Narrow test sets for contracts whose tests are not named after them.
export const NARROW_TEST_OVERRIDES: Record<string, string[]> = {
  "contracts/state-transition/chain-deps/facets/Executor.sol": ["test/foundry/l1/unit/concrete/BatchProcessing/"],
  "contracts/state-transition/chain-deps/facets/Committer.sol": ["test/foundry/l1/unit/concrete/BatchProcessing/"],
};

// Copied into each re-check workspace; `lib` is linked instead.
export const WORKSPACE_DIRS = ["contracts", "test", "deploy-scripts", "upgrade-envs", "script-config"];
export const WORKSPACE_FILES = ["foundry.toml", "remappings.txt", ".env"];

// Peak RSS of one unoptimized compile grows ~4 MB per source: 0.17 GB for 27 sources, 2.5 GB for 632.
export const MB_PER_SOURCE = 4;
export const MIN_WORKER_MB = 256;
export const RESERVE_MB = 3072;
export const MEMORY_HEADROOM = 1.3;

export const DEFAULT_MUTANT_TIMEOUT_S = 300;
