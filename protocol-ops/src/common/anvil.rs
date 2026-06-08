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
/// The fork always uses chain ID 31337, overriding whatever the parent chain
/// reports. This is required because `ZKsyncOSTestnetVerifier` asserts
/// `block.chainid != 1`, so forking a mainnet-chain-ID Anvil would fail.
/// If the parent chain has chain ID 1, a warning is emitted.
pub fn start_anvil_fork(fork_url: &str) -> anyhow::Result<AnvilInstance> {
    if let Ok(parent_chain_id) = crate::common::ethereum::query_chain_id_sync(fork_url) {
        if parent_chain_id == 1 {
            crate::common::logger::warn(
                "Parent chain has chain ID 1 (mainnet). \
                 The simulation fork will use chain ID 31337 instead.\n\
                 If you are using a local Anvil, start it with: anvil --chain-id 31337",
            );
        }
    }

    alloy::node_bindings::Anvil::new()
        .fork(fork_url)
        .chain_id(31337)
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
