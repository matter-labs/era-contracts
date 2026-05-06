//! Helpers for resolving contract addresses from L1 on-chain state.
//!
//! These mirror the resolution logic used by `zksync-os-server`: given a
//! bridgehub address, derive secondary addresses (CTM proxy, bytecodes
//! supplier, CTM deployment tracker, …) directly from L1 rather than
//! requiring callers to pass them explicitly.

use std::sync::Arc;

use anyhow::Context;
use ethers::providers::{Http, Provider};
use ethers::types::Address;

use crate::abi::{
    BridgehubAbi, ChainTypeManagerBaseAbi, IChainTypeManagerAbi, TestnetVerifierAbi, ZkChainAbi,
};

fn provider(rpc_url: &str) -> anyhow::Result<Arc<Provider<Http>>> {
    Ok(Arc::new(Provider::<Http>::try_from(rpc_url)?))
}

fn ensure_nonzero(addr: Address, what: &str) -> anyhow::Result<Address> {
    anyhow::ensure!(addr != Address::zero(), "{what} returned zero address");
    Ok(addr)
}

/// Resolve `bridgehub.chainTypeManager(chainId)` → CTM proxy address.
pub async fn resolve_ctm_proxy(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<Address> {
    let bh = BridgehubAbi::new(bridgehub, provider(l1_rpc_url)?);
    let ctm = bh
        .chain_type_manager(chain_id.into())
        .call()
        .await
        .context("bridgehub.chainTypeManager() call failed")?;
    ensure_nonzero(ctm, &format!("bridgehub.chainTypeManager({chain_id})"))
}

/// Discover the CTM proxy address from L1, without requiring an existing chain ID.
///
/// Strategy:
/// 1. If any chains are registered, use `chainTypeManager(first_chain_id)`.
/// 2. Otherwise, scan `ChainTypeManagerAdded(address indexed)` events on the
///    bridgehub and return the most recently added CTM.
pub async fn discover_ctm_proxy(l1_rpc_url: &str, bridgehub: Address) -> anyhow::Result<Address> {
    use ethers::providers::Middleware;
    use ethers::types::Filter;

    let p = provider(l1_rpc_url)?;
    let bh = BridgehubAbi::new(bridgehub, p.clone());

    // Try via existing chain first.
    let chain_ids = bh
        .get_all_zk_chain_chain_i_ds()
        .call()
        .await
        .context("bridgehub.getAllZKChainChainIDs()")?;
    if let Some(first) = chain_ids.first() {
        let ctm = bh
            .chain_type_manager(*first)
            .call()
            .await
            .context("bridgehub.chainTypeManager()")?;
        if ctm != Address::zero() {
            return Ok(ctm);
        }
    }

    // No chains — scan ChainTypeManagerAdded events.
    // event ChainTypeManagerAdded(address indexed chainTypeManager)
    let topic0 =
        ethers::types::H256::from(ethers::utils::keccak256(b"ChainTypeManagerAdded(address)"));
    let filter = Filter::new()
        .address(bridgehub)
        .topic0(topic0)
        .from_block(0u64);
    let logs = p
        .get_logs(&filter)
        .await
        .context("scan ChainTypeManagerAdded events on bridgehub")?;
    let log = logs.last().ok_or_else(|| {
        anyhow::anyhow!(
            "No ChainTypeManagerAdded events found on bridgehub {bridgehub:#x} — \
             ecosystem not initialized?"
        )
    })?;
    // The CTM address is indexed (topic1).
    let ctm = Address::from_slice(&log.topics[1][12..32]);
    ensure_nonzero(ctm, "ChainTypeManagerAdded event")
}

/// Resolve `bridgehub.l1CtmDeployer()` → CTM deployment tracker (STM tracker).
pub async fn resolve_stm_tracker(l1_rpc_url: &str, bridgehub: Address) -> anyhow::Result<Address> {
    let bh = BridgehubAbi::new(bridgehub, provider(l1_rpc_url)?);
    let tracker = bh
        .l_1_ctm_deployer()
        .call()
        .await
        .context("bridgehub.l1CtmDeployer() call failed")?;
    ensure_nonzero(tracker, "bridgehub.l1CtmDeployer()")
}

/// Resolve `bridgehub.getAllZKChainChainIDs()` → list of registered chain IDs.
pub async fn resolve_all_chain_ids(
    l1_rpc_url: &str,
    bridgehub: Address,
) -> anyhow::Result<Vec<u64>> {
    let bh = BridgehubAbi::new(bridgehub, provider(l1_rpc_url)?);
    let ids = bh
        .get_all_zk_chain_chain_i_ds()
        .call()
        .await
        .context("bridgehub.getAllZKChainChainIDs() call failed")?;
    Ok(ids.iter().map(|id| id.as_u64()).collect())
}

/// Enumerate every CTM proxy currently registered under `bridgehub` by
/// iterating its `getAllZKChainChainIDs()` and looking up each chain's
/// `chainTypeManager`. Returns deduped addresses in first-seen order, with
/// the first chain that uses each as a witness (handy for downstream
/// auto-resolution of rollup-DA-manager).
pub async fn discover_all_ctms(
    l1_rpc_url: &str,
    bridgehub: Address,
) -> anyhow::Result<Vec<(Address, u64)>> {
    let chain_ids = resolve_all_chain_ids(l1_rpc_url, bridgehub).await?;
    let mut out: Vec<(Address, u64)> = Vec::new();
    for cid in chain_ids {
        let ctm = resolve_ctm_proxy(l1_rpc_url, bridgehub, cid)
            .await
            .with_context(|| format!("resolving CTM for chain {cid}"))?;
        if !out.iter().any(|(a, _)| *a == ctm) {
            out.push((ctm, cid));
        }
    }
    Ok(out)
}

/// Resolve `ctm.L1_BYTECODES_SUPPLIER()` → bytecodes supplier address.
pub async fn resolve_bytecodes_supplier(
    l1_rpc_url: &str,
    ctm_proxy: Address,
) -> anyhow::Result<Address> {
    let ctm = ChainTypeManagerBaseAbi::new(ctm_proxy, provider(l1_rpc_url)?);
    let supplier = ctm
        .l1_bytecodes_supplier()
        .call()
        .await
        .context("ctm.L1_BYTECODES_SUPPLIER() call failed")?;
    ensure_nonzero(supplier, "ctm.L1_BYTECODES_SUPPLIER()")
}

/// Resolve `bridgehub.settlementLayer(chainId)` → gateway chain ID.
///
/// Returns the chain ID of the gateway the given chain settles on, or an error
/// if the chain settles on L1 (i.e. `settlementLayer == L1_CHAIN_ID` or 0).
pub async fn resolve_settlement_layer(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<u64> {
    let p = provider(l1_rpc_url)?;
    let bh = BridgehubAbi::new(bridgehub, p);
    let l1_chain_id = bh
        .l1_chain_id()
        .call()
        .await
        .context("bridgehub.L1_CHAIN_ID() call failed")?
        .as_u64();
    let sl = bh
        .settlement_layer(chain_id.into())
        .call()
        .await
        .context("bridgehub.settlementLayer() call failed")?
        .as_u64();
    anyhow::ensure!(
        sl != 0 && sl != l1_chain_id,
        "chain {chain_id} settles on L1 (settlementLayer={sl}, L1_CHAIN_ID={l1_chain_id}) — \
         not migrated to a gateway"
    );
    Ok(sl)
}

/// Resolve `bridgehub.owner()` → governance contract address.
///
/// The bridgehub's owner is the Governance contract (set during ecosystem
/// deployment via `transferOwnership`).
pub async fn resolve_governance(l1_rpc_url: &str, bridgehub: Address) -> anyhow::Result<Address> {
    let bh = BridgehubAbi::new(bridgehub, provider(l1_rpc_url)?);
    let gov = bh
        .owner()
        .call()
        .await
        .context("bridgehub.owner() call failed")?;
    ensure_nonzero(gov, "bridgehub.owner()")
}

/// Resolve `ChainAdmin(chain.admin).owner()` → EOA that controls the chain's
/// ChainAdmin contract.
///
/// For forge `--sender` / Safe-bundle `from` we need an EOA, not the
/// ChainAdmin contract itself (which has no private key and doesn't hold
/// the deployer's resources like ZK tokens).
pub async fn resolve_chain_admin_owner(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<Address> {
    let admin = resolve_chain_admin(l1_rpc_url, bridgehub, chain_id).await?;
    // Reuse `BridgehubAbi.owner()` — selector 0x8da5cb5b is OZ Ownable
    // standard, shared by every Ownable including ChainAdmin.
    let ownable = BridgehubAbi::new(admin, provider(l1_rpc_url)?);
    let eoa = ownable
        .owner()
        .call()
        .await
        .with_context(|| format!("ChainAdmin({admin:#x}).owner() call failed"))?;
    ensure_nonzero(eoa, "ChainAdmin.owner()")
}

/// Resolve `Governance(bridgehub.owner()).owner()` → EOA that controls the
/// Governance contract.
///
/// For forge `--sender` / Safe-bundle `from` we need an EOA, not the Governance
/// contract itself (which has no private key). One Ownable hop past
/// `resolve_governance` gets us there.
pub async fn resolve_governance_owner(
    l1_rpc_url: &str,
    bridgehub: Address,
) -> anyhow::Result<Address> {
    let gov = resolve_governance(l1_rpc_url, bridgehub).await?;
    // Reuse `BridgehubAbi.owner()` — the selector (0x8da5cb5b) is the OZ
    // Ownable standard, shared by every Ownable contract including Governance.
    let ownable = BridgehubAbi::new(gov, provider(l1_rpc_url)?);
    let eoa = ownable
        .owner()
        .call()
        .await
        .with_context(|| format!("Governance({gov:#x}).owner() call failed"))?;
    ensure_nonzero(eoa, "Governance.owner()")
}

/// Resolve `bridgehub.admin()` → bridgehub admin EOA / Safe address.
///
/// The Bridgehub's admin is a separate role from its owner: `onlyAdmin`
/// gates chain-registration-scoped operations (e.g. `addChainTypeManager`,
/// `registerChain`) while `onlyOwner` gates deeper governance changes. Most
/// bootstrap flows need this address because their bundle includes at
/// least one `onlyAdmin`-gated tx (e.g. `register_ctm`).
pub async fn resolve_bridgehub_admin(
    l1_rpc_url: &str,
    bridgehub: Address,
) -> anyhow::Result<Address> {
    let bh = BridgehubAbi::new(bridgehub, provider(l1_rpc_url)?);
    let admin = bh
        .admin()
        .call()
        .await
        .context("bridgehub.admin() call failed")?;
    ensure_nonzero(admin, "bridgehub.admin()")
}

/// Resolve `bridgehub.getZKChain(chainId)` → diamond proxy address.
pub async fn resolve_zk_chain(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<Address> {
    let bh = BridgehubAbi::new(bridgehub, provider(l1_rpc_url)?);
    let diamond = bh
        .get_zk_chain(chain_id.into())
        .call()
        .await
        .context("bridgehub.getZKChain() call failed")?;
    ensure_nonzero(diamond, &format!("bridgehub.getZKChain({chain_id})"))
}

/// Resolve the post-v29 `ValidatorTimelock` address for a given chain.
///
/// bridgehub → CTM (via `chainTypeManager(chainId)`) →
/// `validatorTimelockPostV29()`. The v29+ timelock is the one with per-chain
/// role granularity (`addValidatorForChainId`, `hasRoleForChainId`, …) —
/// all admin-action paths in this tool target that contract.
pub async fn resolve_validator_timelock(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<Address> {
    let ctm = resolve_ctm_proxy(l1_rpc_url, bridgehub, chain_id).await?;
    let ctm_ifc = IChainTypeManagerAbi::new(ctm, provider(l1_rpc_url)?);
    let vt = ctm_ifc
        .validator_timelock_post_v29()
        .call()
        .await
        .context("ctm.validatorTimelockPostV29() call failed")?;
    ensure_nonzero(vt, "ctm.validatorTimelockPostV29()")
}

/// Resolve a chain's admin: `IZKChain(bridgehub.getZKChain(chainId)).getAdmin()`.
///
/// The result is the `ChainAdmin` contract that gates every admin-only facet
/// call on that chain (e.g. `scheduleUpgrade`, `updateValidator`). Every
/// prepare-shape admin action therefore lets the caller omit it and auto-
/// discovers it from the bridgehub + chain id pair.
pub async fn resolve_chain_admin(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<Address> {
    let diamond = resolve_zk_chain(l1_rpc_url, bridgehub, chain_id).await?;
    let zk_chain = ZkChainAbi::new(diamond, provider(l1_rpc_url)?);
    let admin = zk_chain
        .get_admin()
        .call()
        .await
        .with_context(|| format!("zkChain({:#x}).getAdmin() call failed", diamond))?;
    ensure_nonzero(admin, &format!("zkChain({:#x}).getAdmin()", diamond))
}

/// Resolve `zkChain.getRollupDAManager()` → RollupDAManager address.
pub async fn resolve_rollup_da_manager(
    l1_rpc_url: &str,
    zk_chain: Address,
) -> anyhow::Result<Address> {
    let chain = ZkChainAbi::new(zk_chain, provider(l1_rpc_url)?);
    let manager = chain
        .get_rollup_da_manager()
        .call()
        .await
        .context("zkChain.getRollupDAManager() call failed")?;
    ensure_nonzero(manager, "zkChain.getRollupDAManager()")
}

/// Resolve `ctm.isZKsyncOS()` → bool.
pub async fn resolve_is_zksync_os(l1_rpc_url: &str, ctm_proxy: Address) -> anyhow::Result<bool> {
    let ctm = IChainTypeManagerAbi::new(ctm_proxy, provider(l1_rpc_url)?);
    ctm.is_z_ksync_os()
        .call()
        .await
        .context("ctm.isZKsyncOS() call failed")
}

/// Resolve whether the current verifier is a testnet verifier by querying
/// `IS_TESTNET_VERIFIER()` on the verifier contract.
///
/// Returns `false` if the verifier doesn't expose this constant (production
/// verifiers or older deployments).
pub async fn resolve_is_testnet_verifier(
    l1_rpc_url: &str,
    ctm_proxy: Address,
) -> anyhow::Result<bool> {
    let p = provider(l1_rpc_url)?;
    let ctm = IChainTypeManagerAbi::new(ctm_proxy, p.clone());

    let version = ctm
        .protocol_version()
        .call()
        .await
        .context("ctm.protocolVersion() call failed")?;
    let verifier = ctm
        .protocol_version_verifier(version)
        .call()
        .await
        .context("ctm.protocolVersionVerifier() call failed")?;
    ensure_nonzero(verifier, "ctm.protocolVersionVerifier()")?;

    let verifier = TestnetVerifierAbi::new(verifier, p);
    // Production verifiers and older deployments may not expose this constant.
    Ok(verifier.is_testnet_verifier().call().await.unwrap_or(false))
}
