use rlp::RlpStream;
use std::fs;
use zksync_state::interface::IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID;
use zksync_types::fee::Fee;
use zksync_types::l2::L2Tx;
use zksync_types::transaction_request::{PaymasterParams, TransactionRequest};
use zksync_types::web3::Bytes;
use zksync_types::{
    abi, address_to_u256, Address, K256PrivateKey, L2ChainId, Nonce, PackedEthSignature,
    Transaction, EIP_1559_TX_TYPE, H256, L2_ASSET_TRACKER_ADDRESS, PRIORITY_OPERATION_L2_TX_TYPE,
    REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_BYTE, U256,
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
    let signature = PackedEthSignature::sign_raw(key, &msg).expect("Failed to sign EIP-1559 tx");
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

/// Each fixture owns its addresses — unfunded and codeless — so its effects show up in balances.
const L1_TX_SENDER: u64 = 0xf0001;
const L1_TX_TARGET: u64 = 0xf0002;
const L1_TX_REFUND_RECIPIENT: u64 = 0xf0003;
const L1_FEE_TX_SENDER: u64 = 0xf0011;
const L1_FEE_TX_TARGET: u64 = 0xf0012;
const L1_FEE_TX_REFUND_RECIPIENT: u64 = 0xf0013;
/// Value transferred by both L1->L2 fixtures.
const L1_TX_VALUE: u64 = 1_000_000;
/// Well under `MAX_GAS_PER_TRANSACTION`, so `reservedGas` is zero and only execution decides the
/// refund.
const L1_TX_GAS_LIMIT: u64 = 20_000_000;
/// Non-zero, so `payToOperator` is not identically zero and force-fail billing is visible.
const L1_FEE_TX_GAS_PRICE: u64 = 100;
const L1_REVERT_TX_SENDER: u64 = 0xf0021;
const L1_REVERT_TX_REFUND_RECIPIENT: u64 = 0xf0023;
/// No function matches it on the target, so the call reverts on its first instruction.
const UNKNOWN_SELECTOR: [u8; 4] = [0xde, 0xad, 0xbe, 0xef];

/// An L1->L2 transaction transferring its whole `value` to a fresh address. With
/// `max_fee_per_gas = 0` the operator is paid nothing, so balances do not depend on gas burned.
fn generate_l1_transaction(
    sender: u64,
    target: Address,
    refund_recipient: u64,
    max_fee_per_gas: u64,
    calldata: Vec<u8>,
) -> Transaction {
    let sender = Address::from_low_u64_be(sender);
    let refund_recipient = Address::from_low_u64_be(refund_recipient);
    let value = U256::from(L1_TX_VALUE);
    let gas_limit = U256::from(L1_TX_GAS_LIMIT);
    let max_fee_per_gas = U256::from(max_fee_per_gas);

    let tx = abi::Transaction::L1 {
        tx: abi::L2CanonicalTransaction {
            tx_type: PRIORITY_OPERATION_L2_TX_TYPE.into(),
            from: address_to_u256(&sender),
            to: address_to_u256(&target),
            gas_limit,
            gas_per_pubdata_byte_limit: REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_BYTE.into(),
            max_fee_per_gas,
            max_priority_fee_per_gas: U256::zero(),
            paymaster: U256::zero(),
            // Serial id of the priority operation.
            nonce: U256::one(),
            value,
            reserved: [
                // `mintValue`
                gas_limit * max_fee_per_gas + value,
                address_to_u256(&refund_recipient),
                U256::zero(),
                U256::zero(),
            ],
            data: calldata,
            signature: vec![],
            factory_deps: vec![],
            paymaster_input: vec![],
            reserved_dynamic: vec![],
        }
        .into(),
        factory_deps: vec![],
        eth_block: 0,
    };

    let mut tx = Transaction::from_abi(tx, false).expect("Failed to build the L1->L2 fixture");
    // `from_abi` stamps the current time, which would make the fixture differ on every run.
    tx.received_timestamp_ms = 0;
    tx
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
        0xb5, 0xb1, 0x87, 0x0d, 0x4a, 0x32, 0x0e, 0x3a, 0x2b, 0x9c, 0x4f, 0x6e, 0x8d, 0x7a, 0x1c,
        0x5f, 0x3b, 0x6e, 0x2d, 0x9a, 0x8c, 0x7f, 0x1e, 0x4d, 0x6b, 0x3a, 0x5c, 0x9e, 0x2f, 0x8d,
        0x7b, 0x4a,
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

    let tx2 = generate_l1_transaction(
        L1_TX_SENDER,
        Address::from_low_u64_be(L1_TX_TARGET),
        L1_TX_REFUND_RECIPIENT,
        0,
        vec![],
    );
    write_transaction(dir, 2, &tx2);

    let tx3 = generate_l1_transaction(
        L1_FEE_TX_SENDER,
        Address::from_low_u64_be(L1_FEE_TX_TARGET),
        L1_FEE_TX_REFUND_RECIPIENT,
        L1_FEE_TX_GAS_PRICE,
        vec![],
    );
    write_transaction(dir, 3, &tx3);

    // Reverts in the target, which is what force-fail has to be indistinguishable from.
    let tx4 = generate_l1_transaction(
        L1_REVERT_TX_SENDER,
        L2_ASSET_TRACKER_ADDRESS,
        L1_REVERT_TX_REFUND_RECIPIENT,
        0,
        UNKNOWN_SELECTOR.to_vec(),
    );
    write_transaction(dir, 4, &tx4);

    println!("Done. Generated 5 test transactions.");
}
