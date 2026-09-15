//! Canonical prepare-phase orchestration.
//!
//! `UpgradeInner::prepare` fires `the core script's noGovernancePrepare`
//! once and `the CTM script's noGovernancePrepare` once per target CTM, all on
//! the supplied `ForgeRunner` so deployer broadcasts merge into one Safe
//! bundle.
//!
//! Real-world ecosystems also need governance-owned proxy preconditions and
//! operational admin call execution around prepare; those live in
//! [`super::upgrade_full::UpgradeFull`], which composes this.
//!
//! The governance phase is not on this struct — it's a free helper in
//! [`super::upgrade`] because it has no state of its own (just file IO + ABI
//! passthrough).

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use alloy::primitives::{Address, Bytes, B256};
use alloy::sol_types::SolCall;
use anyhow::Context;

// Every script generation exposes the same entry points (`noGovernancePrepare(CoreUpgradeParams)` /
// `(CTMUpgradeParams)`), so this one driver serves them all; which one actually runs is decided by
// the `--core-script-path` / `--ctm-script-path` inputs.
use crate::common::abi::{ICTMUpgradeV31Abi, IComposeUpgradeOperationAbi, ICoreUpgradeV31Abi};
use crate::common::wallets::Wallet;
use crate::common::{forge::ForgeRunner, logger};

// ── inputs / outputs ───────────────────────────────────────────────────────

/// Per-CTM inputs. One entry per `--ctm-proxy` (or per `[[ctm]]` row in a
/// `--ctm-config` TOML).
pub struct CtmInputs {
    /// CTM proxy address.
    pub proxy: Address,
    /// Override for the rollup DA manager address; when `None`, prepare_ctm resolves it from a
    /// chain registered on the CTM. Unlike the bytecodes supplier — which the prepare script
    /// reads off the CTM's own `L1_BYTECODES_SUPPLIER()` immutable, so nothing transports it —
    /// no CTM-level getter exposes the DA manager.
    pub rollup_da_manager: Option<Address>,
}

/// Inputs to the prepare phase. The CLI handler builds this from clap args.
pub struct PrepareInputs {
    /// CLI-compatible collection; the prepare boundary requires exactly one CTM.
    pub ctms: Vec<CtmInputs>,
    /// Optional CREATE2 salt for the Core prepare; random if `None`.
    pub create2_factory_salt: Option<B256>,
    /// Optional per-CTM CREATE2 salts. Keyed by CTM proxy address. Each CTM
    /// prepare must use a distinct salt because the contracts it deploys
    /// (notably `GovernanceUpgradeTimer`) have env-wide identical constructor
    /// args — same salt + same factory + same init code → same address →
    /// gov-replay's second `startTimer()` would revert. Supplied via the
    /// `[create2_factory_salts]` table in `upgrade-envs/<release-env-dir>/
    /// <env>.toml`; missing entries fall back to a random salt (legacy
    /// local-fixture path).
    pub create2_factory_salt_per_ctm: Option<HashMap<Address, B256>>,
    /// Upgrade config TOML path relative to `l1-contracts/`.
    pub upgrade_input_path: String,
    /// Output TOML path for the core forge call (relative to l1-contracts/).
    pub core_output_path: String,
    /// Core upgrade script path (relative to `l1-contracts/`).
    pub core_script_path: String,
    /// CTM upgrade script path (relative to `l1-contracts/`).
    pub ctm_script_path: String,
    /// Compose script path (relative to `l1-contracts/`): deploys the operation over every CTM
    /// prepare's transition and emits the coordinator's stage calls. Skipped for a bootstrap
    /// edge, whose prepares emit no transition.
    pub compose_script_path: String,
    /// ZK token asset ID used by CTM prepare. For named envs this comes from
    /// `upgrade-envs/permanent-values/<env>.toml`; otherwise it is explicitly
    /// supplied or falls back only for networks with a canonical value.
    pub zk_token_asset_id: B256,
    /// Whether the CTM's verifier is the testnet one, which accepts unproven batches. Declared per
    /// environment in `permanent-values/<env>.toml`; passed through rather than read in Solidity,
    /// because only the testnet verifiers expose `IS_TESTNET_VERIFIER` and probing for it would need
    /// a try/catch the contracts forbid.
    pub testnet_verifier: bool,
}

/// Output of the prepare phase: the TOMLs each forge invocation wrote, in
/// the order the governance phase should replay them (core first, then per
/// CTM in input order, then the optional new-Gateway bring-up bundle).
pub struct PrepareOutput {
    pub core_toml: PathBuf,
    pub ctm_tomls: Vec<CtmPrepareEntry>,
    /// The compose step's output — the `EcosystemUpgradeOperation` and the coordinator's three
    /// stage calls — or `None` for a bootstrap edge (no transition to compose over).
    pub operation_toml: Option<PathBuf>,
    /// Empty when the env's `[new_gateway]` block isn't set. When present,
    /// each entry points at one `GatewayVotePreparation` output TOML (one
    /// per CTM deployed on the gateway); the merge logic in
    /// `upgrade::write_merged_ecosystem_toml` decodes
    /// `governance_calls_to_execute` from each and appends to stage 2.
    pub new_gateway_tomls: Vec<PathBuf>,
}

/// Per-CTM prepare result: where the script wrote its TOML. `prepare` rejects
/// anything that is not a ZKsync OS CTM, so the merged ecosystem TOML labels
/// every section `[ctms.zksync_os]`.
pub struct CtmPrepareEntry {
    pub proxy: Address,
    pub toml: PathBuf,
}

// ── struct ────────────────────────────────────────────────────────────────

pub struct UpgradeInner<'a> {
    contracts_path: &'a Path,
    bridgehub: Address,
}

impl<'a> UpgradeInner<'a> {
    pub fn new(contracts_path: &'a Path, bridgehub: Address) -> Self {
        Self {
            contracts_path,
            bridgehub,
        }
    }

    pub fn bridgehub(&self) -> Address {
        self.bridgehub
    }

    /// Run `the core script's noGovernancePrepare` then
    /// `the CTM script's noGovernancePrepare` for the selected CTM, all on the
    /// supplied runner. Returns the per-step output TOML paths.
    ///
    /// `pub(super)` so production callers must go through
    /// [`super::upgrade_full::UpgradeFull::prepare`] — that wrapper
    /// runs the governance-owned proxy precondition first and executes
    /// operational admin calls afterwards.
    pub(super) async fn prepare(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &PrepareInputs,
        ctm: &CtmInputs,
    ) -> anyhow::Result<PrepareOutput> {
        crate::common::l1_contracts::ensure_supported_os_ctm(&runner.rpc_url, ctm.proxy)
            .await
            .with_context(|| format!("Unsupported upgrade target ({:#x})", ctm.proxy))?;

        let core_toml = self
            .prepare_core(runner, deployer, inputs)
            .await
            .context("core prepare")?;

        let path = self
            .prepare_ctm(runner, deployer, inputs, ctm)
            .await
            .with_context(|| format!("ctm prepare ({:#x})", ctm.proxy))?;
        let ctm_entry = CtmPrepareEntry {
            proxy: ctm.proxy,
            toml: path,
        };

        let operation_toml = self
            .compose_operation(runner, deployer, inputs, &core_toml, &ctm_entry)
            .await
            .context("compose operation")?;

        Ok(PrepareOutput {
            core_toml,
            ctm_tomls: vec![ctm_entry],
            operation_toml,
            new_gateway_tomls: Vec::new(),
        })
    }

    /// Compose the one CTM transition and optional core change into an operation.
    /// Bootstrap prepares emit no transition and retain their explicit handover flow.
    async fn compose_operation(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &PrepareInputs,
        core_toml: &Path,
        ctm: &CtmPrepareEntry,
    ) -> anyhow::Result<Option<PathBuf>> {
        let transition = read_ctm_transition(&ctm.toml)?;
        if transition.is_zero() {
            logger::info(
                "no transition to compose over (bootstrap edge): skipping the compose step",
            );
            return Ok(None);
        }
        ensure_script_exists(self.contracts_path, &inputs.compose_script_path)?;

        let coordinator = read_ecosystem_upgrade_executor(core_toml)?;
        let core_registry = read_core_registry(core_toml)?;
        logger::info(format!(
            "Composing the operation on coordinator {coordinator:#x}: core registry {core_registry:#x}, transition {transition:#x}"
        ));

        let output_path_str = "/script-out/upgrade-operation.toml".to_string();
        let output_path = self
            .contracts_path
            .join(output_path_str.trim_start_matches('/'));
        let _ = fs::remove_file(&output_path);

        let script = runner
            .script_path_from_root(
                self.contracts_path,
                Path::new(inputs.compose_script_path.trim_start_matches('/')),
            )
            .with_calldata(&Bytes::from(
                IComposeUpgradeOperationAbi::composeCall {
                    _params: IComposeUpgradeOperationAbi::ComposeOperationParams {
                        coordinator,
                        coreRegistry: core_registry,
                        transition,
                        // The operation's init code is unique to its transition, so the core salt
                        // cannot collide with the prepares' deployments.
                        create2FactorySalt: inputs
                            .create2_factory_salt
                            .unwrap_or_else(|| B256::from(rand::random::<[u8; 32]>())),
                        outputPath: output_path_str,
                    },
                }
                .abi_encode(),
            ))
            .with_broadcast()
            .with_ffi()
            .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
            .with_offline()
            .with_wallet(deployer);

        logger::step("Running the compose step");
        runner
            .run(script)
            .context("Failed to execute the compose script")?;

        Ok(Some(output_path))
    }

    async fn prepare_core(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &PrepareInputs,
    ) -> anyhow::Result<PathBuf> {
        ensure_script_exists(self.contracts_path, &inputs.core_script_path)?;

        let upgrade_input = self
            .contracts_path
            .join(inputs.upgrade_input_path.trim_start_matches('/'));
        if !upgrade_input.exists() {
            anyhow::bail!("Upgrade input file not found: {}", upgrade_input.display());
        }

        let core_output_path = self
            .contracts_path
            .join(inputs.core_output_path.trim_start_matches('/'));
        let _ = fs::remove_file(&core_output_path);

        let create2_salt = inputs
            .create2_factory_salt
            .unwrap_or_else(|| B256::from(rand::random::<[u8; 32]>()));

        let script = runner
            .script_path_from_root(
                self.contracts_path,
                Path::new(inputs.core_script_path.trim_start_matches('/')),
            )
            .with_calldata(&Bytes::from(
                ICoreUpgradeV31Abi::noGovernancePrepareCall {
                    _params: ICoreUpgradeV31Abi::CoreUpgradeParams {
                        bridgehubProxyAddress: self.bridgehub,
                        create2FactorySalt: create2_salt,
                        upgradeInputPath: inputs.upgrade_input_path.clone(),
                        outputPath: inputs.core_output_path.clone(),
                    },
                }
                .abi_encode(),
            ))
            .with_broadcast()
            .with_ffi()
            .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
            .with_offline()
            .with_wallet(deployer);

        logger::step("Running core prepare");
        runner
            .run(script)
            .context("Failed to execute the core script's noGovernancePrepare")?;

        Ok(core_output_path)
    }

    async fn prepare_ctm(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &PrepareInputs,
        ctm: &CtmInputs,
    ) -> anyhow::Result<PathBuf> {
        ensure_script_exists(self.contracts_path, &inputs.ctm_script_path)?;

        let ctm_proxy = ctm.proxy;

        // Find a chain on this CTM as a witness for rollup-DA-manager auto-
        // resolution.
        let chain_ids =
            crate::common::l1_contracts::resolve_all_chain_ids(&runner.rpc_url, self.bridgehub)
                .await
                .context("Failed to query registered chain IDs from bridgehub")?;
        let mut representative_chain: Option<u64> = None;
        for &cid in &chain_ids {
            let chain_ctm = crate::common::l1_contracts::resolve_ctm_proxy(
                &runner.rpc_url,
                self.bridgehub,
                cid,
            )
            .await
            .with_context(|| format!("resolving CTM for chain {cid}"))?;
            if chain_ctm == ctm_proxy {
                representative_chain = Some(cid);
                break;
            }
        }
        let representative_chain = representative_chain.with_context(|| {
            format!(
                "No registered chain uses CTM {ctm_proxy:#x}. Auto-resolution of \
                 rollup DA manager requires at least one registered chain on the \
                 target CTM."
            )
        })?;
        logger::info(format!(
            "CTM proxy: {ctm_proxy:#x} (representative chain {representative_chain})"
        ));

        let rollup_da_manager = match ctm.rollup_da_manager {
            Some(addr) => {
                logger::info(format!("RollupDAManager (override): {addr:#x}"));
                addr
            }
            None => {
                let zk_chain = crate::common::l1_contracts::resolve_zk_chain(
                    &runner.rpc_url,
                    self.bridgehub,
                    representative_chain,
                )
                .await
                .context("Failed to resolve ZK chain diamond proxy from bridgehub")?;
                let resolved = crate::common::l1_contracts::resolve_rollup_da_manager(
                    &runner.rpc_url,
                    zk_chain,
                )
                .await
                .context("Failed to auto-resolve RollupDAManager from ZK chain")?;
                logger::info(format!(
                    "RollupDAManager (auto-resolved via chain {representative_chain}): \
                     {resolved:#x}"
                ));
                resolved
            }
        };

        let governance =
            crate::common::l1_contracts::resolve_governance(&runner.rpc_url, self.bridgehub)
                .await
                .context("Failed to auto-resolve governance address from bridgehub")?;
        logger::info(format!("Governance (auto-resolved): {governance:#x}"));

        let chain_registration_sender = read_chain_registration_sender_proxy(
            &self
                .contracts_path
                .join(inputs.core_output_path.trim_start_matches('/')),
        )?;
        logger::info(format!(
            "ChainRegistrationSender (core prepare): {chain_registration_sender:#x}"
        ));
        let ecosystem_upgrade_executor = read_ecosystem_upgrade_executor(
            &self
                .contracts_path
                .join(inputs.core_output_path.trim_start_matches('/')),
        )?;
        logger::info(format!(
            "EcosystemUpgradeExecutor (core prepare): {ecosystem_upgrade_executor:#x}"
        ));
        // Only the bootstrap edge reads it: its call sequence covers both domains, so the object
        // describing that sequence needs the ecosystem inventory alongside the edge.
        let core_registry = read_core_registry(
            &self
                .contracts_path
                .join(inputs.core_output_path.trim_start_matches('/')),
        )?;
        logger::info(format!("CoreRegistry (core prepare): {core_registry:#x}"));
        // Per-CTM CREATE2 salt. Each CTM prepare deploys a few contracts whose
        // constructor args are env-wide constants — notably
        // `GovernanceUpgradeTimer(initialDelay, 2 weeks, ownerAddress,
        // ecosystemAdminAddress)` — so two CTMs prepared in one ecosystem would
        // land them at the same address without per-CTM differentiation, and the
        // downstream gov-replay's second `startTimer()` on that contract would
        // revert. Named environments keep CREATE2 salts keyed by registered CTM
        // (`upgrade-envs/v0.34.0-registry/<env>.toml [create2_salts.per_ctm]`);
        // legacy local fixtures fall back to a fresh random salt.
        let create2_salt = inputs
            .create2_factory_salt_per_ctm
            .as_ref()
            .and_then(|m| m.get(&ctm_proxy).copied())
            .unwrap_or_else(|| B256::from(rand::random::<[u8; 32]>()));
        logger::info(format!(
            "Per-CTM create2 salt: {create2_salt:#x} (ctm={ctm_proxy:#x})"
        ));

        // Per-CTM output path so back-to-back prepares don't clobber each other.
        let output_path_str = format!("/script-out/upgrade-ctm-{ctm_proxy:#x}.toml");
        let ctm_output_path = self
            .contracts_path
            .join(output_path_str.trim_start_matches('/'));
        let _ = fs::remove_file(&ctm_output_path);

        let script = runner
            .script_path_from_root(
                self.contracts_path,
                Path::new(inputs.ctm_script_path.trim_start_matches('/')),
            )
            .with_calldata(&Bytes::from(
                ICTMUpgradeV31Abi::noGovernancePrepareCall {
                    _params: ICTMUpgradeV31Abi::CTMUpgradeParams {
                        ctmProxy: ctm_proxy,
                        rollupDAManager: rollup_da_manager,
                        create2FactorySalt: create2_salt,
                        upgradeInputPath: inputs.upgrade_input_path.clone(),
                        outputPath: output_path_str.clone(),
                        governance,
                        chainRegistrationSender: chain_registration_sender,
                        zkTokenAssetId: inputs.zk_token_asset_id,
                        testnetVerifier: inputs.testnet_verifier,
                        ecosystemUpgradeExecutor: ecosystem_upgrade_executor,
                        coreRegistry: core_registry,
                    },
                }
                .abi_encode(),
            ))
            .with_broadcast()
            .with_ffi()
            .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
            .with_offline()
            .with_wallet(deployer);

        logger::step(format!("Running CTM prepare for {ctm_proxy:#x}"));
        runner
            .run(script)
            .context("Failed to execute the CTM script's noGovernancePrepare")?;

        // Simulation probes are generated independently from production prepare. Preserve the
        // existing package fields consumed by the merger and simulator, without broadcasting
        // either probe or coupling their construction to a version-specific prepare script.
        let simulation = runner
            .script_path_from_root(
                self.contracts_path,
                Path::new("deploy-scripts/simulation/UpgradeSimulation.s.sol"),
            )
            .with_env("UPGRADE_SIMULATION_CTM", format!("{ctm_proxy:#x}"))
            .with_env(
                "UPGRADE_SIMULATION_OUTPUT",
                ctm_output_path.to_string_lossy().into_owned(),
            )
            .with_offline()
            .with_wallet(deployer);
        runner
            .run(simulation)
            .context("Failed to generate chain upgrade/creation simulator probes")?;

        Ok(ctm_output_path)
    }
}

fn read_chain_registration_sender_proxy(core_toml: &Path) -> anyhow::Result<Address> {
    let raw =
        fs::read_to_string(core_toml).with_context(|| format!("read {}", core_toml.display()))?;
    let top: toml::Value =
        toml::from_str(&raw).with_context(|| format!("parse {}", core_toml.display()))?;
    let value = top
        .get("upgrade_addresses")
        .and_then(|v| v.get("bridgehub"))
        .and_then(|v| v.get("chain_registration_sender_proxy_addr"))
        .and_then(|v| v.as_str())
        .with_context(|| {
            format!(
                "missing upgrade_addresses.bridgehub.chain_registration_sender_proxy_addr in {}",
                core_toml.display()
            )
        })?;

    value.parse().with_context(|| {
        format!(
            "chain_registration_sender_proxy_addr in {} is not a valid address: {}",
            core_toml.display(),
            value,
        )
    })
}

/// The `[registry].core_registry_addr` the core prepare wrote — the ecosystem leg the operation
/// names. Zero when the core prepare deployed no ecosystem implementation (the upgrade then has
/// no ecosystem leg).
fn read_core_registry(core_toml: &Path) -> anyhow::Result<Address> {
    let raw =
        fs::read_to_string(core_toml).with_context(|| format!("read {}", core_toml.display()))?;
    let top: toml::Value =
        toml::from_str(&raw).with_context(|| format!("parse {}", core_toml.display()))?;
    let value = top
        .get("registry")
        .and_then(|v| v.get("core_registry_addr"))
        .and_then(|v| v.as_str())
        .with_context(|| {
            format!(
                "missing registry.core_registry_addr in {}",
                core_toml.display()
            )
        })?;
    value.parse().with_context(|| {
        format!(
            "core_registry_addr in {} is not a valid address: {}",
            core_toml.display(),
            value,
        )
    })
}

/// Read the transition of a CTM prepare. The coordinator already binds its executor on-chain.
fn read_ctm_transition(ctm_toml: &Path) -> anyhow::Result<Address> {
    let raw =
        fs::read_to_string(ctm_toml).with_context(|| format!("read {}", ctm_toml.display()))?;
    let top: toml::Value =
        toml::from_str(&raw).with_context(|| format!("parse {}", ctm_toml.display()))?;
    top.get("registry")
        .and_then(|v| v.get("ctm_transition_addr"))
        .and_then(|v| v.as_str())
        .with_context(|| {
            format!(
                "missing registry.ctm_transition_addr in {}",
                ctm_toml.display()
            )
        })?
        .parse()
        .with_context(|| {
            format!(
                "invalid registry.ctm_transition_addr in {}",
                ctm_toml.display()
            )
        })
}

/// The `[registry].ecosystem_upgrade_executor_addr` the core prepare wrote — the coordinator
/// (`EcosystemUpgradeExecutor`) the CTM prepare's executor and timers answer to, and the target
/// of the compose step's stage calls.
fn read_ecosystem_upgrade_executor(core_toml: &Path) -> anyhow::Result<Address> {
    let raw =
        fs::read_to_string(core_toml).with_context(|| format!("read {}", core_toml.display()))?;
    let top: toml::Value =
        toml::from_str(&raw).with_context(|| format!("parse {}", core_toml.display()))?;
    let value = top
        .get("registry")
        .and_then(|v| v.get("ecosystem_upgrade_executor_addr"))
        .and_then(|v| v.as_str())
        .with_context(|| {
            format!(
                "missing registry.ecosystem_upgrade_executor_addr in {}",
                core_toml.display()
            )
        })?;

    value.parse().with_context(|| {
        format!(
            "ecosystem_upgrade_executor_addr in {} is not a valid address: {}",
            core_toml.display(),
            value,
        )
    })
}

fn ensure_script_exists(contracts_path: &Path, script_path: &str) -> anyhow::Result<()> {
    let script_file_path = script_path
        .trim_start_matches('/')
        .split(':')
        .next()
        .unwrap_or(script_path);
    let script_full_path = contracts_path.join(script_file_path);
    if !script_full_path.exists() {
        anyhow::bail!("Script not found: {}", script_full_path.display());
    }
    Ok(())
}
