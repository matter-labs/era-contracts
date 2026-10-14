//! The proxy rows an upgrade carries, held against the implementation that is actually live —
//! the same read on both paths, the bootstrap edge and the recurring operation.
//!
//! A row is read through the applying domain's bound `ProxyAdmin`, the one `ProxyUpgradeRowLib`
//! applies it through: a transparent proxy answers `implementation()` only to its own admin, and
//! every proxy a row may name sits under its domain's.

use alloy::primitives::Address;
use alloy::providers::Provider;

use crate::upgrade_verification::report::VerificationResult;

use super::provenance::{expect_code_present, tolerate};
use super::views::{ProxyAdminView, ProxyUpgradeRow};

/// What a row's live implementation says about it — the on-chain row semantics
/// (`ProxyUpgradeRowLib`): a proxy at `expectedOldImpl` is upgraded, one already at `implNew` is
/// skipped, anything else reverts the whole governance bundle.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum RowVerdict {
    Departs,
    AlreadyApplied,
    Mismatch,
}

pub(super) fn classify_row(live_impl: Address, row: &ProxyUpgradeRow) -> RowVerdict {
    if live_impl == row.expectedOldImpl {
        RowVerdict::Departs
    } else if live_impl == row.implNew {
        RowVerdict::AlreadyApplied
    } else {
        RowVerdict::Mismatch
    }
}

/// Each participating row must depart from the implementation that is LIVE, read through
/// `domain_admin`.
///
/// A row at an unexpected implementation reverts the whole bundle on chain, so a mismatch here is
/// an upgrade that cannot execute, not a cosmetic drift. A row already at `implNew` is accepted
/// as the contracts accept it, with a warning: part of the upgrade has already happened.
pub(super) async fn verify_rows<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    kind: &str,
    rows: &[ProxyUpgradeRow],
    domain_admin: Address,
) -> anyhow::Result<()> {
    for (i, row) in rows.iter().enumerate() {
        let label = format!("{kind} {i} ({})", row.proxy);
        let Some(live_impl) = tolerate(
            ProxyAdminView::new(domain_admin, provider)
                .getProxyImplementation(row.proxy)
                .call()
                .await,
            result,
            &format!(
                "{label}: the live implementation of {} under {domain_admin}",
                row.proxy
            ),
        ) else {
            continue;
        };
        match classify_row(live_impl, row) {
            RowVerdict::Departs => {
                result.report_ok(&format!(
                    "{label} departs from the live implementation (read through {domain_admin})"
                ));
            }
            RowVerdict::AlreadyApplied => {
                result.report_warn(&format!(
                    "{label} is ALREADY at its new implementation {}: the row is a no-op, so \
                     part of this upgrade has already been applied",
                    row.implNew
                ));
            }
            RowVerdict::Mismatch => {
                result.report_error(&format!(
                    "{label} expects to depart from {} but {live_impl} is live (read through \
                     {domain_admin})",
                    row.expectedOldImpl
                ));
            }
        }
        expect_code_present(provider, result, &format!("{label} implNew"), row.implNew).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::Bytes;
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    const DOMAIN_ADMIN: Address = Address::repeat_byte(0xAD);
    const OLD: Address = Address::repeat_byte(0x01);
    const NEW: Address = Address::repeat_byte(0x02);
    const OTHER: Address = Address::repeat_byte(0x03);

    fn row() -> ProxyUpgradeRow {
        ProxyUpgradeRow {
            proxy: Address::repeat_byte(0x99),
            expectedOldImpl: OLD,
            implNew: NEW,
            callInitializeUpgrade: false,
        }
    }

    #[test]
    fn a_row_is_classified_by_the_on_chain_semantics() {
        assert_eq!(classify_row(OLD, &row()), RowVerdict::Departs);
        assert_eq!(classify_row(NEW, &row()), RowVerdict::AlreadyApplied);
        assert_eq!(classify_row(OTHER, &row()), RowVerdict::Mismatch);
    }

    /// The mirror is decoded positionally, so it must encode exactly as the Solidity struct: four
    /// static words and no fifth (`admin`) field.
    #[test]
    fn a_row_encodes_as_the_four_field_solidity_struct() {
        assert_eq!(row().abi_encode().len(), 4 * 32);
    }

    /// Drives the reporting path over a mocked transport: one `getProxyImplementation` answer
    /// and one `eth_getCode` answer for `implNew`, per row.
    async fn run(rows: &[ProxyUpgradeRow], live_impls: &[Address]) -> VerificationResult {
        let asserter = Asserter::new();
        for live in live_impls {
            asserter.push_success(&Bytes::from(live.abi_encode()));
            asserter.push_success(&Bytes::from_static(&[0x60, 0x00]));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        verify_rows(&provider, &mut result, "CTM-domain row", rows, DOMAIN_ADMIN)
            .await
            .unwrap();
        assert!(asserter.read_q().is_empty());
        result
    }

    #[tokio::test]
    async fn a_row_already_applied_is_a_warning_and_a_departing_row_is_clean() {
        let result = run(&[row()], &[NEW]).await;
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 1);
        let result = run(&[row()], &[OLD]).await;
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 0);
    }

    #[tokio::test]
    async fn a_row_at_an_unknown_implementation_fails_the_run() {
        let result = run(&[row()], &[OTHER]).await;
        assert_eq!(result.errors, 1);
        assert!(result.ensure_success().is_err());
    }
}
