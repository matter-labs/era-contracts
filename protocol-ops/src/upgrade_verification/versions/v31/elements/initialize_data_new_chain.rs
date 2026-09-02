use crate::upgrade_verification::verifiers::VerificationResult;

/// Verify the chain-creation diamond cut's `initCalldata` tail.
///
/// Since v34 the tail is empty: `InitializeDataNewChain` (the three EraVM bytecode
/// hashes, which ZKsync OS chains never used) was removed from the `DiamondInit` ABI.
/// `ChainTypeManagerBase` prepends the selector and all mandatory fields (chainId,
/// admin, bridgehub, …) at chain-creation time. The verifier is fetched from
/// `CTM.protocolVersionVerifier()` inside `DiamondInit`; fee params are hardcoded from
/// `Config.sol` constants — neither appears in `initCalldata`.
pub fn verify_chain_creation_init_calldata(init_calldata: &[u8], result: &mut VerificationResult) {
    if init_calldata.is_empty() {
        result.report_ok(
            "chain-creation initCalldata is empty (InitializeDataNewChain removed in v34)",
        );
    } else {
        result.report_error(&format!(
            "chain-creation initCalldata must be empty from v34 onwards, got {} bytes",
            init_calldata.len()
        ));
    }
}
