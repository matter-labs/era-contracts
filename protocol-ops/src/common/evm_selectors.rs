//! Function-selector extraction from deployed EVM bytecode.
//!
//! Mirrors `Utils.getAllSelectors` in `l1-contracts/deploy-scripts`, which is
//! what the deploy scripts use to build a diamond cut: every selector the
//! runtime dispatcher answers, minus `getName()`.

use std::collections::HashSet;

/// `getName()` — present on every facet for tooling, deliberately excluded
/// from diamond cuts by `Utils.getAllSelectors`.
pub const GET_NAME_SELECTOR: [u8; 4] = [0x17, 0xd7, 0xde, 0x7c];

/// Selectors a facet's deployed bytecode dispatches on, excluding `getName()`.
pub fn facet_selectors_from_bytecode(bytecode: &[u8]) -> HashSet<[u8; 4]> {
    evmole::contract_info(evmole::ContractInfoArgs::new(bytecode).with_selectors())
        .functions
        .unwrap_or_default()
        .into_iter()
        .map(|function| function.selector)
        .filter(|selector| selector != &GET_NAME_SELECTOR)
        .collect()
}
