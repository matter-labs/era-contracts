use ethers::{abi::encode, types::{Address, H256, U256}, utils::keccak256};
use crate::system_contracts::L2_NATIVE_TOKEN_VAULT_ADDRESS;

pub fn encode_ntv_asset_id(l1_chain_id: U256, addr: Address) -> H256 {
    let encoded_data = encode(&[
        ethers::abi::Token::Uint(l1_chain_id),
        ethers::abi::Token::Address(L2_NATIVE_TOKEN_VAULT_ADDRESS),
        ethers::abi::Token::Address(addr),
    ]);
    H256(keccak256(&encoded_data))
}
