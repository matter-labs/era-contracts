//! `TxOriginAsserter.assertTxOrigin()`, the call a chain batch ends with on an environment that
//! configures an asserter (`[permanent_contracts] tx_origin_asserter_addr`). It reverts unless
//! `tx.origin` is the asserter's authority or, when the authority is a Safe, one of its owners.
//! A Safe batch can be sent by anyone who holds enough signatures; with this call as its last
//! one, only an authorized executor can.

use alloy::primitives::{Address, Bytes};
use alloy::providers::Provider;
use alloy::sol_types::SolCall;
use anyhow::Context;
use serde_json::json;

use crate::common::ethereum::get_provider;
use crate::common::forge::SafeBundle;

alloy::sol! {
    #[sol(rpc)]
    interface ITxOriginAsserter {
        function assertTxOrigin() external view;
        function authority() external view returns (address);
    }

    #[sol(rpc)]
    interface IAuthoritySafe {
        function getOwners() external view returns (address[] memory);
    }
}

/// Calldata of `assertTxOrigin()`.
pub fn assertion_calldata() -> Bytes {
    ITxOriginAsserter::assertTxOriginCall {}.abi_encode().into()
}

/// Whether `data` is exactly an `assertTxOrigin()` call.
pub fn is_assertion(data: &[u8]) -> bool {
    data == ITxOriginAsserter::assertTxOriginCall::SELECTOR.as_slice()
}

/// Append `assertTxOrigin()` on `asserter` to every bundle, sent by the bundle's own sender.
pub fn append_assertion(bundles: &mut [SafeBundle], asserter: Address, step: &str) {
    let to = asserter.to_checksum(None);
    let data = assertion_calldata().to_string();
    for bundle in bundles {
        bundle.txs.push(json!({
            "step": step,
            "from": bundle.target,
            "to": to,
            "data": data,
            "value": "0",
        }));
    }
}

/// An address `asserter` accepts as `tx.origin`: its authority when that is an EOA, otherwise the
/// first owner of the authority Safe.
///
/// A fork replay sends each transaction of a bundle from the bundle's sender, a Safe or the
/// account that owns it, so `tx.origin` would be that sender and the assertion would always
/// revert. Replays send the assertion from this address instead: that checks the asserter is
/// deployed and accepts an executor. It says nothing about who executes on L1.
pub async fn authorized_origin(rpc_url: &str, asserter: Address) -> anyhow::Result<Address> {
    let provider = get_provider(rpc_url)?;
    let authority = ITxOriginAsserter::new(asserter, provider.clone())
        .authority()
        .call()
        .await
        .with_context(|| format!("TxOriginAsserter {asserter:#x} authority()"))?;
    let code = provider
        .get_code_at(authority)
        .await
        .with_context(|| format!("eth_getCode({authority:#x})"))?;
    if code.is_empty() {
        return Ok(authority);
    }
    let owners = IAuthoritySafe::new(authority, provider)
        .getOwners()
        .call()
        .await
        .with_context(|| format!("authority {authority:#x} getOwners()"))?;
    owners.first().copied().with_context(|| {
        format!("the authority {authority:#x} of TxOriginAsserter {asserter:#x} has no owners")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ASSERTER: Address = Address::repeat_byte(0xaa);

    fn bundle(target: &str, tx_count: usize) -> SafeBundle {
        SafeBundle {
            target: target.to_string(),
            steps: vec!["chain.upgrade".to_string()],
            txs: (0..tx_count)
                .map(|_| json!({"step": "chain.upgrade", "from": target, "to": "0x01", "data": "0x", "value": "0"}))
                .collect(),
        }
    }

    /// Only zksync-os-mainnet configures an asserter, so only its chain batches end with the call.
    #[test]
    fn only_zksync_os_mainnet_configures_an_asserter() {
        use crate::common::env_config::EnvConfig;

        if crate::common::paths::resolve_l1_contracts_path().is_err() {
            return; // no checkout around the test binary
        }
        let asserter = |env: &str| EnvConfig::load(env).unwrap().tx_origin_asserter();
        assert_eq!(
            asserter("zksync-os-mainnet"),
            Some(alloy::primitives::address!(
                "123450011cb3166a63D4523B2496eCc1fea665BB"
            ))
        );
        for env in ["stage", "stage3", "testnet", "testnet3", "mainnet", "adi"] {
            assert_eq!(asserter(env), None, "{env}");
        }
    }

    #[test]
    fn the_assertion_is_described_by_what_it_checks() {
        use crate::common::call_description::{Describer, Names};

        let mut describer = Describer::new(Names::default(), None);
        assert_eq!(
            describer
                .describe_call(ASSERTER, &assertion_calldata())
                .unwrap(),
            "check that an authorized executor sends the batch (TxOriginAsserter.assertTxOrigin)"
        );
    }

    #[test]
    fn the_assertion_is_the_bare_selector() {
        assert_eq!(assertion_calldata().to_string(), "0xeafb2ef3");
        assert!(is_assertion(&assertion_calldata()));
        assert!(!is_assertion(&[0xea, 0xfb, 0x2e, 0xf3, 0x00]));
        assert!(!is_assertion(&[]));
    }

    #[test]
    fn every_bundle_ends_with_the_assertion_from_its_own_sender() {
        let mut bundles = vec![bundle("0x1111", 1), bundle("0x2222", 2)];
        append_assertion(&mut bundles, ASSERTER, "chain.upgrade");

        assert_eq!(bundles[0].txs.len(), 2);
        assert_eq!(bundles[1].txs.len(), 3);
        for bundle in &bundles {
            let last = bundle.txs.last().unwrap();
            assert_eq!(last["from"], bundle.target);
            assert_eq!(last["to"], ASSERTER.to_checksum(None));
            assert_eq!(last["data"], "0xeafb2ef3");
            assert_eq!(last["value"], "0");
            assert_eq!(last["step"], "chain.upgrade");
        }
        // The bundle's own transactions keep their place.
        assert_eq!(bundles[1].txs[0]["to"], "0x01");
    }
}
