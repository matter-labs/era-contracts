use alloy::{
    hex,
    primitives::{Address, FixedBytes},
    sol_types::SolValue,
};

use super::super::elements::call_list::{CallList, UpgradeProposal};

pub(crate) fn encode_upgrade_data(encoded_calls: &str) -> String {
    let calls_list = CallList::parse(&encoded_calls);
    let upgrade_proposal = UpgradeProposal {
        calls: calls_list.elems,
        executor: Address::ZERO,
        salt: FixedBytes::<32>::ZERO,
    };

    hex::encode(upgrade_proposal.abi_encode())
}
