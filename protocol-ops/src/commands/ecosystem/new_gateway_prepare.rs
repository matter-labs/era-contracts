//! New-Gateway prepare step for the v31 ecosystem flow.
//!
//! When the env's `permanent-values/<env>.toml` carries a `[new_gateway]`
//! block, `V31UpgradeFull::prepare` invokes this step on the same anvil fork
//! as Core+CTM prepares. It wraps the existing
//! `chain::gateway::convert::stage_vote_prepare` (which itself drives
//! `deploy-scripts/gateway/GatewayVotePreparation.s.sol`) so we get the
//! complete new-GW bring-up in one bundle:
//!
//!   - L1 `setSettlementLayerStatus(gatewayChainId, true)` (whitelist).
//!   - L1→L2 `addChainTypeManager(gatewayCTM)` on the L2 Bridgehub.
//!   - L1 `setAssetDeploymentTracker` + `registerCTMAssetOnL1`.
//!   - L1→L2 two-bridges `setAssetHandler` for the chain assetId.
//!   - L1→L2 two-bridges chain-asset-handler registration for the GW CTM.
//!   - L1→L2 `acceptOwnership` on the GW RollupDAManager (+ ServerNotifier).
//!   - L1→L2 `setGatewaySettlementFee(fee)` on `GW_ASSET_TRACKER_ADDR`.
//!
//! The script writes its bundle as abi-encoded `Call[]` into the
//! `governance_calls_to_execute` field of an output TOML; the ecosystem
//! merge in [`super::upgrade::write_merged_ecosystem_toml`] decodes that
//! field and appends it to stage 2 of `<env-out>/ecosystem.toml`.
//!
//! Two real-fork caveats worth flagging:
//!
//! - The script CREATE2-deploys the entire GW CTM contract set (Mailbox /
//!   Executor / Diamond / etc.). Those deploys land in the deployer-EOA
//!   Safe bundle alongside Core+CTM-upgrade deploys, which makes that
//!   bundle noticeably larger.
//! - The deployer EOA pays for both the L1 deploys *and* the value attached
//!   to each L1→L2 priority tx (since `Utils.prepareGovernanceL1L2*`
//!   approves base-token spend from the *governance* address but the
//!   deploys themselves use `msg.sender`). On simulate forks that's
//!   harmless; on a real run the deployer needs ETH + ZK headroom.

use std::path::{Path, PathBuf};

use anyhow::Context;
use ethers::types::{Address, Bytes};
use ethers::utils::hex;
use serde::Deserialize;

use crate::commands::chain::gateway::convert::{stage_vote_prepare, VotePrepareInputs};
use crate::commands::ecosystem::v31_upgrade_inner::CtmPrepareEntry;
use crate::common::anvil::{
    evm_increase_time_and_mine, evm_revert, evm_snapshot, send_impersonated_tx, set_balance,
};
use crate::common::env_config::NewGatewayConfig;
use crate::common::ethereum::get_ethers_provider;
use crate::common::forge::ForgeRunner;
use crate::common::governance_calls::decode_calls;
use crate::common::logger;
use crate::common::paths;
use crate::common::wallets::Wallet;

/// Relative path (inside `l1-contracts/`) where `GatewayVotePreparation` writes
/// its output. Lives under `script-out/` because forge's `fs_permissions` only
/// allows writes there. The ecosystem prepare flow reads from this same path
/// to extract `governance_calls_to_execute`.
const VOTE_PREP_OUTPUT_REL: &str = "script-out/v31-new-gateway-vote-preparation.toml";

/// Run `GatewayVotePreparation` for the env's configured new-gateway, returning
/// the absolute path to the output TOML so the caller can merge its
/// `governance_calls_to_execute` field into stage 2 of the ecosystem TOML.
///
/// `deployer` is the same wallet that signs the rest of the prepare phase
/// (the ecosystem deployer EOA); its broadcasts merge into the existing
/// deployer Safe bundle. When `new_gw.refund_recipient` is absent, the
/// deployer's address is used as the refund recipient — EOAs aren't aliased
/// across L1→L2, so refunds land back at the deployer on L2 and stay
/// spendable.
#[allow(clippy::too_many_arguments)]
pub async fn prepare_new_gateway(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    bridgehub: Address,
    core_toml: &Path,
    new_gw: &NewGatewayConfig,
    ctm_representative_chain_id: u64,
    ctm_tomls: &[CtmPrepareEntry],
    zk_token_asset_id: ethers::types::H256,
    gw_create2_salt: Option<ethers::types::H256>,
) -> anyhow::Result<PathBuf> {
    let refund_recipient = new_gw.refund_recipient.unwrap_or(deployer.address);

    // Resolve which CTM the new GW will host (the deployed GW CTM is a
    // variant of this CTM) by looking up its proxy via the configured
    // representative chain, then find the matching prepare entry produced
    // earlier in this same fork run. The override path uses the
    // `force_deployments_data` that prepare just serialized into the per-CTM
    // TOML, which is the post-v31 value (the on-chain dump path would only
    // work *after* governance stage 1 has actually swapped the CTM impl).
    let source_ctm = crate::common::l1_contracts::resolve_ctm_proxy(
        &runner.rpc_url,
        bridgehub,
        ctm_representative_chain_id,
    )
    .await
    .context("resolving source CTM proxy for new gateway")?;
    let source_ctm_entry = ctm_tomls
        .iter()
        .find(|e| e.proxy == source_ctm)
        .with_context(|| {
            format!(
                "no prepare entry for source CTM {:#x} (representative chain {}); \
                 the env's `[new_gateway].ctm_representative_chain_ids` must point \
                 at chains whose CTMs were included in `[[ctm_contracts.ctms]]`",
                source_ctm, ctm_representative_chain_id
            )
        })?;
    let force_deployments_data = read_ctm_force_deployments_data(&source_ctm_entry.toml)
        .with_context(|| {
            format!(
                "reading force_deployments_data from CTM prepare TOML: {}",
                source_ctm_entry.toml.display()
            )
        })?;

    logger::step(format!(
        "Running new-Gateway vote-prepare (GW chain {}, source CTM {:#x} via chain {})",
        new_gw.chain_id, source_ctm, ctm_representative_chain_id
    ));
    logger::info(format!(
        "Settlement fee:   {} (wrapped-ZK wei)",
        new_gw.settlement_fee
    ));
    logger::info(format!(
        "Refund recipient: {refund_recipient:#x}{}",
        if new_gw.refund_recipient.is_some() {
            " (from [new_gateway].refund_recipient)"
        } else {
            " (defaulted to deployer EOA — EOAs not aliased across L1→L2)"
        }
    ));
    if let Some(sn) = new_gw.server_notifier {
        logger::info(format!("ServerNotifier (pre-deployed): {sn:#x}"));
    }

    // ── Snapshot + apply gov stages 0+1 on the prepare fork ────────────
    // GatewayVotePreparation has a hard
    //   `require(ctm.protocolVersion() == latestProtocolVersion)`
    // in `setAddressesBasedOnBridgehub`, plus several v31+ getter reads
    // (`isZKsyncOS()`, `protocolVersionVerifier()`, `newChainCreationParamsBlock()`).
    // The source CTM is still on the pre-v31 impl on the fork at this point.
    //
    // To get the script past those checks WITHOUT polluting the deployer's
    // Safe bundle with the governance calls (those belong in the gov
    // bundle, executed separately), we:
    //   1. Snapshot the fork.
    //   2. Replay gov stages 0+1 from the just-emitted core + per-CTM
    //      TOMLs as raw `eth_sendTransaction` from the impersonated
    //      governance address. Direct ethers bypasses forge entirely so
    //      these txs don't land in any broadcast log.
    //   3. Run GatewayVotePreparation — the source CTM is now v31 on the
    //      fork, so the require + on-chain reads succeed. Its broadcast
    //      log captures the GW CTM deploys for the deployer bundle.
    //   4. Capture the GW deploy txs from forge's broadcast log so we can
    //      re-apply them after the revert.
    //   5. Revert to the snapshot — undoes the gov-0+1 application AND the
    //      GW deploys on the fork, but leaves the bundle JSON intact.
    //   6. Re-broadcast the captured GW deploy txs as raw
    //      `eth_sendTransaction` from each tx's `from`. The CREATE2 deploys
    //      land at the same addresses, so downstream stage-2 calls
    //      (which reference those addresses) still resolve when governance
    //      stage 2 runs against this fork later.
    let governance = crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub)
        .await
        .context("resolve governance address for gov-0+1 replay")?;
    // Fund the impersonated governance EOA so its eth_sendTransaction calls
    // have gas headroom (governance is typically a contract on stage/mainnet,
    // so anvil's auto-impersonated account starts with zero ETH).
    set_balance(&runner.rpc_url, governance)
        .await
        .context("anvil_setBalance(governance)")?;

    let snap_id = evm_snapshot(&runner.rpc_url)
        .await
        .context("evm_snapshot before gov-0+1 replay")?;

    replay_gov_stages_0_and_1(&runner.rpc_url, governance, core_toml, ctm_tomls)
        .await
        .context("replay gov stages 0+1 on prepare fork")?;

    // Register the new GW's base-token assetId in the freshly-deployed
    // L1AssetTracker. GatewayVotePreparation's first L1→L2 priority tx
    // charges the base token (ZK on a ZKsyncOS GW), which routes through
    // `L1AssetRouter.bridgehubDepositBaseToken` → `NTV.bridgeBurn` →
    // `L1AssetTracker.handleChainBalanceIncreaseOnL1` → `_requireRegistered`.
    // In production this registration happens in stage3 (post-governance),
    // but our prepare-time replay needs it earlier. The function is public
    // (anyone can call), so a direct ethers tx is enough.
    let asset_tracker = read_asset_tracker_proxy(core_toml)
        .with_context(|| format!("read asset_tracker_proxy_addr from {}", core_toml.display()))?;
    prime_zk_token_registration(&runner.rpc_url, asset_tracker, zk_token_asset_id)
        .await
        .context("prime ZK-token registration in L1AssetTracker")?;

    // Fund the deployer EOA with ZK tokens so the L1→L2 priority txs in
    // GatewayVotePreparation (which charge ZK as base token) can succeed
    // when forge --broadcast simulates them against the fork. Uses the
    // real `BridgedStandardERC20.bridgeMint` flow via NTV impersonation —
    // the only address authorized to mint per the token's `onlyNTV` guard.
    fund_zk_via_bridge_mint(
        &runner.rpc_url,
        bridgehub,
        zk_token_asset_id,
        deployer.address,
    )
    .await
    .context("fund deployer ZK balance on prepare fork")?;

    let stage_result = stage_vote_prepare(
        runner,
        deployer,
        bridgehub,
        new_gw.chain_id,
        &VotePrepareInputs {
            ctm_representative_chain_id,
            vote_preparation_toml: VOTE_PREP_OUTPUT_REL,
            refund_recipient,
            gateway_settlement_fee: new_gw.settlement_fee,
            force_deployments_data_override: Some(force_deployments_data),
            create2_salt: gw_create2_salt,
        },
    )
    .await
    .context("new-gateway vote-prepare forge invocation");

    // Roll back fork (drops gov-0+1 + GW state) so downstream consumers
    // start from the same state real L1 would be in before the upgrade.
    // The forge broadcast logs were written to disk during the GW prep run,
    // so the Safe bundle generator still has the deploys + priority txs
    // it needs to emit. We do NOT manually re-broadcast those txs here —
    // the downstream `executeSafeBundles` replay handles them on the *test
    // harness's* anvil (this nested fork dies when `ForgeRunner` drops).
    // Note also: no need to re-fund anything on this fork post-revert —
    // the harness-owned anvil is where bundle replay happens; funding for
    // that lives in `v31-upgrade-test-runner.ts:fundDeployerZkForBundleReplay`.
    evm_revert(&runner.rpc_url, &snap_id)
        .await
        .context("evm_revert after GW prep")?;
    let _ = stage_result?;

    let contracts_path = paths::resolve_l1_contracts_path()?;
    let abs_path = contracts_path.join(VOTE_PREP_OUTPUT_REL);
    anyhow::ensure!(
        abs_path.exists(),
        "Vote preparation output not found at {}",
        abs_path.display()
    );
    Ok(abs_path)
}

// ── helpers ────────────────────────────────────────────────────────────

/// Apply stages 0+1 of the just-emitted governance TOMLs to the fork as
/// the impersonated governance address. Bypasses forge so the txs don't
/// land in any Safe bundle.
async fn replay_gov_stages_0_and_1(
    rpc_url: &str,
    governance: Address,
    core_toml: &Path,
    ctm_tomls: &[CtmPrepareEntry],
) -> anyhow::Result<()> {
    logger::info(format!(
        "Replaying gov stages 0+1 on prepare fork as governance {governance:#x} \
         to satisfy GatewayVotePreparation's v31-CTM precondition"
    ));
    // Read stage0/1/2 from each per-script TOML in the same source order the
    // ecosystem-merge uses (core first, then per-CTM in input order). All
    // three stages need to be applied: GatewayVotePreparation needs to see
    // the v31-upgraded CTM state, and that includes per-CTM stage-2 calls
    // (notably the L1AssetRouter / NTV registration of the ZK token assetId
    // used as the GW base token — without it, the GW deploy reverts with
    // `AssetIdNotRegistered`).
    //
    // Stages are interleaved per stage index (all stage 0 across files,
    // then all stage 1, then all stage 2). Stage 0 typically starts a
    // deadline timer that stage 1's `checkDeadline()` asserts has elapsed,
    // so we fast-forward anvil time between stages 0 and 1 — same trick the
    // fork-upgrade-test harness uses (`advanceL1TimePastUpgradeDeadline`).
    //
    // After the snapshot revert downstream, this whole state goes away —
    // the test runner's downstream Step 6 then replays stages 0/1/2 fresh
    // from the merged ecosystem.toml. No double-application happens.
    let sources: Vec<&Path> = std::iter::once(core_toml)
        .chain(ctm_tomls.iter().map(|e| e.toml.as_path()))
        .collect();

    // `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps`
    // now defers each CTM's `acceptOwnership()` to a stage-0 governance call
    // (recorded in `script-out/pre-governance-accept-ownerships.toml`)
    // instead of executing it directly on the fork. The fork's CTM owners
    // therefore still sit at `pendingOwner = governance` until those calls
    // run. Stage-1 contains `onlyOwner` calls (`setChainCreationParams`,
    // etc.), so apply the deferred acceptOwnerships HERE before the regular
    // stage 0 — same impersonated-`from = governance` envelope, identical
    // end state.
    let contracts_path = crate::common::paths::resolve_l1_contracts_path()?;
    let pre_gov_accept_calls =
        crate::commands::ecosystem::upgrade::read_pre_governance_accept_ownership_calls(
            &contracts_path,
        )
        .context("read pre-governance-accept-ownerships.toml for replay")?;
    for (idx, call) in pre_gov_accept_calls.iter().enumerate() {
        send_impersonated_tx(
            rpc_url,
            governance,
            call.target,
            Bytes::from(call.data.clone()),
            GOV_REPLAY_GAS_LIMIT,
        )
        .await
        .with_context(|| {
            format!(
                "pre-gov acceptOwnership #{idx} → {:#x} (deferred by AdminFunctions)",
                call.target
            )
        })?;
        let _ = call.value; // always 0 for acceptOwnership()
    }
    let mut total = pre_gov_accept_calls.len();
    for stage in [0u8, 1, 2] {
        if stage == 1 {
            evm_increase_time_and_mine(rpc_url, GOV_DEADLINE_BUMP_SECONDS)
                .await
                .context("evm_increaseTime between stage 0 and 1")?;
        }
        for path in &sources {
            let hex_str = read_gov_stage_hex(path, stage)?;
            let calls = decode_calls(&hex_str)
                .with_context(|| format!("decode stage{stage}_calls from {}", path.display()))?;
            for (idx, call) in calls.iter().enumerate() {
                send_impersonated_tx(
                    rpc_url,
                    governance,
                    call.target,
                    Bytes::from(call.data.clone()),
                    GOV_REPLAY_GAS_LIMIT,
                )
                .await
                .with_context(|| {
                    format!(
                        "stage {stage} call #{idx} from {} → {:#x}",
                        path.display(),
                        call.target
                    )
                })?;
                let _ = call.value; // governance-direct calls are always value=0 in our flow
                total += 1;
            }
        }
    }
    logger::info(format!("Applied {total} gov stage-0/1/2 call(s) on fork"));
    Ok(())
}

/// Time bump (in seconds) between stage 0 and stage 1. Stage 0 starts the
/// `GovernanceUpgradeTimer` with a delay set in the v31 upgrade input
/// (1200s on stage). 24h is enough headroom for any reasonable delay
/// without making block.timestamp wildly diverge from real wall time.
const GOV_DEADLINE_BUMP_SECONDS: u64 = 24 * 60 * 60;

/// Pull `asset_tracker_proxy_addr` out of `CoreUpgrade_v31`'s output TOML.
/// Set by `saveOutputVersionSpecific` (see CoreUpgrade_v31.s.sol:240).
fn read_asset_tracker_proxy(core_toml: &Path) -> anyhow::Result<Address> {
    #[derive(serde::Deserialize)]
    struct Top {
        asset_tracker_proxy_addr: String,
    }
    let raw = std::fs::read_to_string(core_toml)
        .with_context(|| format!("read {}", core_toml.display()))?;
    let top: Top =
        toml::from_str(&raw).with_context(|| format!("parse {}", core_toml.display()))?;
    top.asset_tracker_proxy_addr.parse().with_context(|| {
        format!(
            "asset_tracker_proxy_addr is not a valid address: {}",
            top.asset_tracker_proxy_addr
        )
    })
}

/// 1e30 wei (1B tokens for an 18-decimal token) — comfortably above the
/// ~580 ZK each GatewayVotePreparation priority tx charges. Kept as a
/// constant so the harness-side TypeScript funding uses the same amount.
pub const ZK_FUNDING_WEI_HEX: &str = "0xc9f2c9cd04674edea40000000";

/// Mint `1e30` wei of ZK to `deployer` via `BridgedStandardERC20.bridgeMint`,
/// impersonating the canonical NTV (the only caller `onlyNTV` admits). This
/// is the real-contract-call analogue of "fund the deployer for the GW prep
/// priority-tx broadcast" — we don't touch ERC20 storage directly.
///
/// Only valid against an anvil fork with `--auto-impersonate` so the NTV
/// address can be used as `from` despite being a contract.
async fn fund_zk_via_bridge_mint(
    rpc_url: &str,
    bridgehub: Address,
    zk_token_asset_id: ethers::types::H256,
    deployer: Address,
) -> anyhow::Result<()> {
    use ethers::types::U256;

    let provider = get_ethers_provider(rpc_url)?;
    // Resolve token + NTV: bridgehub → assetRouter → NTV → tokenAddress(assetId).
    let bh = ethers::contract::Contract::new(
        bridgehub,
        ethers::abi::parse_abi(&["function assetRouter() view returns (address)"]).unwrap(),
        provider.clone(),
    );
    let asset_router: Address = bh
        .method::<_, Address>("assetRouter", ())?
        .call()
        .await
        .context("bridgehub.assetRouter()")?;
    let ar = ethers::contract::Contract::new(
        asset_router,
        ethers::abi::parse_abi(&["function nativeTokenVault() view returns (address)"]).unwrap(),
        provider.clone(),
    );
    let ntv: Address = ar
        .method::<_, Address>("nativeTokenVault", ())?
        .call()
        .await
        .context("assetRouter.nativeTokenVault()")?;
    let ntv_c = ethers::contract::Contract::new(
        ntv,
        ethers::abi::parse_abi(&["function tokenAddress(bytes32) view returns (address)"]).unwrap(),
        provider.clone(),
    );
    let zk_token: Address = ntv_c
        .method::<_, Address>("tokenAddress", zk_token_asset_id)?
        .call()
        .await
        .context("NTV.tokenAddress(zkTokenAssetId)")?;
    anyhow::ensure!(
        zk_token != Address::zero(),
        "NTV.tokenAddress({zk_token_asset_id:#x}) returned zero — assetId not registered on this fork"
    );

    let amount = U256::from_str_radix(ZK_FUNDING_WEI_HEX.trim_start_matches("0x"), 16)
        .expect("hard-coded ZK_FUNDING_WEI_HEX is valid hex");

    logger::info(format!(
        "Minting 1e30 wei ZK to {deployer:#x} at {zk_token:#x} via NTV {ntv:#x}.bridgeMint"
    ));

    // NTV is a contract — give it ETH for gas (anvil_setBalance is a balance
    // override, not a storage write to the token).
    set_balance(rpc_url, ntv)
        .await
        .context("anvil_setBalance(NTV)")?;

    // ABI-encode bridgeMint(address,uint256) and send as the NTV via auto-impersonate.
    let selector = &ethers::utils::id("bridgeMint(address,uint256)")[..4];
    let args = ethers::abi::encode(&[
        ethers::abi::Token::Address(deployer),
        ethers::abi::Token::Uint(amount),
    ]);
    let mut calldata = Vec::with_capacity(4 + args.len());
    calldata.extend_from_slice(selector);
    calldata.extend_from_slice(&args);

    send_impersonated_tx(
        rpc_url,
        ntv,
        zk_token,
        ethers::types::Bytes::from(calldata),
        GOV_REPLAY_GAS_LIMIT,
    )
    .await
    .context("BridgedStandardERC20.bridgeMint(deployer, 1e30) from NTV")?;

    // Sanity-check the mint via balanceOf so a future ABI / NTV-address drift
    // surfaces here, not as a downstream "burn amount exceeds balance" deep
    // inside the forge run.
    let token = ethers::contract::Contract::new(
        zk_token,
        ethers::abi::parse_abi(&["function balanceOf(address) view returns (uint256)"]).unwrap(),
        provider,
    );
    let bal: U256 = token
        .method::<_, U256>("balanceOf", deployer)?
        .call()
        .await
        .context("balanceOf(deployer) after bridgeMint")?;
    anyhow::ensure!(
        bal >= amount,
        "bridgeMint didn't credit the expected amount — balanceOf returned {bal}, expected ≥ {amount}"
    );
    Ok(())
}

/// Call `L1AssetTracker.registerLegacyToken(zkTokenAssetId)` so the GW's
/// first L1→L2 priority tx (which charges ZK as the base token) can pass
/// the `_requireRegistered` gate. The function is public — anyone can call
/// it — so a single direct-ethers tx from an anvil-default EOA is enough.
/// We send outside forge so it doesn't land in any Safe bundle; the
/// production stage-3 phase later re-applies this registration cleanly
/// through the standard flow against the fresh real-L1 state.
async fn prime_zk_token_registration(
    rpc_url: &str,
    asset_tracker: Address,
    zk_token_asset_id: ethers::types::H256,
) -> anyhow::Result<()> {
    let selector = &ethers::utils::id("registerLegacyToken(bytes32)")[..4];
    let mut calldata = Vec::with_capacity(36);
    calldata.extend_from_slice(selector);
    calldata.extend_from_slice(zk_token_asset_id.as_bytes());

    // Any EOA works; default-anvil account 0 has known unlimited funding
    // via `set_balance`. We don't use the deployer EOA here because
    // (i) we want this to NOT count as a deployer broadcast, and
    // (ii) anvil's auto-impersonate accepts any `from` without holding
    //      its key.
    let caller: Address = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        .parse()
        .unwrap();
    set_balance(rpc_url, caller)
        .await
        .context("anvil_setBalance(default-anvil-caller)")?;

    logger::info(format!(
        "Priming L1AssetTracker.registerLegacyToken({zk_token_asset_id:#x}) on {asset_tracker:#x}"
    ));
    send_impersonated_tx(
        rpc_url,
        caller,
        asset_tracker,
        Bytes::from(calldata),
        GOV_REPLAY_GAS_LIMIT,
    )
    .await
    .context("registerLegacyToken(zkTokenAssetId)")?;
    Ok(())
}

/// Read `governance_calls.stage{N}_calls` (0x-prefixed hex) from a per-script
/// prepare TOML. Mirrors the `GovernanceCalls` struct in `upgrade.rs`.
fn read_gov_stage_hex(path: &Path, stage: u8) -> anyhow::Result<String> {
    #[derive(Deserialize)]
    struct Top {
        governance_calls: Stages,
    }
    #[derive(Deserialize)]
    struct Stages {
        stage0_calls: String,
        stage1_calls: String,
        stage2_calls: String,
    }
    let raw = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let top: Top = toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    Ok(match stage {
        0 => top.governance_calls.stage0_calls,
        1 => top.governance_calls.stage1_calls,
        2 => top.governance_calls.stage2_calls,
        _ => anyhow::bail!("invalid stage {stage}; expected 0..=2"),
    })
}

/// Per-call gas limit for the gov-0+1 replay. Generous — these are
/// governance-driven proxy upgrades / ownership transfers that can spike
/// during state initialization. Below `--disable-block-gas-limit`'s
/// effective ceiling.
const GOV_REPLAY_GAS_LIMIT: u64 = 100_000_000;

/// Pull `force_deployments_data` out of a per-CTM v31 prepare TOML.
/// `DefaultCTMUpgrade.s.sol:913` writes the value with
/// `vm.serializeBytes("contracts_newConfig", ...)`, but the saveOutput
/// re-aliases that group as `contracts_config` on the root object before
/// `vm.writeToml`, so the field lands under `[contracts_config]` in the
/// emitted TOML (0x-prefixed hex).
fn read_ctm_force_deployments_data(path: &Path) -> anyhow::Result<Bytes> {
    #[derive(serde::Deserialize)]
    struct Top {
        contracts_config: ContractsConfig,
    }
    #[derive(serde::Deserialize)]
    struct ContractsConfig {
        force_deployments_data: String,
    }

    let raw = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let parsed: Top = toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    let trimmed = parsed
        .contracts_config
        .force_deployments_data
        .trim_start_matches("0x");
    let bytes = hex::decode(trimmed).with_context(|| {
        format!(
            "force_deployments_data in {} is not valid hex",
            path.display()
        )
    })?;
    Ok(Bytes::from(bytes))
}

// The merge of `governance_calls_to_execute` (abi-encoded `Call[]`) into stage
// 2 of the ecosystem TOML lives inline in `upgrade::write_merged_ecosystem_toml`
// — that function also embeds the rest of the output TOML (deployed GW CTM
// addresses + diamond cut data) under `[new_gateway]` for reviewability, so
// splitting the read out into a separate helper here would be more code, not
// less.
