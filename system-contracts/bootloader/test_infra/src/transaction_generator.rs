use rlp::RlpStream;
use std::fs;
use zksync_state::interface::IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID;
use zksync_types::fee::Fee;
use zksync_types::l2::L2Tx;
use zksync_types::transaction_request::{PaymasterParams, TransactionRequest};
use zksync_types::web3::Bytes;
use zksync_types::{
    H256, K256PrivateKey, L2ChainId, Nonce, PackedEthSignature, Transaction, EIP_1559_TX_TYPE,
    U256,
};

fn generate_eip712_transaction(key: &K256PrivateKey, chain_id: L2ChainId) -> Transaction {
    let contract_address = zksync_types::Address::from_low_u64_be(0x1234567890abcdef);
    let calldata = vec![0xa4, 0x13, 0x68, 0x62, 0x00, 0x01, 0x02, 0x03];
    let fee = Fee {
        gas_limit: U256::from(1_000_000u64),
        max_fee_per_gas: U256::from(250_000_000u64),
        max_priority_fee_per_gas: U256::zero(),
        gas_per_pubdata_limit: U256::from(50_000u64),
    };

    let l2tx = L2Tx::new_signed(
        Some(contract_address),
        calldata,
        Nonce(0),
        fee,
        U256::zero(),
        chain_id,
        key,
        vec![],
        PaymasterParams::default(),
    )
    .expect("Failed to create signed EIP-712 transaction");

    Transaction::from(l2tx)
}

fn generate_eip1559_transaction(key: &K256PrivateKey, chain_id: L2ChainId) -> Transaction {
    let address = key.address();

    let mut tx_request = TransactionRequest {
        nonce: U256::from(1u32),
        from: Some(address),
        // `to = None` creates an EVM deployment-style transaction (`reserved1 == 1`).
        to: None,
        value: U256::zero(),
        gas_price: U256::from(250_000_000u64),
        max_priority_fee_per_gas: Some(U256::from(1u32)),
        gas: U256::from(1_000_000u64),
        // Very small init code so deployment data is non-empty.
        input: Bytes(vec![0x60, 0x00, 0x60, 0x00, 0xF3]),
        transaction_type: Some(EIP_1559_TX_TYPE.into()),
        chain_id: Some(chain_id.as_u64()),
        access_list: Some(Vec::new()),
        ..Default::default()
    };

    // Step 1: RLP-encode unsigned tx, prepend type byte
    let mut rlp_stream = RlpStream::new();
    tx_request
        .rlp(&mut rlp_stream, None)
        .expect("Failed to RLP-encode unsigned EIP-1559 tx");
    let mut unsigned_data = rlp_stream.out().to_vec();
    unsigned_data.insert(0, EIP_1559_TX_TYPE);

    // Step 2: Hash via message_to_signed_bytes
    let msg = PackedEthSignature::message_to_signed_bytes(&unsigned_data);

    // Step 3: Sign via sign_raw
    let signature =
        PackedEthSignature::sign_raw(key, &msg).expect("Failed to sign EIP-1559 tx");
    tx_request.raw = Some(Bytes(unsigned_data));

    // Step 4: RLP-encode signed tx, prepend type byte
    let mut rlp_signed = RlpStream::new();
    tx_request
        .rlp(&mut rlp_signed, Some(&signature))
        .expect("Failed to RLP-encode signed EIP-1559 tx");
    let mut signed_data = rlp_signed.out().to_vec();
    signed_data.insert(0, EIP_1559_TX_TYPE);

    // Step 5: Decode via from_bytes_unverified
    let (req, hash) = TransactionRequest::from_bytes_unverified(&signed_data)
        .expect("Failed to decode signed EIP-1559 tx");

    // Step 6: Convert to L2Tx then Transaction
    let mut l2tx = L2Tx::from_request(req, usize::MAX, true)
        .expect("Failed to convert EIP-1559 request to L2Tx");
    l2tx.set_input(signed_data, hash);

    Transaction::from(l2tx)
}

fn write_transaction(dir: &str, index: usize, tx: &Transaction) {
    let json = serde_json::to_string_pretty(tx).expect("Failed to serialize transaction to JSON");

    // Round-trip verification
    let _roundtrip: Transaction =
        serde_json::from_str(&json).expect("Round-trip deserialization failed");

    let path = format!("{}/{}.json", dir, index);
    fs::write(&path, &json).unwrap_or_else(|e| panic!("Failed to write {}: {}", path, e));
    println!("Wrote {}", path);
}

pub(crate) fn generate_transactions() {
    let key = K256PrivateKey::from_bytes(H256([
        0xb5, 0xb1, 0x87, 0x0d, 0x4a, 0x32, 0x0e, 0x3a, 0x2b, 0x9c, 0x4f, 0x6e, 0x8d, 0x7a,
        0x1c, 0x5f, 0x3b, 0x6e, 0x2d, 0x9a, 0x8c, 0x7f, 0x1e, 0x4d, 0x6b, 0x3a, 0x5c, 0x9e,
        0x2f, 0x8d, 0x7b, 0x4a,
    ]))
    .expect("Invalid private key bytes");

    // Must match IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID so that the chain_id in the
    // signed transactions matches the SystemContext chain_id in the VM storage.
    let chain_id = L2ChainId::from(IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID);

    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/src/test_transactions");
    fs::create_dir_all(dir).expect("Failed to create test_transactions directory");

    println!("Generating test transactions into {}", dir);

    let tx0 = generate_eip712_transaction(&key, chain_id);
    write_transaction(dir, 0, &tx0);

    let tx1 = generate_eip1559_transaction(&key, chain_id);
    write_transaction(dir, 1, &tx1);

    println!("Done. Generated 2 test transactions.");
}
