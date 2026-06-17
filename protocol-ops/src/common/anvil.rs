use alloy::node_bindings::AnvilInstance;
use alloy::primitives::Address;
use alloy::providers::Provider;
use anyhow::Context;
use serde_json::json;

use crate::common::ethereum::get_provider;

/// Start anvil forking the given RPC URL with auto-impersonation enabled.
///
/// Auto-impersonation is on because simulate-mode forge runs always use
/// `--sender X --unlocked` — the fork must sign for arbitrary addresses.
///
/// The fork intentionally inherits the parent chain ID. Several deployment
/// scripts read `block.chainid` while generating calldata, so overriding it
/// would produce bundles for the wrong source chain.
pub fn start_anvil_fork(fork_url: &str) -> anyhow::Result<AnvilInstance> {
    alloy::node_bindings::Anvil::new()
        .fork(fork_url)
        .arg("--auto-impersonate")
        // Scripts like bridgehub multicalls can exceed the 30M default block
        // gas limit; lift it so simulations don't spuriously OOG.
        .arg("--disable-block-gas-limit")
        .try_spawn()
        .context("failed to spawn anvil — is it installed?")
}

/// Give `address` a fat ETH balance on an anvil fork via `anvil_setBalance`.
///
/// Used to unblock auto-resolved senders that are contracts (e.g. Governance,
/// the bridgehub admin Safe) or EOAs with insufficient ETH on the forked
/// chain. Only safe against anvil — real L1 rejects the call.
pub async fn set_balance(rpc_url: &str, address: Address) -> anyhow::Result<()> {
    let provider = get_provider(rpc_url)?;
    // 10 000 ETH is plenty for any deployment / multicall the Solidity
    // scripts do. Raw hex-encoded u256 to match anvil's expected format.
    const FUNDING_WEI_HEX: &str = "0x21e19e0c9bab2400000"; // 10_000 * 1e18
    provider
        .raw_request::<_, serde_json::Value>(
            "anvil_setBalance".into(),
            json!([format!("{address:#x}"), FUNDING_WEI_HEX]),
        )
        .await
        .with_context(|| format!("anvil_setBalance({address:#x}) failed against {rpc_url}"))?;
    Ok(())
}

/// Bump anvil's L1 timestamp by `seconds` and mine a new block so the
/// increase is reflected in subsequent calls' `block.timestamp`. Used to
/// step over `GovernanceUpgradeTimer` deadlines between v31 stage 0 and
/// stage 1 governance replays — stage 1's `checkDeadline()` requires
/// `block.timestamp >= deadline` set by stage 0.
pub async fn evm_increase_time_and_mine(rpc_url: &str, seconds: u64) -> anyhow::Result<()> {
    let provider = get_provider(rpc_url)?;
    provider
        .raw_request::<_, serde_json::Value>("evm_increaseTime".into(), json!([seconds]))
        .await
        .with_context(|| format!("evm_increaseTime({seconds}) failed against {rpc_url}"))?;
    provider
        .raw_request::<_, serde_json::Value>("evm_mine".into(), json!([]))
        .await
        .with_context(|| format!("evm_mine failed against {rpc_url}"))?;
    Ok(())
}

/// Take an EVM state snapshot via `evm_snapshot`. Returns the snapshot id
/// (hex-encoded uint256) to pass back to [`evm_revert`].
///
/// Anvil supports both `evm_snapshot` (geth-style) and `anvil_snapshot`; we
/// use the geth-style name since reth/hardhat-node accept it too.
pub async fn evm_snapshot(rpc_url: &str) -> anyhow::Result<String> {
    let provider = get_provider(rpc_url)?;
    let id: serde_json::Value = provider
        .raw_request("evm_snapshot".into(), json!([]))
        .await
        .with_context(|| format!("evm_snapshot failed against {rpc_url}"))?;
    let id_str = id
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("evm_snapshot returned non-string: {id}"))?
        .to_string();
    Ok(id_str)
}

/// Revert the EVM state to a prior snapshot. Note: anvil discards the
/// snapshot after revert, so each snapshot id is single-use.
pub async fn evm_revert(rpc_url: &str, snapshot_id: &str) -> anyhow::Result<()> {
    let provider = get_provider(rpc_url)?;
    let ok: bool = provider
        .raw_request("evm_revert".into(), json!([snapshot_id]))
        .await
        .with_context(|| format!("evm_revert({snapshot_id}) failed against {rpc_url}"))?;
    anyhow::ensure!(
        ok,
        "evm_revert({snapshot_id}) returned false — snapshot not found / already consumed"
    );
    Ok(())
}

/// Send a transaction via `eth_sendTransaction` from `sender` against an
/// anvil fork with auto-impersonate enabled. Bypasses forge entirely so the
/// tx does NOT land in any forge broadcast log (and therefore not in any
/// downstream Safe-bundle JSON), while still mutating the fork state.
///
/// Use this to apply governance-style calls on the prepare fork to bring
/// it into a "post-stage-N" state without polluting the deployer's bundle.
///
/// Reverts on the wire are surfaced as `anyhow::Error` (receipt status != 1).
pub async fn send_impersonated_tx(
    rpc_url: &str,
    sender: Address,
    to: Address,
    data: alloy::primitives::Bytes,
    gas_limit: u64,
) -> anyhow::Result<alloy::primitives::B256> {
    use alloy::network::TransactionBuilder;
    use alloy::rpc::types::TransactionRequest;

    let provider = get_provider(rpc_url)?;

    // Explicit `from` keys impersonation on anvil's `--auto-impersonate` path.
    let req = TransactionRequest::default()
        .with_from(sender)
        .with_to(to)
        .with_input(data)
        .with_value(alloy::primitives::U256::ZERO)
        .with_gas_limit(gas_limit);

    let pending = provider.send_transaction(req).await.with_context(|| {
        format!("eth_sendTransaction (impersonated {sender:#x} → {to:#x}) failed")
    })?;
    let tx_hash = *pending.tx_hash();
    let receipt = pending
        .get_receipt()
        .await
        .with_context(|| format!("await receipt for impersonated tx {tx_hash:#x}"))?;
    anyhow::ensure!(
        receipt.status(),
        "impersonated tx {tx_hash:#x} reverted ({sender:#x} → {to:#x})",
    );
    Ok(tx_hash)
}

#[cfg(test)]
mod tests {
    #[test]
    fn start_anvil_fork_does_not_override_parent_chain_id() {
        let source = include_str!("anvil.rs");
        let forbidden_builder = [".chain", "_id("].concat();

        assert!(
            !source.contains(&forbidden_builder),
            "forked Anvil must inherit the parent chain id because scripts use block.chainid in generated calldata"
        );
    }
}
