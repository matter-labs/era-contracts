/// Reverts whose selector proves the effect already happened skip outright;
/// `OperationMustBePending` (either spelling) is deferred to a Governance
/// state check; everything else — including the `b926a6b0` value the old
/// list carried, which is no known selector — is left alone.
#[test]
fn classify_revert_separates_done_from_ambiguous_and_unknown() {
    use super::RevertClass;
    let wrap = |sel: &str| {
        format!("server returned an error response: error code 3: execution reverted, data: \"0x{sel}00000000000000000000000000000000000000000000000000000000deadbeef\"")
    };
    assert_eq!(
        super::classify_revert(&wrap("1a21feed")),
        RevertClass::AlreadyDone("OperationExists")
    );
    assert_eq!(
        super::classify_revert(&wrap("876E8B23")),
        RevertClass::AlreadyDone("EraBytecodeAlreadyPublished")
    );
    assert_eq!(
        super::classify_revert(&wrap("61733a89")),
        RevertClass::AlreadyDone("EVMBytecodeAlreadyPublished")
    );
    assert_eq!(
        super::classify_revert(&wrap("0dfb42bf")),
        RevertClass::AlreadyDone("AddressAlreadySet")
    );
    assert_eq!(
        super::classify_revert(&wrap("eda2fbb1")),
        RevertClass::GovernanceOperationNotPending
    );
    assert_eq!(
        super::classify_revert("execution reverted: Operation must be pending"),
        RevertClass::GovernanceOperationNotPending
    );
    assert_eq!(
        super::classify_revert(&wrap("b926a6b0")),
        RevertClass::Unknown
    );
    assert_eq!(
        super::classify_revert("execution reverted: Ownable: caller is not the owner"),
        RevertClass::Unknown
    );
}

const JOURNAL_FROM: &str = "0xab75e283274247b43a1f220885850ebefa399b88";
const JOURNAL_TO: &str = "0x7e7bc292a71b73cebe77633937ddad3dc1f80ed2";
const JOURNAL_DATA: &str =
    "0xf2fde38b000000000000000000000000000000000000000000000000000000000000dead";

/// A journal entry as the executor writes it (lowercase addresses, decimal
/// value); `from` optional so legacy entries can be modelled.
fn journal_entry(
    from: Option<&str>,
    to: &str,
    data: &str,
    value: &str,
    status: u64,
) -> super::ExecutedTx {
    super::ExecutedTx {
        tx_hash: format!("0x{}", "11".repeat(32)),
        to: to.to_string(),
        data: data.to_string(),
        value: value.to_string(),
        status,
        from: from.map(str::to_string),
        ..Default::default()
    }
}

fn full_entry() -> super::ExecutedTx {
    journal_entry(Some(JOURNAL_FROM), JOURNAL_TO, JOURNAL_DATA, "0", 1)
}

/// The call as the executor sees it: checksummed addresses, as a Safe TX
/// Builder file spells them.
fn safe_call() -> (
    alloy::primitives::Address,
    alloy::primitives::Address,
    alloy::primitives::Bytes,
) {
    let from = "0xaB75E283274247b43a1f220885850ebEFa399B88"
        .parse()
        .unwrap();
    let to = "0x7E7bc292A71B73CeBE77633937dDaD3dc1f80ED2"
        .parse()
        .unwrap();
    let data = alloy::primitives::Bytes::from(
        alloy::hex::decode(JOURNAL_DATA.trim_start_matches("0x")).unwrap(),
    );
    (from, to, data)
}

/// The journal spells addresses lowercase and the value in decimal; the
/// Safe file may not. Matching is on parsed values. A legacy entry without
/// a recorded signer matches on the call alone (the receipt's `from` is
/// checked on chain instead).
#[test]
fn journal_entry_matches_ignores_spelling_and_accepts_legacy_entries() {
    let (from, to, data) = safe_call();
    let value = alloy::primitives::U256::ZERO;
    assert!(super::journal_entry_matches(
        &full_entry(),
        from,
        to,
        &data,
        value
    ));
    let mut hex_value = full_entry();
    hex_value.value = "0x0".to_string();
    assert!(super::journal_entry_matches(
        &hex_value, from, to, &data, value
    ));
    let legacy = journal_entry(None, JOURNAL_TO, JOURNAL_DATA, "0", 1);
    assert!(super::journal_entry_matches(
        &legacy, from, to, &data, value
    ));
}

/// A reverted entry, another signer, or a different target / calldata /
/// value is not an execution of this call.
#[test]
fn journal_entry_matches_rejects_reverted_and_different_calls() {
    let (from, to, data) = safe_call();
    let value = alloy::primitives::U256::ZERO;
    let rejects = |label: &str, entry: super::ExecutedTx| {
        assert!(
            !super::journal_entry_matches(&entry, from, to, &data, value),
            "{label} must not match"
        );
    };
    let mut e = full_entry();
    e.status = 0;
    rejects("reverted", e);
    let mut e = full_entry();
    e.from = Some("0x0000000000000000000000000000000000000001".to_string());
    rejects("other signer", e);
    let mut e = full_entry();
    e.from = Some("not-an-address".to_string());
    rejects("garbage signer", e);
    let mut e = full_entry();
    e.to = "0x0000000000000000000000000000000000000001".to_string();
    rejects("other target", e);
    let mut e = full_entry();
    e.data = JOURNAL_DATA.replace("dead", "beef");
    rejects("other calldata", e);
    let mut e = full_entry();
    e.value = "1".to_string();
    rejects("other value", e);
}

/// One journal entry justifies one skip per run: two identical prior
/// entries serve two identical calls (in any bundle) and no more, and
/// entries appended by this run are never candidates.
#[test]
fn resume_journal_claims_each_prior_entry_once_and_ignores_new_entries() {
    let (from, to, data) = safe_call();
    let value = alloy::primitives::U256::ZERO;
    let mut journal = super::ResumeJournal {
        path: None,
        bundle: super::ExecutedBundle {
            transactions: vec![full_entry(), full_entry()],
        },
        prior: 2,
        claimed: vec![false, false],
    };
    assert_eq!(
        journal.next_prior_match_from(0, from, to, &data, value),
        Some(0)
    );
    journal.claimed[0] = true;
    assert_eq!(
        journal.next_prior_match_from(0, from, to, &data, value),
        Some(1)
    );
    journal.claimed[1] = true;
    assert_eq!(
        journal.next_prior_match_from(0, from, to, &data, value),
        None
    );
    // A receipt this run records is not a resume candidate.
    journal
        .record(alloy::primitives::B256::from([1_u8; 32]), full_entry())
        .unwrap();
    assert_eq!(journal.transactions().len(), 3);
    assert_eq!(
        journal.next_prior_match_from(0, from, to, &data, value),
        None
    );
    // Another signer's identical call finds nothing.
    let other: alloy::primitives::Address = "0x0000000000000000000000000000000000000001"
        .parse()
        .unwrap();
    journal.claimed = vec![false, false];
    assert_eq!(
        journal.next_prior_match_from(0, other, to, &data, value),
        None
    );
}

use std::fs;

use alloy::primitives::B256;
use tempfile::tempdir;

use super::{
    bump_gas, gwei_to_wei, load_executed_bundle, parse_gwei, record_executed_tx, ExecutedBundle,
    ExecutedTx, GAS_BUMP_BPS,
};

#[test]
fn gas_price_ceilings_parse_exactly_with_decimals() {
    assert_eq!(parse_gwei("500"), Ok(gwei_to_wei(500)));
    assert_eq!(parse_gwei("0.5"), Ok(500_000_000));
    assert_eq!(parse_gwei(".25"), Ok(250_000_000));
    assert_eq!(parse_gwei("2."), Ok(gwei_to_wei(2)));
    assert_eq!(parse_gwei("1.000000001"), Ok(1_000_000_001));
    assert_eq!(parse_gwei("0.000000001"), Ok(1));
    for bad in [
        "",
        ".",
        "0",
        "0.0",
        "-1",
        "+1",
        "1e9",
        " 0.5",
        "0.5 ",
        "1.0000000001",
        "1,5",
        "abc",
    ] {
        assert!(parse_gwei(bad).is_err(), "{bad:?} should be rejected");
    }
}

#[test]
fn the_cli_takes_a_fractional_ceiling() {
    use clap::Parser;
    let parse = |extra: &[&str]| {
        let mut argv = vec![
            "execute-safe",
            "--safe-file",
            "b.json",
            "--private-key",
            "0x01",
        ];
        argv.extend_from_slice(extra);
        super::DevExecuteSafeArgs::try_parse_from(argv)
    };
    assert_eq!(
        parse(&["--max-gas-price-gwei", "0.5"])
            .unwrap()
            .max_gas_price_wei,
        500_000_000
    );
    assert_eq!(parse(&[]).unwrap().max_gas_price_wei, gwei_to_wei(500));
    assert!(parse(&["--max-gas-price-gwei", "0"]).is_err());
}

#[test]
fn bump_gas_increases_by_at_least_the_replacement_threshold() {
    // +15% keeps replacements above geth's ≥10% requirement.
    let start = gwei_to_wei(10);
    let next = bump_gas(start, gwei_to_wei(500)).unwrap();
    assert_eq!(next, start * GAS_BUMP_BPS / 10_000);
    assert!(next >= start + start / 10, "bump must clear the +10% floor");
}

#[test]
fn bump_gas_is_strictly_monotonic_even_for_tiny_values() {
    // Integer rounding must never yield a no-op bump.
    assert_eq!(bump_gas(1, 1_000), Some(2));
    assert_eq!(bump_gas(7, 1_000), Some(8));
}

#[test]
fn bump_gas_caps_at_ceiling_then_stops() {
    let max = gwei_to_wei(100);
    // A bump that would overshoot is clamped to the ceiling...
    assert_eq!(bump_gas(gwei_to_wei(95), max), Some(max));
    // ...and once at/above the ceiling, no further bump is offered.
    assert_eq!(bump_gas(max, max), None);
    assert_eq!(bump_gas(max + 1, max), None);
}

#[test]
fn confirmed_receipts_are_journaled_immediately_and_survive_retries() {
    let dir = tempdir().unwrap();
    let out = dir.path().join("executed.json");
    let first_hash = B256::from([1_u8; 32]);
    let second_hash = B256::from([2_u8; 32]);
    let first = ExecutedTx {
        tx_hash: format!("{first_hash:#x}"),
        to: "0x1111111111111111111111111111111111111111".to_string(),
        data: "0x01".to_string(),
        value: "0".to_string(),
        status: 1,
        ..Default::default()
    };
    let second = ExecutedTx {
        tx_hash: format!("{second_hash:#x}"),
        to: "0x2222222222222222222222222222222222222222".to_string(),
        data: "0x02".to_string(),
        value: "0".to_string(),
        status: 1,
        ..Default::default()
    };

    let mut first_run = ExecutedBundle::default();
    record_executed_tx(&out, &mut first_run, first_hash, first.clone()).unwrap();
    assert_eq!(
        load_executed_bundle(Some(&out)).unwrap().transactions,
        vec![first.clone()]
    );

    // Simulate a new process after the first bundle attempt failed.
    let mut retry = load_executed_bundle(Some(&out)).unwrap();
    record_executed_tx(&out, &mut retry, second_hash, second.clone()).unwrap();
    assert_eq!(
        load_executed_bundle(Some(&out)).unwrap().transactions,
        vec![first, second]
    );

    let hashes = fs::read_to_string(dir.path().join("transactions.txt")).unwrap();
    assert_eq!(
        hashes.lines().collect::<Vec<_>>(),
        vec![format!("{first_hash:#x}"), format!("{second_hash:#x}")]
    );
}

/// EIP-7825 caps a tx at 2^24 gas. Estimates whose 25% buffer used to land
/// between the cap and the old 20M limit (refused at send) now get the cap;
/// smaller estimates keep their full buffer.
#[test]
fn buffered_gas_limit_stays_within_the_eip7825_cap() {
    const BLOCK: u64 = 60_000_000;
    assert_eq!(super::PER_TX_GAS_LIMIT_CAP, 16_777_216);
    assert_eq!(super::buffered_gas_limit(1_000_000, BLOCK), 1_250_000);
    assert_eq!(super::buffered_gas_limit(13_421_772, BLOCK), 16_777_215);
    assert_eq!(super::buffered_gas_limit(14_000_000, BLOCK), 16_777_216);
    assert_eq!(super::buffered_gas_limit(16_777_216, BLOCK), 16_777_216);
}

/// Under Glamsterdam (EIP-8037) a deploy's state gas lets its estimate
/// exceed 2^24; the buffer then stops at the block gas limit, and never
/// goes below the estimate itself.
#[test]
fn buffered_gas_limit_above_the_cap_is_bounded_by_the_block() {
    const BLOCK: u64 = 60_000_000;
    assert_eq!(super::buffered_gas_limit(16_777_217, BLOCK), 20_971_521);
    assert_eq!(super::buffered_gas_limit(29_109_458, BLOCK), 36_386_822);
    assert_eq!(super::buffered_gas_limit(55_000_000, BLOCK), BLOCK);
    assert_eq!(super::buffered_gas_limit(BLOCK, BLOCK), BLOCK);
}

/// A spent nonce we never sent at (a stale pending nonce) is resent at the
/// next one. A spent nonce we did send at stops the run and names every hash:
/// one of them may have mined behind a lagging RPC, and a resend would
/// execute the call twice.
#[test]
fn a_spent_nonce_resends_only_calls_never_sent_at_it() {
    let to = alloy::primitives::Address::repeat_byte(0x11);
    assert!(super::nonce_spent_without_receipt(to, 7, &[]).is_ok());

    let sent = [B256::repeat_byte(0xaa), B256::repeat_byte(0xbb)];
    let err = super::nonce_spent_without_receipt(to, 7, &sent)
        .unwrap_err()
        .to_string();
    assert!(err.contains("nonce 7 was spent"), "{err}");
    assert!(err.contains("Not resending"), "{err}");
    for hash in sent {
        assert!(err.contains(&format!("{hash:#x}")), "{err}");
    }
}

/// A batch publish reverts on its first already-published member, so the
/// skip check splits it into single-bytecode publishes, one per member in
/// order, for both entry points. A single publish is decided by its own
/// revert, and unrelated calls are not batches.
#[test]
fn bytecode_batches_split_into_single_publishes() {
    use super::{
        publishEVMBytecodeCall, publishEVMBytecodesCall, publishEraBytecodeCall,
        publishEraBytecodesCall,
    };
    use alloy::primitives::Bytes;
    use alloy::sol_types::SolCall;

    let a = Bytes::from(vec![0xaa; 64]);
    let b = Bytes::from(vec![0xbb; 32]);
    let era_batch = publishEraBytecodesCall {
        _bytecodes: vec![a.clone(), b.clone()],
    }
    .abi_encode();
    assert_eq!(
        super::split_bytecode_batch(&era_batch).unwrap(),
        vec![
            Bytes::from(
                publishEraBytecodeCall {
                    _bytecode: a.clone()
                }
                .abi_encode()
            ),
            Bytes::from(
                publishEraBytecodeCall {
                    _bytecode: b.clone()
                }
                .abi_encode()
            ),
        ]
    );
    let evm_batch = publishEVMBytecodesCall {
        _bytecodes: vec![b.clone()],
    }
    .abi_encode();
    assert_eq!(
        super::split_bytecode_batch(&evm_batch).unwrap(),
        vec![Bytes::from(
            publishEVMBytecodeCall { _bytecode: b }.abi_encode()
        )]
    );

    let single = publishEraBytecodeCall { _bytecode: a }.abi_encode();
    assert!(super::split_bytecode_batch(&single).is_none());
    assert!(super::split_bytecode_batch(&[0x12, 0x34, 0x56, 0x78]).is_none());
}

/// `AddressAlreadySet(addr)` is a replay only when the call was setting
/// `addr`: a single-address setter, or `addVerifier(version, fflonk, plonk)`
/// naming it, skips. A call setting a different address, or a revert that
/// carries no address, does not.
#[test]
fn address_already_set_skips_only_for_the_same_address() {
    let set = "000000000000000000000000c16161c7f704388285fe58db287f6216a350dafa";
    let other = "0000000000000000000000001111111111111111111111111111111111111111";
    let version = "000000000000000000000000000000000000000000000000000000000000001f";
    let revert = format!(
            "server returned an error response: error code 3: execution reverted, data: \"0x0dfb42bf{set}\""
        );
    let call = |args: &[&str]| {
        let mut data = vec![0x12, 0x34, 0x56, 0x78];
        for arg in args {
            data.extend(alloy::hex::decode(arg).unwrap());
        }
        data
    };

    assert!(super::already_set_address_is_called(&revert, &call(&[set])));
    assert!(super::already_set_address_is_called(
        &revert,
        &call(&[version, other, set])
    ));
    assert!(!super::already_set_address_is_called(
        &revert,
        &call(&[other])
    ));
    assert!(!super::already_set_address_is_called(
        "execution reverted, data: \"0x0dfb42bf\"",
        &call(&[set])
    ));

    // anvil also decodes the error into the message, ahead of `data`.
    let anvil = format!(
            "server returned an error response: error code 3: execution reverted: custom error 0x0dfb42bf: {set}, data: \"0x0dfb42bf{set}\""
        );
    assert!(super::already_set_address_is_called(&anvil, &call(&[set])));
    assert!(!super::already_set_address_is_called(
        &anvil,
        &call(&[other])
    ));
}
