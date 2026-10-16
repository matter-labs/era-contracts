//! The enum-indexed proxy inventories an upgrade carries — a core transition's ecosystem rows,
//! an operation's or a bootstrap's CTM-domain rows — held against live state, the same way on
//! every path.
//!
//! Each participating row (a non-zero `implNew`) answers three questions:
//!
//! 1. Is its proxy the contract its SLOT names? Slot `i` of an inventory is enum member `i`
//!    (`L1EcosystemContract`, `CTMContract`), and that member's proxy is discovered from live state
//!    the package does not supply: the ecosystem's through the Bridgehub and the getters it exposes,
//!    the CTM domain's through the CTM ([`discover_slot_proxy`]). A row whose proxy is another
//!    contract would install the slot's implementation behind the wrong proxy.
//! 2. Does it depart from the implementation that is LIVE? It is read through the applying
//!    domain's bound `ProxyAdmin`, the one `ProxyUpgradeRowLib` applies it through: a transparent
//!    proxy answers `implementation()` only to its own admin, and every proxy a row may name sits
//!    under its domain's.
//! 3. Does its `implNew` run the reviewed build of the slot's contract
//!    ([`super::provenance::expect_code_identity`])?

use alloy::primitives::Address;
use alloy::providers::Provider;

use crate::upgrade_verification::constants::{CTM_CONTRACTS, L1_ECOSYSTEM_CONTRACTS};
use crate::upgrade_verification::report::VerificationResult;

use super::construction::ReviewedBuild;
use super::provenance::{expect_code_identity, tolerate};
use super::views::{
    BridgehubView, CtmView, L1AssetRouterView, L1NullifierView, ProxyAdminView, ProxyUpgradeRow,
};

/// Which enum indexes an inventory.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Inventory {
    /// `L1EcosystemContract`: a core transition's `proxyUpgrades`, applied through the ecosystem
    /// `ProxyAdmin`.
    Ecosystem,
    /// `CTMContract`: an operation's `ctmInfrastructure` or a bootstrap's `ctmProxyUpgrades`,
    /// applied through the CTM-domain `ProxyAdmin`.
    CtmDomain,
}

impl Inventory {
    fn enum_name(self) -> &'static str {
        match self {
            Self::Ecosystem => "L1EcosystemContract",
            Self::CtmDomain => "CTMContract",
        }
    }

    fn members(self) -> &'static [&'static str] {
        match self {
            Self::Ecosystem => &L1_ECOSYSTEM_CONTRACTS,
            Self::CtmDomain => &CTM_CONTRACTS,
        }
    }

    /// The contracts the implementation behind `member`'s proxy may be. Empty for a member that
    /// is no proxy of the domain: a row there can never apply.
    pub(super) fn implementations(self, member: &str) -> &'static [&'static str] {
        match (self, member) {
            (Self::Ecosystem, "L1Bridgehub") => &["L1Bridgehub"],
            (Self::Ecosystem, "L1ChainAssetHandler") => &["L1ChainAssetHandler"],
            (Self::Ecosystem, "L1MessageRoot") => &["L1MessageRoot"],
            (Self::Ecosystem, "L1Nullifier") => &["L1Nullifier"],
            (Self::Ecosystem, "L1AssetRouter") => &["L1AssetRouter"],
            (Self::Ecosystem, "L1NativeTokenVault") => &["L1NativeTokenVault"],
            (Self::Ecosystem, "L1InteropHandler") => &["L1InteropHandler"],
            (Self::Ecosystem, "CTMDeploymentTracker") => &["CTMDeploymentTracker"],
            (Self::Ecosystem, "ChainRegistrationSender") => &["ChainRegistrationSender"],
            (Self::CtmDomain, "ChainTypeManager") => &["ChainTypeManager"],
            // A fresh CTM deploys its timelock as the multisig committer (`DeployCTM`).
            (Self::CtmDomain, "ValidatorTimelock") => &["MultisigCommitter", "ValidatorTimelock"],
            (Self::CtmDomain, "BytecodesSupplier") => &["BytecodesSupplier"],
            (Self::CtmDomain, "PermissionlessValidator") => &["PermissionlessValidator"],
            (Self::CtmDomain, "ServerNotifier") => &["ServerNotifier"],
            (Self::CtmDomain, "L1InteropFeeManager") => &["L1InteropFeeManager"],
            _ => &[],
        }
    }
}

/// The proxy `member`'s slot must name, read from live state through `anchor` — the Bridgehub for
/// the ecosystem, the CTM for its domain. `Ok(None)` for a member that is no proxy of the domain;
/// `Err` says why the proxy could not be read.
pub(super) async fn discover_slot_proxy<P: Provider>(
    provider: &P,
    inventory: Inventory,
    member: &str,
    anchor: Address,
) -> Result<Option<Address>, String> {
    fn read<T>(outcome: Result<T, impl std::fmt::Display>, what: &str) -> Result<T, String> {
        outcome.map_err(|e| format!("{what} could not be read ({e})"))
    }
    let bridgehub = BridgehubView::new(anchor, provider);
    let ctm = CtmView::new(anchor, provider);
    let asset_router = || async {
        read(
            bridgehub.assetRouter().call().await,
            "the Bridgehub's assetRouter()",
        )
    };
    let nullifier = || async {
        let router = asset_router().await?;
        read(
            L1AssetRouterView::new(router, provider)
                .L1_NULLIFIER()
                .call()
                .await,
            "the asset router's L1_NULLIFIER()",
        )
    };
    let address = match (inventory, member) {
        (Inventory::Ecosystem, "L1Bridgehub") => anchor,
        (Inventory::Ecosystem, "L1ChainAssetHandler") => read(
            bridgehub.chainAssetHandler().call().await,
            "the Bridgehub's chainAssetHandler()",
        )?,
        (Inventory::Ecosystem, "L1MessageRoot") => read(
            bridgehub.messageRoot().call().await,
            "the Bridgehub's messageRoot()",
        )?,
        (Inventory::Ecosystem, "L1Nullifier") => nullifier().await?,
        (Inventory::Ecosystem, "L1AssetRouter") => asset_router().await?,
        (Inventory::Ecosystem, "L1NativeTokenVault") => read(
            L1AssetRouterView::new(asset_router().await?, provider)
                .nativeTokenVault()
                .call()
                .await,
            "the asset router's nativeTokenVault()",
        )?,
        (Inventory::Ecosystem, "L1InteropHandler") => read(
            L1NullifierView::new(nullifier().await?, provider)
                .l1InteropHandler()
                .call()
                .await,
            "the nullifier's l1InteropHandler()",
        )?,
        (Inventory::Ecosystem, "CTMDeploymentTracker") => read(
            bridgehub.l1CtmDeployer().call().await,
            "the Bridgehub's l1CtmDeployer()",
        )?,
        (Inventory::Ecosystem, "ChainRegistrationSender") => read(
            bridgehub.chainRegistrationSender().call().await,
            "the Bridgehub's chainRegistrationSender()",
        )?,
        (Inventory::CtmDomain, "ChainTypeManager") => anchor,
        (Inventory::CtmDomain, "ValidatorTimelock") => read(
            ctm.validatorTimelockPostV29().call().await,
            "the CTM's validatorTimelockPostV29()",
        )?,
        (Inventory::CtmDomain, "BytecodesSupplier") => read(
            ctm.L1_BYTECODES_SUPPLIER().call().await,
            "the CTM's L1_BYTECODES_SUPPLIER()",
        )?,
        (Inventory::CtmDomain, "PermissionlessValidator") => read(
            ctm.PERMISSIONLESS_VALIDATOR().call().await,
            "the CTM's PERMISSIONLESS_VALIDATOR()",
        )?,
        (Inventory::CtmDomain, "L1InteropFeeManager") => read(
            ctm.L1_INTEROP_FEE_MANAGER().call().await,
            "the CTM's L1_INTEROP_FEE_MANAGER()",
        )?,
        (Inventory::CtmDomain, "ServerNotifier") => read(
            ctm.serverNotifierAddress().call().await,
            "the CTM's serverNotifierAddress()",
        )?,
        _ => return Ok(None),
    };
    Ok(Some(address))
}

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

/// One inventory, as a verifier holds it against live state.
pub(super) struct InventoryReview<'a> {
    pub(super) inventory: Inventory,
    /// The whole enum-indexed array, inert slots included: a row's slot is its index.
    pub(super) rows: &'a [ProxyUpgradeRow],
    /// The `ProxyAdmin` the domain applies its rows through.
    pub(super) domain_admin: Address,
    /// Where the slots' proxies are discovered from: the Bridgehub for the ecosystem, the CTM for
    /// its domain. `None` when it could not be established (already reported); every slot is
    /// then unverified.
    pub(super) anchor: Option<Address>,
    /// A slot whose proxy is not yet under `domain_admin`, so its departure cannot be read through
    /// it (the bootstrap's ServerNotifier before its handover, reported by the caller).
    pub(super) departure_unreadable: Option<usize>,
}

/// Holds every participating row of an inventory to its slot, its departure and its new
/// implementation's code. Returns how many rows participate.
///
/// Reads, per participating row: its slot's proxy through the anchor, the live implementation
/// through the domain admin, then the `implNew`'s code.
pub(super) async fn verify_inventory<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &InventoryReview<'_>,
) -> anyhow::Result<usize> {
    let inventory = review.inventory;
    let members = inventory.members();
    if review.rows.len() != members.len() {
        result.report_error(&format!(
            "the {} inventory has {} slot(s) but the enum has {}: its slots cannot be named, and \
             the reviewed objects refuse such an inventory at construction",
            inventory.enum_name(),
            review.rows.len(),
            members.len()
        ));
    }
    let mut participating = 0;
    for (slot, row) in review.rows.iter().enumerate() {
        if row.implNew.is_zero() {
            continue;
        }
        participating += 1;
        let Some(member) = members.get(slot) else {
            result.report_error(&format!(
                "{} slot {slot} ({}) lies beyond the enum this verifier knows: what it upgrades \
                 cannot be named",
                inventory.enum_name(),
                row.proxy
            ));
            continue;
        };
        let label = format!("{}.{member} row ({})", inventory.enum_name(), row.proxy);
        let implementations = inventory.implementations(member);
        if implementations.is_empty() {
            result.report_error(&format!(
                "{label}: {member} is no proxy of its domain, so a row in its slot can never \
                 apply"
            ));
            continue;
        }

        expect_slot_proxy(provider, result, review, &label, member, row.proxy).await;

        if review.departure_unreadable == Some(slot) {
            result.print_info(&format!(
                "  {label} is not source-checked: its proxy is not under {} yet, so its \
                 implementation cannot be read through it",
                review.domain_admin
            ));
        } else {
            verify_departure(provider, result, &label, row, review.domain_admin).await;
        }

        expect_code_identity(
            provider,
            build,
            result,
            &format!("{label} implNew"),
            row.implNew,
            implementations,
        )
        .await?;
    }
    Ok(participating)
}

/// The row's proxy against the one its slot's member resolves to on chain.
async fn expect_slot_proxy<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    review: &InventoryReview<'_>,
    label: &str,
    member: &str,
    proxy: Address,
) {
    let Some(anchor) = review.anchor else {
        result.report_error(&format!(
            "{label}: the {} {member} cannot be discovered, so the row's proxy is held against \
             nothing",
            match review.inventory {
                Inventory::Ecosystem => "ecosystem's",
                Inventory::CtmDomain => "CTM domain's",
            }
        ));
        return;
    };
    match discover_slot_proxy(provider, review.inventory, member, anchor).await {
        Ok(Some(discovered)) if discovered == proxy => {
            result.report_ok(&format!("{label} names the live {member} {discovered}"))
        }
        Ok(Some(discovered)) => result.report_error(&format!(
            "{label} names proxy {proxy}, but the live {member} is {discovered}: the row would \
             install {member}'s implementation behind another contract"
        )),
        Ok(None) => result.report_error(&format!(
            "{label}: {member} has no proxy to discover, so the row's proxy is held against \
             nothing"
        )),
        Err(why) => result.report_error(&format!(
            "{label}: the live {member} cannot be discovered — {why}"
        )),
    }
}

/// The row must depart from the implementation that is LIVE, read through `domain_admin`.
///
/// A row at an unexpected implementation reverts the whole bundle on chain, so a mismatch here is
/// an upgrade that cannot execute, not a cosmetic drift. A row already at `implNew` is accepted as
/// the contracts accept it, with a warning: part of the upgrade has already happened.
async fn verify_departure<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    label: &str,
    row: &ProxyUpgradeRow,
    domain_admin: Address,
) {
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
        return;
    };
    match classify_row(live_impl, row) {
        RowVerdict::Departs => {
            result.report_ok(&format!(
                "{label} departs from the live implementation (read through {domain_admin})"
            ));
        }
        RowVerdict::AlreadyApplied => {
            result.report_warn(&format!(
                "{label} is ALREADY at its new implementation {}: the row is a no-op, so part of \
                 this upgrade has already been applied",
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
}

/// How many slots of an inventory participate.
pub(super) fn participating(rows: &[ProxyUpgradeRow]) -> usize {
    rows.iter().filter(|row| !row.implNew.is_zero()).count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::constants::CTM_CONTRACT_SERVER_NOTIFIER_SLOT;
    use crate::upgrade_verification::registry::provenance::CodeIdentity;
    use alloy::primitives::Bytes;
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    const DOMAIN_ADMIN: Address = Address::repeat_byte(0xAD);
    const CTM: Address = Address::repeat_byte(0xC7);
    const NOTIFIER: Address = Address::repeat_byte(0x5E);
    const OLD: Address = Address::repeat_byte(0x01);
    const NEW: Address = Address::repeat_byte(0x02);
    const OTHER: Address = Address::repeat_byte(0x03);
    const NOTIFIER_RUNTIME: &[u8] = b"the reviewed ServerNotifier runtime";
    const CTM_RUNTIME: &[u8] = b"the reviewed ChainTypeManager runtime";

    fn slot_of(member: &str) -> usize {
        CTM_CONTRACTS.iter().position(|m| *m == member).unwrap()
    }

    fn row(proxy: Address) -> ProxyUpgradeRow {
        ProxyUpgradeRow {
            proxy,
            expectedOldImpl: OLD,
            implNew: NEW,
            callInitializeUpgrade: false,
        }
    }

    fn inert() -> ProxyUpgradeRow {
        ProxyUpgradeRow {
            proxy: Address::ZERO,
            expectedOldImpl: Address::ZERO,
            implNew: Address::ZERO,
            callInitializeUpgrade: false,
        }
    }

    /// A CTM-domain inventory with one participating row in `member`'s slot.
    fn inventory(member: &str, proxy: Address) -> Vec<ProxyUpgradeRow> {
        let mut rows = vec![inert(); CTM_CONTRACTS.len()];
        rows[slot_of(member)] = row(proxy);
        rows
    }

    fn build() -> ReviewedBuild {
        ReviewedBuild::from_artifacts(
            CodeIdentity::empty().with_contract("l1-contracts/ChainTypeManager", CTM_RUNTIME),
            vec![
                (
                    "ServerNotifier.sol",
                    "ServerNotifier",
                    Vec::new(),
                    NOTIFIER_RUNTIME.to_vec(),
                    Vec::new(),
                ),
                (
                    "ChainTypeManager.sol",
                    "ChainTypeManager",
                    Vec::new(),
                    CTM_RUNTIME.to_vec(),
                    Vec::new(),
                ),
            ],
        )
    }

    #[test]
    fn a_row_is_classified_by_the_on_chain_semantics() {
        assert_eq!(classify_row(OLD, &row(NOTIFIER)), RowVerdict::Departs);
        assert_eq!(
            classify_row(NEW, &row(NOTIFIER)),
            RowVerdict::AlreadyApplied
        );
        assert_eq!(classify_row(OTHER, &row(NOTIFIER)), RowVerdict::Mismatch);
    }

    /// The mirror is decoded positionally, so it must encode exactly as the Solidity struct: four
    /// static words and no fifth (`admin`) field.
    #[test]
    fn a_row_encodes_as_the_four_field_solidity_struct() {
        assert_eq!(row(NOTIFIER).abi_encode().len(), 4 * 32);
    }

    /// Every member a row may name has an implementation list, and every implementation the
    /// lists admit is a member artifact the build loads.
    #[test]
    fn every_proxy_slot_admits_loaded_implementations() {
        let loaded: Vec<&str> = super::super::members::MEMBER_ARTIFACTS
            .iter()
            .map(|(_, name)| *name)
            .collect();
        for member in L1_ECOSYSTEM_CONTRACTS {
            let admitted = Inventory::Ecosystem.implementations(member);
            assert!(!admitted.is_empty(), "{member} has no implementation");
            assert!(admitted.iter().all(|name| loaded.contains(name)));
        }
        for member in [
            "ChainTypeManager",
            "ValidatorTimelock",
            "BytecodesSupplier",
            "PermissionlessValidator",
            "ServerNotifier",
            "L1InteropFeeManager",
        ] {
            let admitted = Inventory::CtmDomain.implementations(member);
            assert!(!admitted.is_empty(), "{member} has no implementation");
            assert!(admitted.iter().all(|name| loaded.contains(name)));
        }
        assert!(Inventory::CtmDomain
            .implementations("MailboxFacet")
            .is_empty());
    }

    /// Drives the reporting path over a mocked transport: per participating row, the slot's
    /// discovered proxy (`serverNotifierAddress()`), the live implementation through the domain
    /// admin, and the `implNew`'s code.
    async fn run(
        rows: &[ProxyUpgradeRow],
        answers: &[Bytes],
        departure_unreadable: Option<usize>,
    ) -> VerificationResult {
        let asserter = Asserter::new();
        for answer in answers {
            asserter.push_success(answer);
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        verify_inventory(
            &provider,
            &build(),
            &mut result,
            &InventoryReview {
                inventory: Inventory::CtmDomain,
                rows,
                domain_admin: DOMAIN_ADMIN,
                anchor: Some(CTM),
                departure_unreadable,
            },
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty(), "every answer was read");
        result
    }

    fn addr(a: Address) -> Bytes {
        Bytes::from(a.abi_encode())
    }

    #[tokio::test]
    async fn a_row_in_its_slot_departing_live_onto_reviewed_code_is_clean() {
        let result = run(
            &inventory("ServerNotifier", NOTIFIER),
            &[
                addr(NOTIFIER),
                addr(OLD),
                Bytes::from_static(NOTIFIER_RUNTIME),
            ],
            None,
        )
        .await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// The slot is the CTM's notifier, the row names another proxy: the implementation would be
    /// installed behind the wrong contract.
    #[tokio::test]
    async fn a_row_naming_another_proxy_than_its_slot_fails() {
        let result = run(
            &inventory("ServerNotifier", OTHER),
            &[
                addr(NOTIFIER),
                addr(OLD),
                Bytes::from_static(NOTIFIER_RUNTIME),
            ],
            None,
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.ensure_success().is_err());
    }

    /// The CTM's own slot is discovered as the CTM itself: no read.
    #[tokio::test]
    async fn the_ctm_slot_is_the_ctm() {
        let result = run(
            &inventory("ChainTypeManager", CTM),
            &[addr(OLD), Bytes::from_static(CTM_RUNTIME)],
            None,
        )
        .await;
        assert_eq!(result.errors, 0);
        let result = run(
            &inventory("ChainTypeManager", OTHER),
            &[addr(OLD), Bytes::from_static(CTM_RUNTIME)],
            None,
        )
        .await;
        assert_eq!(result.errors, 1);
    }

    /// The implementation the row installs must be the slot's contract: reviewed code of another
    /// contract fails, and so does unknown code.
    #[tokio::test]
    async fn an_implementation_that_is_not_the_slots_contract_fails() {
        for code in [CTM_RUNTIME, b"unknown code".as_slice()] {
            let result = run(
                &inventory("ServerNotifier", NOTIFIER),
                &[addr(NOTIFIER), addr(OLD), Bytes::copy_from_slice(code)],
                None,
            )
            .await;
            assert_eq!(result.errors, 1);
        }
    }

    #[tokio::test]
    async fn a_row_already_applied_is_a_warning_and_an_unknown_departure_fails() {
        let result = run(
            &inventory("ServerNotifier", NOTIFIER),
            &[
                addr(NOTIFIER),
                addr(NEW),
                Bytes::from_static(NOTIFIER_RUNTIME),
            ],
            None,
        )
        .await;
        assert_eq!((result.errors, result.warnings), (0, 1));
        let result = run(
            &inventory("ServerNotifier", NOTIFIER),
            &[
                addr(NOTIFIER),
                addr(OTHER),
                Bytes::from_static(NOTIFIER_RUNTIME),
            ],
            None,
        )
        .await;
        assert_eq!(result.errors, 1);
    }

    /// The bootstrap's notifier before its handover: its departure is not read, its slot and
    /// its implementation still are.
    #[tokio::test]
    async fn an_unreadable_departure_still_checks_the_slot_and_the_implementation() {
        let result = run(
            &inventory("ServerNotifier", NOTIFIER),
            &[addr(NOTIFIER), Bytes::from_static(NOTIFIER_RUNTIME)],
            Some(CTM_CONTRACT_SERVER_NOTIFIER_SLOT),
        )
        .await;
        assert_eq!(result.errors, 0);
    }

    /// A row in a slot that names no proxy of the domain can never apply, and nothing is read
    /// for it.
    #[tokio::test]
    async fn a_row_in_a_non_proxy_slot_fails() {
        let result = run(&inventory("MailboxFacet", OTHER), &[], None).await;
        assert_eq!(result.errors, 1);
    }

    /// An inventory whose length is not the enum's is not one the objects accept.
    #[tokio::test]
    async fn an_inventory_of_the_wrong_length_fails() {
        let result = run(&vec![inert(); 3], &[], None).await;
        assert_eq!(result.errors, 1);
    }

    /// Without an anchor the slot cannot be discovered: an error, never a pass.
    #[tokio::test]
    async fn an_undiscoverable_slot_fails() {
        let asserter = Asserter::new();
        asserter.push_success(&addr(OLD));
        asserter.push_success(&Bytes::from_static(NOTIFIER_RUNTIME));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter);
        let mut result = VerificationResult::default();
        verify_inventory(
            &provider,
            &build(),
            &mut result,
            &InventoryReview {
                inventory: Inventory::CtmDomain,
                rows: &inventory("ServerNotifier", NOTIFIER),
                domain_admin: DOMAIN_ADMIN,
                anchor: None,
                departure_unreadable: None,
            },
        )
        .await
        .unwrap();
        assert_eq!(result.errors, 1);
    }

    /// Every proxy slot of both inventories, one participating row at a time: the row passes when
    /// it names the discovered proxy and installs the slot's contract, and fails — exactly once —
    /// when it names any other proxy.
    #[tokio::test]
    async fn every_slot_holds_its_row_to_the_discovered_proxy() {
        const DISCOVERED: Address = Address::repeat_byte(0xD5);
        /// The reads discovering `member`'s proxy before the last one names it.
        fn discovery_reads(member: &str) -> usize {
            match member {
                "L1Bridgehub" | "ChainTypeManager" => 0,
                "L1Nullifier" | "L1NativeTokenVault" => 2,
                "L1InteropHandler" => 3,
                _ => 1,
            }
        }
        let runtime = |name: &str| format!("the reviewed {name} runtime").into_bytes();
        let mut artifacts = Vec::new();
        for (_, name) in super::super::members::MEMBER_ARTIFACTS {
            artifacts.push((*name, *name, Vec::new(), runtime(name), Vec::new()));
        }
        let build = ReviewedBuild::from_artifacts(CodeIdentity::empty(), artifacts);
        let slots = L1_ECOSYSTEM_CONTRACTS
            .iter()
            .map(|m| (Inventory::Ecosystem, *m))
            .chain(
                CTM_CONTRACTS
                    .iter()
                    .filter(|m| !Inventory::CtmDomain.implementations(m).is_empty())
                    .map(|m| (Inventory::CtmDomain, *m)),
            );
        let mut checked = 0;
        for (inventory, member) in slots {
            for (proxy, errors) in [(DISCOVERED, 0), (OTHER, 1)] {
                let members = inventory.members();
                let mut rows = vec![inert(); members.len()];
                rows[members.iter().position(|m| *m == member).unwrap()] = row(proxy);
                let asserter = Asserter::new();
                for _ in 0..discovery_reads(member) {
                    asserter.push_success(&addr(DISCOVERED));
                }
                asserter.push_success(&addr(OLD));
                asserter.push_success(&Bytes::from(runtime(inventory.implementations(member)[0])));
                let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
                let mut result = VerificationResult::default();
                verify_inventory(
                    &provider,
                    &build,
                    &mut result,
                    &InventoryReview {
                        inventory,
                        rows: &rows,
                        domain_admin: DOMAIN_ADMIN,
                        anchor: Some(DISCOVERED),
                        departure_unreadable: None,
                    },
                )
                .await
                .unwrap();
                assert!(
                    asserter.read_q().is_empty(),
                    "{member}: every read was made"
                );
                assert_eq!(result.errors, errors, "{member} naming {proxy}");
            }
            checked += 1;
        }
        assert_eq!(checked, L1_ECOSYSTEM_CONTRACTS.len() + 6);
    }

    /// The ecosystem slots resolve through the Bridgehub and the contracts it links, in the order
    /// the reads are made: the nullifier through the asset router, the interop handler through
    /// the nullifier.
    #[tokio::test]
    async fn the_ecosystem_slots_resolve_through_the_bridgehub() {
        const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
        const ROUTER: Address = Address::repeat_byte(0xB1);
        const NULLIFIER: Address = Address::repeat_byte(0xB2);
        const HANDLER: Address = Address::repeat_byte(0xB3);
        let discover = |answers: Vec<Address>, member: &'static str| async move {
            let asserter = Asserter::new();
            for answer in &answers {
                asserter.push_success(&addr(*answer));
            }
            let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
            let found = discover_slot_proxy(&provider, Inventory::Ecosystem, member, BRIDGEHUB)
                .await
                .unwrap();
            assert!(asserter.read_q().is_empty());
            found
        };
        assert_eq!(discover(vec![], "L1Bridgehub").await, Some(BRIDGEHUB));
        assert_eq!(discover(vec![ROUTER], "L1AssetRouter").await, Some(ROUTER));
        assert_eq!(
            discover(vec![ROUTER, NULLIFIER], "L1Nullifier").await,
            Some(NULLIFIER)
        );
        assert_eq!(
            discover(vec![ROUTER, NULLIFIER, HANDLER], "L1InteropHandler").await,
            Some(HANDLER)
        );
    }
}
