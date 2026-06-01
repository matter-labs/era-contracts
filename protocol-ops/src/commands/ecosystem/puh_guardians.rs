//! PUH/Guardians redeploy helper, called as part of
//! `ecosystem upgrade-prepare-all`.
//!
//! Runs `DeployPUHAndGuardians.s.sol` from the sibling `zk-governance`
//! checkout (default `../../zk-governance`, foundry root with `foundry.toml`
//! at the top level) on the same anvil fork as the core/CTM prepares,
//! and returns the two PUH proposal calls that wire the new contracts into
//! the existing PUH proxy:
//!
//!   1. `ProxyAdmin.upgrade(puhProxy, newPuhImpl)` — swap the impl
//!   2. `PUH.updateGuardians(newGuardians)` — point at the new Guardians
//!
//! These land in **stage 0** so the new PUH + Guardians are wired before the
//! v31 ecosystem proxy upgrades execute.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use ethers::abi::{encode as abi_encode, Token};
use ethers::providers::{Http, Middleware, Provider};
use ethers::types::{Address, H256, U256};
use ethers::utils::keccak256;
use serde::Deserialize;

use crate::common::env_config::EnvConfig;
use crate::common::forge::ForgeRunner;
use crate::common::governance_calls::GovernanceCall;
use crate::common::l1_contracts::resolve_governance;
use crate::common::logger;
use crate::common::wallets::Wallet;

/// EIP-1967 admin slot: keccak256("eip1967.proxy.admin") - 1
const EIP1967_ADMIN_SLOT: H256 = H256([
    0xb5, 0x31, 0x27, 0x68, 0x4a, 0x56, 0x8b, 0x31, 0x73, 0xae, 0x13, 0xb9, 0xf8, 0xa6, 0x01, 0x6e,
    0x24, 0x3e, 0x63, 0xb6, 0xe8, 0xee, 0x11, 0x78, 0xd6, 0xa7, 0x17, 0x85, 0x0b, 0x5d, 0x61, 0x03,
]);

/// `OpenZeppelin.ProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy,address,bytes)`
/// selector (OZ v5). Stage's PUH ProxyAdmin only exposes the v5 form — the
/// v4 `upgrade(address,address)` selector (0x99a88ec4) is absent and reverts
/// on dispatch. We pass empty bytes for the post-upgrade call (no init-style
/// hook needed for the impl swap).
const PROXY_ADMIN_UPGRADE_AND_CALL_SELECTOR: [u8; 4] = [0x96, 0x23, 0x60, 0x9d];
/// `ProtocolUpgradeHandler.updateSecurityCouncil(address)` selector.
const PUH_UPDATE_SECURITY_COUNCIL_SELECTOR: [u8; 4] = [0xdb, 0xfe, 0x3e, 0x96];
/// `ProtocolUpgradeHandler.updateGuardians(address)` selector.
const PUH_UPDATE_GUARDIANS_SELECTOR: [u8; 4] = [0x69, 0x16, 0x16, 0xc5];
/// `ProtocolUpgradeHandler.updateEmergencyUpgradeBoard(address)` selector.
const PUH_UPDATE_EMERGENCY_BOARD_SELECTOR: [u8; 4] = [0x7a, 0xed, 0xf3, 0x37];
/// `bridgehub.chainAssetHandler()` selector.
const BRIDGEHUB_CHAIN_ASSET_HANDLER_SELECTOR: [u8; 4] = [0x70, 0xd8, 0xaf, 0x87];

/// Default well-known CREATE2 deployer (Arachnid). Deployed on Sepolia + mainnet.
const DEFAULT_CREATE2_FACTORY: &str = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
/// Default forge script (relative to the zk-governance foundry root).
const DEFAULT_SCRIPT_PATH: &str = "scripts/DeployPUHAndGuardians.s.sol:DeployPUHAndGuardians";
/// Default seed for the single CREATE2 salt shared by the whole redeployed
/// governance set (PUH impl, Guardians, SecurityCouncil, EmergencyUpgradeBoard).
/// Each contract has distinct init code, so one salt is collision-free and
/// rotates the set as a group. Override via `gov_salt_override`.
const GOV_SALT_SEED: &[u8] = b"v31:gov";
/// Default sibling checkout path for zk-governance.
pub const DEFAULT_ZK_GOV_DIR: &str = "../../zk-governance";

/// Inputs for the PUH/Guardians redeploy step. Most fields default — callers
/// (`ecosystem upgrade-prepare-all`) should pass `env` for the auto-fills and
/// can leave salts/script overrides at defaults.
pub struct PuhGuardiansInputs<'a> {
    pub env: Option<&'a EnvConfig>,
    pub bridgehub: Address,
    /// Forge script: contract address overrides. `None` = on-chain auto-resolve.
    pub chain_asset_handler_override: Option<Address>,
    pub create2_factory_override: Option<Address>,
    /// CREATE2 salt shared by all four redeployed contracts. `None` =
    /// `keccak256(GOV_SALT_SEED)`. Rotate this to move the whole set.
    pub gov_salt_override: Option<H256>,
    pub zk_governance_dir: PathBuf,
    /// ZKsync OS ChainTypeManager proxy address. Required by
    /// `DeployPUHAndGuardians.s.sol` — the old PUH has no getter for this.
    pub zksync_os_ctm: Option<Address>,
    /// When true, deploy `TestnetProtocolUpgradeHandler` (zeroed legal-veto /
    /// upgrade-delay periods) instead of the real `ProtocolUpgradeHandler`.
    /// Defaults to `!env.is_mainnet()` — stage/testnet get the testnet handler,
    /// mainnet gets the real one — mirroring the per-CTM `is_testnet` rule.
    pub use_testnet_puh: bool,
}

impl<'a> PuhGuardiansInputs<'a> {
    pub fn from_env(env: Option<&'a EnvConfig>, bridgehub: Address) -> Self {
        // Mainnet keeps the full timelock; every other ecosystem (stage /
        // testnet / local) gets the zeroed-delay testnet handler.
        let use_testnet_puh = env.map(|c| !c.is_mainnet()).unwrap_or(false);
        Self {
            env,
            bridgehub,
            chain_asset_handler_override: None,
            create2_factory_override: None,
            gov_salt_override: None,
            zk_governance_dir: PathBuf::from(DEFAULT_ZK_GOV_DIR),
            zksync_os_ctm: None,
            use_testnet_puh,
        }
    }
}

/// Outcome of the redeploy: the two governance calls to add to stage 0, plus
/// addresses surfaced for diagnostics / output payloads.
#[derive(Debug)]
pub struct PuhGuardiansOutcome {
    pub stage0_calls: Vec<GovernanceCall>,
    pub puh_proxy: Address,
    pub proxy_admin: Address,
    pub new_puh_impl: Address,
    pub new_guardians: Address,
    pub new_security_council: Address,
    pub new_emergency_upgrade_board: Address,
}

/// Run `DeployPUHAndGuardians.s.sol` against the supplied runner (same anvil
/// fork as the surrounding prepare phase) and return the stage-0 governance
/// calls. Reuses `deployer` for the broadcast.
pub async fn deploy_puh_guardians(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    inputs: &PuhGuardiansInputs<'_>,
) -> anyhow::Result<PuhGuardiansOutcome> {
    let era_chain_id = inputs.env.and_then(|c| c.era_chain_id()).ok_or_else(|| {
        anyhow::anyhow!("--env must supply era_chain_id for PUH/Guardians redeploy")
    })?;
    let create2_factory = inputs
        .create2_factory_override
        .or_else(|| inputs.env.and_then(|c| c.create2_factory()))
        .unwrap_or_else(|| {
            DEFAULT_CREATE2_FACTORY
                .parse()
                .expect("hardcoded factory address parses")
        });
    let gov_salt = inputs
        .gov_salt_override
        .unwrap_or_else(|| H256::from(keccak256(GOV_SALT_SEED)));

    // Resolve --zk-governance-dir relative to the contracts root (`paths::contracts_root()`),
    // so the default `../../zk-governance` works regardless of shell cwd. Some
    // checkouts wrap the foundry project in an `l1-contracts/` subdir; if the
    // top-level dir has no `foundry.toml`, descend into `l1-contracts`.
    let zk_gov_dir = if inputs.zk_governance_dir.is_absolute() {
        inputs.zk_governance_dir.clone()
    } else {
        crate::common::paths::contracts_root().join(&inputs.zk_governance_dir)
    };
    let zk_gov_dir = zk_gov_dir
        .canonicalize()
        .with_context(|| format!("zk-governance dir not found: {}", zk_gov_dir.display()))?;
    let zk_gov_dir = if zk_gov_dir.join("foundry.toml").exists() {
        zk_gov_dir
    } else if zk_gov_dir.join("l1-contracts/foundry.toml").exists() {
        zk_gov_dir.join("l1-contracts")
    } else {
        anyhow::bail!(
            "zk-governance foundry root not found: neither {} nor {}/l1-contracts contains foundry.toml",
            zk_gov_dir.display(),
            zk_gov_dir.display()
        );
    };
    let script_full = zk_gov_dir.join(
        DEFAULT_SCRIPT_PATH
            .split(':')
            .next()
            .unwrap_or(DEFAULT_SCRIPT_PATH),
    );
    if !script_full.exists() {
        anyhow::bail!(
            "zk-governance deploy script not found: {}\n\
             Make sure the checkout has DeployPUHAndGuardians.s.sol on a branch derived from\n\
             vg/oz-audit-feb-2026.",
            script_full.display()
        );
    }

    // ── on-chain reads on the fork ───────────────────────────────────
    let puh_proxy = resolve_governance(&runner.rpc_url, inputs.bridgehub).await?;
    logger::info(format!("ProtocolUpgradeHandler proxy: {puh_proxy:#x}"));

    let chain_asset_handler = match inputs.chain_asset_handler_override {
        Some(addr) => addr,
        None => resolve_chain_asset_handler(&runner.rpc_url, inputs.bridgehub).await?,
    };
    logger::info(format!("ChainAssetHandler: {chain_asset_handler:#x}"));

    let proxy_admin = read_eip1967_admin(&runner.rpc_url, puh_proxy).await?;
    logger::info(format!("PUH ProxyAdmin: {proxy_admin:#x}"));

    let zksync_os_ctm = inputs.zksync_os_ctm.ok_or_else(|| {
        anyhow::anyhow!(
            "zksync_os_ctm is required for PUH/Guardians redeploy — \
             pass it from the CTM prepare output (the CTM with is_zk_sync_os=true)"
        )
    })?;
    logger::info(format!("ZKsync OS CTM: {zksync_os_ctm:#x}"));

    // Forge writes the deploy output TOML inside zk-governance/script-out/
    // so it falls under that repo's `fs_permissions` whitelist.
    let zk_gov_script_out = zk_gov_dir.join("script-out");
    fs::create_dir_all(&zk_gov_script_out)?;
    let deploy_output_toml = zk_gov_script_out.join("deploy-puh-guardians.toml");
    let _ = fs::remove_file(&deploy_output_toml);

    logger::step(format!(
        "Running zk-governance DeployPUHAndGuardians from {}",
        zk_gov_dir.display()
    ));

    let script_rel = Path::new(DEFAULT_SCRIPT_PATH);
    let script = runner
        .script_path_from_root(&zk_gov_dir, script_rel)
        .with_broadcast()
        // The zk-governance foundry.toml has [profile.default|ci|lite] but no
        // `anvil-interop` profile. If our parent harness exported
        // FOUNDRY_PROFILE=anvil-interop (era-contracts side), forge would
        // refuse to load the zk-governance side. Pin to default.
        .with_env("FOUNDRY_PROFILE", "default")
        .with_env("PREV_PROTOCOL_UPGRADE_HANDLER", format!("{:#x}", puh_proxy))
        .with_env("CHAIN_ASSET_HANDLER", format!("{:#x}", chain_asset_handler))
        .with_env(
            "ZKSYNC_OS_CHAIN_TYPE_MANAGER",
            format!("{:#x}", zksync_os_ctm),
        )
        .with_env("CREATE2_FACTORY", format!("{:#x}", create2_factory))
        .with_env("CREATE2_SALT_GOV", format!("{:#x}", gov_salt))
        .with_env("USE_TESTNET_PUH", inputs.use_testnet_puh.to_string())
        .with_env("ERA_CHAIN_ID", era_chain_id.to_string())
        .with_env(
            "DEPLOY_OUTPUT_TOML",
            deploy_output_toml.to_string_lossy().into_owned(),
        )
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_wallet(deployer);
    runner
        .run(script)
        .context("Failed to execute DeployPUHAndGuardians forge script")?;

    let raw = fs::read_to_string(&deploy_output_toml).with_context(|| {
        format!(
            "Forge script did not produce deploy output TOML: {}",
            deploy_output_toml.display()
        )
    })?;
    let parsed: DeployOutput = toml::from_str(&raw)
        .with_context(|| format!("Failed to parse {}", deploy_output_toml.display()))?;
    let new_puh_impl = parsed.new_puh_impl;
    let new_guardians = parsed.new_guardians;
    let new_security_council = parsed.new_security_council;
    let new_emergency_upgrade_board = parsed.new_emergency_upgrade_board;
    logger::info(format!(
        "New PUH impl:    {new_puh_impl:#x} (testnet handler: {})",
        inputs.use_testnet_puh
    ));
    logger::info(format!("New Guardians:        {new_guardians:#x}"));
    logger::info(format!("New SecurityCouncil:  {new_security_council:#x}"));
    logger::info(format!(
        "New EmergencyBoard:   {new_emergency_upgrade_board:#x}"
    ));

    // Stage-0 wiring, executed as the PUH via governance. The impl swap goes
    // first; then the three `onlySelf` setters repoint the proxy at the freshly
    // deployed SecurityCouncil, Guardians and EmergencyUpgradeBoard. The board
    // already embeds the new SC + Guardians as immutables (set at deploy), so
    // pointing the PUH at the new board completes a consistent set.
    let stage0_calls = vec![
        GovernanceCall {
            target: proxy_admin,
            value: U256::zero(),
            data: encode_proxy_admin_upgrade(puh_proxy, new_puh_impl),
        },
        GovernanceCall {
            target: puh_proxy,
            value: U256::zero(),
            data: encode_puh_update_security_council(new_security_council),
        },
        GovernanceCall {
            target: puh_proxy,
            value: U256::zero(),
            data: encode_puh_update_guardians(new_guardians),
        },
        GovernanceCall {
            target: puh_proxy,
            value: U256::zero(),
            data: encode_puh_update_emergency_board(new_emergency_upgrade_board),
        },
    ];

    Ok(PuhGuardiansOutcome {
        stage0_calls,
        puh_proxy,
        proxy_admin,
        new_puh_impl,
        new_guardians,
        new_security_council,
        new_emergency_upgrade_board,
    })
}

#[derive(Debug, Deserialize)]
struct DeployOutput {
    new_puh_impl: Address,
    new_guardians: Address,
    new_security_council: Address,
    new_emergency_upgrade_board: Address,
}

fn http_provider(rpc: &str) -> anyhow::Result<Provider<Http>> {
    Provider::<Http>::try_from(rpc).with_context(|| format!("invalid RPC URL: {rpc}"))
}

async fn resolve_chain_asset_handler(rpc: &str, bridgehub: Address) -> anyhow::Result<Address> {
    let provider = http_provider(rpc)?;
    let result = provider
        .call(
            &ethers::types::transaction::eip2718::TypedTransaction::Legacy(
                ethers::types::transaction::request::TransactionRequest::default()
                    .to(bridgehub)
                    .data(BRIDGEHUB_CHAIN_ASSET_HANDLER_SELECTOR.to_vec()),
            ),
            None,
        )
        .await
        .context("bridgehub.chainAssetHandler() call failed")?;
    if result.0.len() < 32 {
        anyhow::bail!(
            "bridgehub.chainAssetHandler() returned short data ({} bytes)",
            result.0.len()
        );
    }
    let addr = Address::from_slice(&result.0[12..32]);
    if addr.is_zero() {
        anyhow::bail!("bridgehub.chainAssetHandler() returned 0x0 — v31 prepare hasn't run yet");
    }
    Ok(addr)
}

async fn read_eip1967_admin(rpc: &str, proxy: Address) -> anyhow::Result<Address> {
    let provider = http_provider(rpc)?;
    let raw = provider
        .get_storage_at(proxy, EIP1967_ADMIN_SLOT, None)
        .await
        .context("eth_getStorageAt(EIP-1967 admin slot) failed")?;
    let addr = Address::from_slice(&raw.0[12..32]);
    if addr.is_zero() {
        anyhow::bail!("EIP-1967 admin slot of {proxy:#x} is empty — proxy not initialized?");
    }
    Ok(addr)
}

fn encode_proxy_admin_upgrade(proxy: Address, new_impl: Address) -> Vec<u8> {
    let mut buf = Vec::with_capacity(4 + 32 * 4);
    buf.extend_from_slice(&PROXY_ADMIN_UPGRADE_AND_CALL_SELECTOR);
    buf.extend_from_slice(&abi_encode(&[
        Token::Address(proxy),
        Token::Address(new_impl),
        Token::Bytes(Vec::new()),
    ]));
    buf
}

fn encode_puh_update_guardians(new_guardians: Address) -> Vec<u8> {
    encode_address_setter(PUH_UPDATE_GUARDIANS_SELECTOR, new_guardians)
}

fn encode_puh_update_security_council(new_security_council: Address) -> Vec<u8> {
    encode_address_setter(PUH_UPDATE_SECURITY_COUNCIL_SELECTOR, new_security_council)
}

fn encode_puh_update_emergency_board(new_board: Address) -> Vec<u8> {
    encode_address_setter(PUH_UPDATE_EMERGENCY_BOARD_SELECTOR, new_board)
}

/// Encodes a `selector(address)` call — the shape of all three PUH `update*`
/// setters (`updateSecurityCouncil` / `updateGuardians` / `updateEmergencyUpgradeBoard`).
fn encode_address_setter(selector: [u8; 4], addr: Address) -> Vec<u8> {
    let mut buf = Vec::with_capacity(4 + 32);
    buf.extend_from_slice(&selector);
    buf.extend_from_slice(&abi_encode(&[Token::Address(addr)]));
    buf
}
