export interface ManifestBundle {
  index: number;
  file: string;
  target: string;
  steps?: unknown[];
}

export interface BundleManifest {
  bundles: ManifestBundle[];
}

export interface SafeTransaction {
  to?: string;
  value?: string;
  data?: string;
}

export interface SafeBundle {
  transactions: SafeTransaction[];
}

export interface PackedBundle extends ManifestBundle {
  transaction_count: number;
  is_deployer_bundle: boolean | null;
  sha256: string;
}

export interface DeployBundleMetadata {
  schema: string;
  upgrade: string;
  env: string;
  protocol_version: {
    old: string[];
    new: string[];
  };
  contracts_commit: string;
  contracts_worktree_dirty: boolean;
  all_contracts_hashes_sha256: string;
  l1: {
    chain_id: number | null;
    forked_at_block: number | null;
  };
  deployer_address: string | null;
  deployer_dependent_deployments: Array<{ address: string; contract: string }>;
  zk_governance_commit: string | null;
  toolchain: {
    forge: string;
    rustc: string;
    foundry_zksync: string | null;
  };
  generated_by: { workflow_run: string; runner_os: string | null } | null;
  files: Record<string, string>;
  bundles: PackedBundle[];
}

export type TomlRecord = Record<string, unknown>;
