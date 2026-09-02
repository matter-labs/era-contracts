export const DEPLOY_BUNDLE_SCHEMA = "zksync-ecosystem-upgrade-deploy-bundle/1";
export const V31_UPGRADE_NAME = "v0.31.0-interopB";

export const ENV_ANVIL_PORTS: Readonly<Record<string, number>> = {
  stage: 29_545,
  testnet: 29_547,
  mainnet: 29_549,
};
export const REPLAY_PORT_OFFSET = 1;

export const ANVIL_GAS_PRICE_WEI = 1_000_000_000;
export const ANVIL_BALANCE_HEX = "0x21e19e0c9bab2400000";
export const BUNDLE_TARGET_TOKEN_FUNDING_WEI = "1000000000000000000000000000000";
export const ANVIL_READY_ATTEMPTS = 30;
export const ANVIL_READY_DELAY_MS = 1_000;
export const ANVIL_STOP_TIMEOUT_MS = 5_000;
export const PROTOCOL_OPS_MEMORY_LIMIT = 536_870_912;

export const DEFAULT_GATEWAY_RPC_URL = "https://zksync-os-stage-gateway.zksync.dev";
export const DEFAULT_ZK_GOVERNANCE_COMMIT = "cc7c76d";

export const CANONICAL_DEFAULT_ACCOUNT_HASH = "0x010005f9d84c1863bf21a9393f2fd1631af92aab68f12c35dba580c8d7a06146";
export const CANONICAL_DEFAULT_ACCOUNT_EXECUTABLE_SHA256 =
  "28c736311a2f872a0b8ff289b0ae35266f1ccd402885435fd9ffd2a154a39a96";
export const CANONICAL_DEFAULT_ACCOUNT_METADATA_WORD =
  "3ad06056e66b778b11945dd3cf11269b479679b45850c25af96c8ca9f309acb0";
export const DEFAULT_ACCOUNT_METADATA_WORD_BYTES = 32;
export const ERAVM_BYTECODE_WORD_BYTES = 32;
export const ERAVM_HASH_VERSION = 1;
export const ERAVM_HASH_VERSION_OFFSET = 0;
export const ERAVM_HASH_RESERVED_OFFSET = 1;
export const ERAVM_HASH_LENGTH_OFFSET = 2;
export const MAX_ERAVM_BYTECODE_WORDS = 0xffff;

export const HEX_PREFIX_CHARACTERS = 2;
export const HEX_CHARACTERS_PER_BYTE = 2;
export const CREATE2_SALT_BYTES = 32;
export const FUNCTION_SELECTOR_BYTES = 4;
export const SIGINT_EXIT_CODE = 130;
export const SIGTERM_EXIT_CODE = 143;

export const SUPPORTING_BUNDLE_FILES = [
  "prepare/manifest.json",
  "ecosystem.toml",
  "extra-verification-logs.txt",
  "gw-verification-logs.txt",
] as const;

export const REQUIRED_SUPPORTING_BUNDLE_FILES = ["prepare/manifest.json", "ecosystem.toml"] as const;
