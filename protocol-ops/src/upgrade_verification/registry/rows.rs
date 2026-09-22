//! The proxy rows an upgrade carries, held against the implementation that is actually live —
//! the same read on both paths, the bootstrap edge and the recurring operation.
//!
//! A row is read through the admin that administers its proxy: its own `admin` when it names
//! one (the ServerNotifier row sits under a chain-admin-owned `ProxyAdmin`), the applying
//! executor's bound admin otherwise — the resolution `ProxyUpgradeRowLib.adminOf` performs on
//! chain. Reading a foreign-admin row through the domain admin would ask a non-admin, and a
//! transparent proxy answers a non-admin by falling through to its implementation.

use alloy::primitives::Address;
use alloy::providers::Provider;

use crate::upgrade_verification::report::VerificationResult;

use super::provenance::{expect_code_present, tolerate};
use super::views::{ProxyAdminView, ProxyUpgradeRow};

/// The admin a row is read (and, on chain, applied) through.
pub(super) fn admin_of(default_admin: Address, row: &ProxyUpgradeRow) -> Address {
    if row.admin.is_zero() {
        default_admin
    } else {
        row.admin
    }
}

/// What a row's live implementation says about it — the on-chain row semantics
/// (`ProxyUpgradeRowLib`): a proxy at `expectedOldImpl` is upgraded, one already at `implNew` is
/// skipped, anything else reverts the whole stage.
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

/// Each participating row must depart from the implementation that is LIVE, read through the
/// admin the row itself names (or `default_admin` when it names none).
///
/// A row at an unexpected implementation reverts the whole stage on chain, so a mismatch here is
/// an upgrade that cannot execute, not a cosmetic drift. A row already at `implNew` is accepted
/// as the contracts accept it: for a foreign-admin row that is the production order (its
/// administrator applies it before the bundle), for a bound-admin row it means part of the
/// upgrade has already happened and is worth a warning.
pub(super) async fn verify_rows<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    kind: &str,
    rows: &[ProxyUpgradeRow],
    default_admin: Address,
) -> anyhow::Result<()> {
    for (i, row) in rows.iter().enumerate() {
        let admin = admin_of(default_admin, row);
        let label = format!("{kind} {i} ({})", row.proxy);
        let Some(live_impl) = tolerate(
            ProxyAdminView::new(admin, provider)
                .getProxyImplementation(row.proxy)
                .call()
                .await,
            result,
            &format!(
                "{label}: the live implementation of {} under {admin}",
                row.proxy
            ),
        ) else {
            continue;
        };
        match classify_row(live_impl, row) {
            RowVerdict::Departs => {
                result.report_ok(&format!(
                    "{label} departs from the live implementation (read through {admin})"
                ));
            }
            RowVerdict::AlreadyApplied if !row.admin.is_zero() => {
                result.report_ok(&format!(
                    "{label} is ALREADY at its new implementation {}, applied by its own \
                     administrator {admin} ahead of the bundle — the production order for a row \
                     the executor does not own; the executor skips it and the completion gate \
                     still requires it",
                    row.implNew
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
                     {admin})",
                    row.expectedOldImpl
                ));
            }
        }
        expect_code_present(provider, result, &format!("{label} implNew"), row.implNew).await?;
        if !row.admin.is_zero() {
            result.report_warn(&format!(
                "{label} names a FOREIGN ProxyAdmin {}: the executor applies it only if it owns \
                 that admin, otherwise the row is left to that administrator and the completion \
                 gate still requires it applied",
                row.admin
            ));
        }
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
    const OWN_ADMIN: Address = Address::repeat_byte(0x0A);
    const OLD: Address = Address::repeat_byte(0x01);
    const NEW: Address = Address::repeat_byte(0x02);
    const OTHER: Address = Address::repeat_byte(0x03);

    fn row(admin: Address) -> ProxyUpgradeRow {
        ProxyUpgradeRow {
            proxy: Address::repeat_byte(0x99),
            expectedOldImpl: OLD,
            implNew: NEW,
            callInitializeUpgrade: false,
            admin,
        }
    }

    /// The admin resolution is `ProxyUpgradeRowLib.adminOf`: the row's own admin when it names
    /// one, the domain's otherwise. Reading the ServerNotifier row through the CTM-domain admin
    /// was the defect — that admin is not the proxy's admin, so the proxy answered with its
    /// implementation's fallthrough and a correct package failed.
    #[test]
    fn a_foreign_row_resolves_to_its_own_admin_and_a_bound_row_to_the_domains() {
        assert_eq!(admin_of(DOMAIN_ADMIN, &row(OWN_ADMIN)), OWN_ADMIN);
        assert_eq!(admin_of(DOMAIN_ADMIN, &row(Address::ZERO)), DOMAIN_ADMIN);
    }

    #[test]
    fn a_row_is_classified_by_the_on_chain_semantics() {
        assert_eq!(classify_row(OLD, &row(OWN_ADMIN)), RowVerdict::Departs);
        assert_eq!(
            classify_row(NEW, &row(OWN_ADMIN)),
            RowVerdict::AlreadyApplied
        );
        assert_eq!(classify_row(OTHER, &row(OWN_ADMIN)), RowVerdict::Mismatch);
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

    /// `test_migrate_acceptsForeignAdminRowAppliedByItsAdministratorFirst` on the Solidity side:
    /// the contracts accept a foreign-admin row already at `implNew`, so the verifier must too,
    /// and as the expected order rather than a warning.
    #[tokio::test]
    async fn a_foreign_row_already_applied_by_its_administrator_is_accepted() {
        let result = run(&[row(OWN_ADMIN)], &[NEW]).await;
        assert_eq!(result.errors, 0);
        // The one warning is the standing note that the row is foreign, not the applied state.
        assert_eq!(result.warnings, 1);
    }

    #[tokio::test]
    async fn a_bound_row_already_applied_is_a_warning_and_a_departing_row_is_clean() {
        let result = run(&[row(Address::ZERO)], &[NEW]).await;
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 1);
        let result = run(&[row(Address::ZERO)], &[OLD]).await;
        assert_eq!(result.errors, 0);
        assert_eq!(result.warnings, 0);
    }

    #[tokio::test]
    async fn a_row_at_an_unknown_implementation_fails_the_run() {
        let result = run(&[row(OWN_ADMIN)], &[OTHER]).await;
        assert_eq!(result.errors, 1);
        assert!(result.ensure_success().is_err());
    }
}
