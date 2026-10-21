//! The enum-indexed proxy inventories an upgrade carries — a Core-domain `ProxyUpgradeTransition`'s
//! ecosystem rows, a CTM-domain one's or a bootstrap's CTM-domain rows — held against live state,
//! the same way on every path.
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
//!    ([`super::provenance::expect_code_identity`])? For the `ChainTypeManager` slot also: does it
//!    carry the reviewed constructor immutables, which code identity masks ([`verify_ctm_immutables`])?
//! 4. Was its `implNew` built by the reviewed constructor from argument values the review holds
//!    ([`verify_inventory_construction`], [`super::member_construction`])? Every `implNew` is a
//!    deployment of the package's own prepare, so each needs a record — as does the
//!    implementation behind a CTM-domain proxy only the package reports, which a new CTM
//!    implementation's immutables are held against ([`verify_ctm_immutables`]).
//!
//! Before any of that, every participating row must be a real edge ([`row_shape_errors`]). The
//! row-carrying objects refuse a malformed row at construction too; this reports it before the
//! vote (`protocol-docs/ecosystem-upgrade.md#where-each-check-lives`).

use alloy::primitives::Address;
use alloy::providers::Provider;

use crate::upgrade_verification::constants::{
    CTM_CONTRACTS, EIP1967_IMPLEMENTATION_SLOT, EIP1967_PROXY_ADMIN_SLOT, L1_ECOSYSTEM_CONTRACTS,
    PROXY_UPGRADE_DOMAIN_CORE, PROXY_UPGRADE_DOMAIN_CTM,
};
use crate::upgrade_verification::report::VerificationResult;

use super::construction::{ReviewedBuild, REVIEWED_PROXY};
use super::member_construction::{expect_member_construction, ArgContext, Member, MemberReview};
use super::package::ReportedSingletons;
use super::provenance::{expect_code_identity, tolerate};
use super::views::{
    BridgehubView, CtmView, L1AssetRouterView, L1NullifierView, ProxyAdminView, ProxyUpgradeRow,
};

/// Which enum indexes an inventory — equivalently, which `ProxyUpgradeDomain` it belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Inventory {
    /// `L1EcosystemContract`: a Core-domain `ProxyUpgradeTransition`'s `proxyUpgrades`, applied
    /// through the ecosystem `ProxyAdmin`.
    Ecosystem,
    /// `CTMContract`: a CTM-domain `ProxyUpgradeTransition`'s `proxyUpgrades` or a bootstrap's
    /// `ctmProxyUpgrades`, applied through the CTM-domain `ProxyAdmin`.
    CtmDomain,
}

impl Inventory {
    /// The `ProxyUpgradeDomain` tag a `ProxyUpgradeTransition` carrying this inventory has.
    pub(super) fn domain_tag(self) -> u8 {
        match self {
            Self::Ecosystem => PROXY_UPGRADE_DOMAIN_CORE,
            Self::CtmDomain => PROXY_UPGRADE_DOMAIN_CTM,
        }
    }

    /// The `ProxyUpgradeDomain` member name of `tag`, for the report.
    pub(super) fn domain_name(tag: u8) -> String {
        match tag {
            PROXY_UPGRADE_DOMAIN_CORE => "Core".to_string(),
            PROXY_UPGRADE_DOMAIN_CTM => "CTM".to_string(),
            other => format!("unknown ({other})"),
        }
    }

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
/// skipped, anything else reverts the whole governance bundle. A self-edge
/// (`expectedOldImpl == implNew`) is skipped whatever is live, so it upgrades nothing.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum RowVerdict {
    Departs,
    AlreadyApplied,
    Mismatch,
    SelfEdge,
}

pub(super) fn classify_row(live_impl: Address, row: &ProxyUpgradeRow) -> RowVerdict {
    if row.implNew == row.expectedOldImpl {
        RowVerdict::SelfEdge
    } else if live_impl == row.expectedOldImpl {
        RowVerdict::Departs
    } else if live_impl == row.implNew {
        RowVerdict::AlreadyApplied
    } else {
        RowVerdict::Mismatch
    }
}

/// Why a participating row is not a real edge, judged from the row alone: a zero proxy, a zero
/// `expectedOldImpl`, a self-edge, or a proxy an earlier participating row already names (`earlier`
/// holds `(proxy, slot)` of those rows). Empty for a well-formed row.
fn row_shape_errors(row: &ProxyUpgradeRow, earlier: &[(Address, usize)]) -> Vec<String> {
    let mut errors = Vec::new();
    if row.proxy.is_zero() {
        errors.push(
            "names the zero address as its proxy: no implementation can be read there, so \
             applying it reverts the bundle"
                .to_string(),
        );
    }
    if row.expectedOldImpl.is_zero() {
        errors.push(
            "departs from the zero address, which no proxy runs: the row can only revert the \
             bundle, or be skipped when its proxy already runs `implNew`"
                .to_string(),
        );
    }
    if row.expectedOldImpl == row.implNew {
        errors.push(format!(
            "is a self-edge (`expectedOldImpl == implNew` == {}): `applyRows` skips it whatever is \
             live, so it upgrades nothing — omit the row or name the implementation it replaces",
            row.implNew
        ));
    }
    if let Some((_, slot)) = earlier.iter().find(|(proxy, _)| *proxy == row.proxy) {
        errors.push(format!(
            "names proxy {} a second time (slot {slot} names it too): the second row \
             source-checks against the state the first one left, and the post-pass requires the \
             proxy to run both rows' `implNew`",
            row.proxy
        ));
    }
    errors
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
    /// What the package reports for the Bridgehub and the CTM domain's singletons: the last
    /// fallbacks a new `ChainTypeManager` implementation's immutables are held against.
    pub(super) reported: ReportedSingletons,
}

/// An implementation whose code identity passed, for its construction check: a participating
/// row's `implNew`, or the implementation behind a proxy only the package reports.
pub(super) struct RowImplementation {
    label: String,
    address: Address,
    admitted: &'static [&'static str],
    identified: &'static str,
    /// Why the package's prepare must have deployed it.
    new_because: &'static str,
    /// The CTM row's immutables as [`verify_ctm_immutables`] established them.
    ctm_immutables: Option<CtmImmutableExpectations>,
}

/// The implementations [`verify_inventory`] identified.
pub(super) struct InventoryOutcome {
    implementations: Vec<RowImplementation>,
}

/// Why a row's `implNew` needs a record.
const ROW_IMPLEMENTATION_IS_NEW: &str =
    "a row installs only an implementation its prepare deployed";
/// Why the implementation behind a proxy only the package reports needs a record.
const REPORTED_IMPLEMENTATION_IS_NEW: &str =
    "the package introduces the proxy, so its prepare deployed the implementation behind it";

/// Holds every participating row of an inventory to its shape, its slot, its departure and its new
/// implementation's code. Returns the implementations whose code passed, for
/// [`verify_inventory_construction`].
///
/// Reads, per well-formed participating row: its slot's proxy through the anchor, the live
/// implementation through the domain admin, then the `implNew`'s code — and for the CTM row its
/// immutables ([`verify_ctm_immutables`]). A malformed row is reported and not read.
pub(super) async fn verify_inventory<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &InventoryReview<'_>,
) -> anyhow::Result<InventoryOutcome> {
    let inventory = review.inventory;
    let members = inventory.members();
    if review.rows.len() != members.len() {
        result.report_error(&format!(
            "the {} inventory has {} slot(s) but the enum has {}: its slots cannot be named, and \
             the object's constructor refuses such an inventory",
            inventory.enum_name(),
            review.rows.len(),
            members.len()
        ));
    }
    let mut implementations = Vec::new();
    let mut earlier: Vec<(Address, usize)> = Vec::new();
    for (slot, row) in review.rows.iter().enumerate() {
        if row.implNew.is_zero() {
            continue;
        }
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
        let admitted = inventory.implementations(member);
        if admitted.is_empty() {
            result.report_error(&format!(
                "{label}: {member} is no proxy of its domain, so a row in its slot can never \
                 apply"
            ));
            continue;
        }
        let shape = row_shape_errors(row, &earlier);
        earlier.push((row.proxy, slot));
        if !shape.is_empty() {
            for why in shape {
                result.report_error(&format!("{label} {why}"));
            }
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

        let identified = expect_code_identity(
            provider,
            build,
            result,
            &format!("{label} implNew"),
            row.implNew,
            admitted,
        )
        .await?;
        let (ctm_immutables, reported) = if inventory == Inventory::CtmDomain
            && *member == "ChainTypeManager"
        {
            let (established, reported) =
                verify_ctm_immutables(provider, build, result, review, &label, row.implNew).await?;
            (Some(established), reported)
        } else {
            (None, Vec::new())
        };
        if let Some(identified) = identified {
            implementations.push(RowImplementation {
                label: format!("{label} implNew"),
                address: row.implNew,
                admitted,
                identified,
                new_because: ROW_IMPLEMENTATION_IS_NEW,
                ctm_immutables,
            });
        }
        implementations.extend(reported);
    }
    Ok(InventoryOutcome { implementations })
}

/// Holds each implementation [`verify_inventory`] identified to its construction record. Each is
/// a deployment of the package's own prepare — a row exists only when the run replaces the live
/// implementation, and a proxy only the package reports is one it introduces — so none is carried
/// over.
pub(super) async fn verify_inventory_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    members: &MemberReview<'_>,
    outcome: &InventoryOutcome,
) -> anyhow::Result<()> {
    for implementation in &outcome.implementations {
        expect_member_construction(
            provider,
            build,
            result,
            members,
            Member {
                label: &implementation.label,
                address: implementation.address,
                admitted: implementation.admitted,
                identified: implementation.identified,
                carried_over: None,
                new_because: implementation.new_because,
                context: match &implementation.ctm_immutables {
                    Some(expectations) => ArgContext::CtmImmutables(expectations),
                    None => ArgContext::None,
                },
            },
        )
        .await?;
    }
    Ok(())
}

/// A `ChainTypeManager` constructor immutable: code identity masks its value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum CtmImmutable {
    BridgeHub,
    BytecodesSupplier,
    /// Written into every new chain once by `DiamondInit` and never re-read.
    PermissionlessValidator,
    InteropFeeManager,
}

/// The value each CTM immutable must have and where it comes from, as [`verify_ctm_immutables`]
/// established it; `None` where nothing does.
pub(super) type CtmImmutableExpectations = Vec<(CtmImmutable, Option<(Address, String)>)>;

/// Where the value an immutable must have comes from when the live CTM does not answer it.
enum Fallback {
    /// A value the review holds outright, and where it comes from.
    Known(Address, String),
    /// A proxy the package reports for the immutable's CTM-domain slot, under `field`, which the
    /// review must first establish on chain.
    Reported {
        proxy: Address,
        member: &'static str,
        field: &'static str,
    },
    None,
}

impl CtmImmutable {
    const ALL: [Self; 4] = [
        Self::BridgeHub,
        Self::BytecodesSupplier,
        Self::PermissionlessValidator,
        Self::InteropFeeManager,
    ];

    pub(super) fn getter(self) -> &'static str {
        match self {
            Self::BridgeHub => "BRIDGE_HUB",
            Self::BytecodesSupplier => "L1_BYTECODES_SUPPLIER",
            Self::PermissionlessValidator => "PERMISSIONLESS_VALIDATOR",
            Self::InteropFeeManager => "L1_INTEROP_FEE_MANAGER",
        }
    }

    /// The CTM-domain slot whose proxy the immutable names, and the package field reporting it.
    fn slot(
        self,
        reported: &ReportedSingletons,
    ) -> Option<(&'static str, &'static str, Option<Address>)> {
        match self {
            Self::BytecodesSupplier => Some((
                "BytecodesSupplier",
                "bytecodes_supplier_addr",
                reported.bytecodes_supplier,
            )),
            Self::PermissionlessValidator => Some((
                "PermissionlessValidator",
                "permissionless_validator_addr",
                reported.permissionless_validator,
            )),
            Self::InteropFeeManager => Some((
                "L1InteropFeeManager",
                "interop_fee_manager_proxy_addr",
                reported.interop_fee_manager,
            )),
            Self::BridgeHub => None,
        }
    }

    async fn read<P: Provider>(
        self,
        provider: &P,
        ctm: Address,
    ) -> Result<Address, alloy::contract::Error> {
        let view = CtmView::new(ctm, provider);
        match self {
            Self::BridgeHub => view.BRIDGE_HUB().call().await,
            Self::BytecodesSupplier => view.L1_BYTECODES_SUPPLIER().call().await,
            Self::PermissionlessValidator => view.PERMISSIONLESS_VALIDATOR().call().await,
            Self::InteropFeeManager => view.L1_INTEROP_FEE_MANAGER().call().await,
        }
    }

    /// The value the review establishes without the live CTM: for a CTM-domain singleton the
    /// participating inventory row of its slot, else the proxy the package reports for it. None
    /// for the Bridgehub, which the implementation's construction record is held against the
    /// reviewed one for ([`super::member_construction`]).
    fn fallback(self, review: &InventoryReview<'_>) -> Fallback {
        match self {
            Self::BridgeHub => Fallback::None,
            _ => {
                let Some((member, field, reported)) = self.slot(&review.reported) else {
                    return Fallback::None;
                };
                let row = CTM_CONTRACTS
                    .iter()
                    .position(|m| *m == member)
                    .and_then(|slot| review.rows.get(slot))
                    .filter(|row| !row.implNew.is_zero() && !row.proxy.is_zero());
                match (row, reported) {
                    (Some(row), _) => {
                        Fallback::Known(row.proxy, format!("the inventory's {member} row"))
                    }
                    (None, Some(proxy)) => Fallback::Reported {
                        proxy,
                        member,
                        field,
                    },
                    (None, None) => Fallback::None,
                }
            }
        }
    }
}

/// Holds each constructor immutable of the new `ChainTypeManager` implementation against a value
/// the review establishes independently: the live CTM's own getter (unchanged across the swap),
/// else [`CtmImmutable::fallback`]. A zero value, or one nothing establishes, is an error. Returns
/// the established values, which the implementation's construction record is held against too,
/// and the implementation behind each proxy only the package reports that it established, whose
/// own construction is checked like a row's `implNew`.
///
/// Reads, per immutable in [`CtmImmutable::ALL`] order: the implementation's getter, the live
/// CTM's (when the anchor is known) and, for a reported proxy, [`establish_reported_proxy`]'s.
async fn verify_ctm_immutables<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &InventoryReview<'_>,
    label: &str,
    implementation: Address,
) -> anyhow::Result<(CtmImmutableExpectations, Vec<RowImplementation>)> {
    let mut established = CtmImmutableExpectations::new();
    let mut reported_implementations = Vec::new();
    for immutable in CtmImmutable::ALL {
        let getter = immutable.getter();
        let arriving = tolerate(
            immutable.read(provider, implementation).await,
            result,
            &format!("{label} implNew's {getter}()"),
        );
        let live = match review.anchor {
            Some(ctm) => immutable.read(provider, ctm).await.ok(),
            None => None,
        };
        let expected = match live.filter(|live| !live.is_zero()) {
            Some(live) => Some((live, format!("the live CTM's own {getter}()"))),
            None => match immutable.fallback(review) {
                Fallback::Known(value, source) => Some((value, source)),
                Fallback::Reported {
                    proxy,
                    member,
                    field,
                } => {
                    let Some((source, behind)) = establish_reported_proxy(
                        provider, build, result, review, proxy, member, field,
                    )
                    .await?
                    else {
                        established.push((immutable, None));
                        continue;
                    };
                    reported_implementations.push(behind);
                    Some((proxy, source))
                }
                Fallback::None => None,
            },
        };
        let expected = expected.filter(|(value, _)| !value.is_zero());
        established.push((immutable, expected.clone()));
        let Some(arriving) = arriving else {
            continue;
        };
        match expected {
            _ if arriving.is_zero() => result.report_error(&format!(
                "{label}: the new implementation's {getter} is zero, and code identity does not \
                 cover constructor immutables"
            )),
            Some((expected, _)) if expected == arriving => result.report_ok(&format!(
                "{label}: the new implementation's {getter} is {arriving}"
            )),
            Some((expected, source)) => result.report_error(&format!(
                "{label}: the new implementation's {getter} is {arriving}, but {source} is \
                 {expected}"
            )),
            None => result.report_error(&format!(
                "{label}: the new implementation's {getter} is {arriving}, and neither the live \
                 CTM nor the package establishes the value it must have: unverified"
            )),
        }
    }
    Ok((established, reported_implementations))
}

/// A singleton proxy only the package reports — one this upgrade introduces, which no row upgrades
/// and the live CTM does not name yet — is established when it runs the reviewed
/// [`REVIEWED_PROXY`], its EIP-1967 admin slot names the domain admin, and the implementation its
/// EIP-1967 implementation slot names runs the reviewed contract of its slot. Returns how the
/// report names it and the implementation behind it, or `None` with the failure reported.
///
/// Reads: the proxy's code, its admin slot, its implementation slot, the implementation's code.
async fn establish_reported_proxy<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &InventoryReview<'_>,
    proxy: Address,
    member: &'static str,
    field: &'static str,
) -> anyhow::Result<Option<(String, RowImplementation)>> {
    let proxy_label = format!("the package's {field} {proxy}");
    let (_, proxy_contract) = REVIEWED_PROXY;
    if expect_code_identity(
        provider,
        build,
        result,
        &proxy_label,
        proxy,
        &[proxy_contract],
    )
    .await?
    .is_none()
    {
        return Ok(None);
    }
    // A transparent proxy answers `admin()` and `implementation()` only to its admin, so the
    // slots are read.
    let admin = provider
        .get_storage_at(proxy, EIP1967_PROXY_ADMIN_SLOT.into())
        .await?;
    let admin = Address::from_word(admin.into());
    if admin != review.domain_admin {
        result.report_error(&format!(
            "{proxy_label} is administered by {admin}, not the CTM-domain ProxyAdmin {}, so it \
             does not establish the {member} a new CTM implementation must name",
            review.domain_admin
        ));
        return Ok(None);
    }
    result.report_ok(&format!(
        "{proxy_label} is administered by the CTM-domain ProxyAdmin {admin}"
    ));
    let implementation = provider
        .get_storage_at(proxy, EIP1967_IMPLEMENTATION_SLOT.into())
        .await?;
    let implementation = Address::from_word(implementation.into());
    let label = format!("{proxy_label}'s implementation");
    let admitted = review.inventory.implementations(member);
    let Some(name) =
        expect_code_identity(provider, build, result, &label, implementation, admitted).await?
    else {
        return Ok(None);
    };
    Ok(Some((
        format!("the package's {field}, a CTM-domain proxy running the reviewed {name},"),
        RowImplementation {
            label,
            address: implementation,
            admitted,
            identified: name,
            new_because: REPORTED_IMPLEMENTATION_IS_NEW,
            ctm_immutables: None,
        },
    )))
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
        RowVerdict::SelfEdge => {
            result.report_error(&format!(
                "{label} is a self-edge onto {}: it upgrades nothing",
                row.implNew
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

    use super::super::construction::{canonical_create2_address, DETERMINISTIC_CREATE2_FACTORY};
    use super::super::member_construction::ReviewedEnv;
    use crate::common::forge::scripts::member_deployments::{
        MemberDeploymentRecord, MemberDeployments,
    };

    const DOMAIN_ADMIN: Address = Address::repeat_byte(0xAD);
    const CTM: Address = Address::repeat_byte(0xC7);
    const NOTIFIER: Address = Address::repeat_byte(0x5E);
    const OLD: Address = Address::repeat_byte(0x01);
    const NEW: Address = Address::repeat_byte(0x02);
    const OTHER: Address = Address::repeat_byte(0x03);
    const NOTIFIER_RUNTIME: &[u8] = b"the reviewed ServerNotifier runtime";
    const CTM_RUNTIME: &[u8] = b"the reviewed ChainTypeManager runtime";
    const FEE_MANAGER_RUNTIME: &[u8] = b"the reviewed L1InteropFeeManager runtime";
    const PROXY_RUNTIME: &[u8] = b"the reviewed TransparentUpgradeableProxy runtime";

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

    fn creation(name: &str) -> Vec<u8> {
        format!("the creation code of {name}").into_bytes()
    }

    fn build() -> ReviewedBuild {
        ReviewedBuild::from_artifacts(
            CodeIdentity::empty().with_contract("l1-contracts/ChainTypeManager", CTM_RUNTIME),
            vec![
                (
                    "ServerNotifier.sol",
                    "ServerNotifier",
                    creation("ServerNotifier"),
                    NOTIFIER_RUNTIME.to_vec(),
                    Vec::new(),
                ),
                (
                    "ChainTypeManager.sol",
                    "ChainTypeManager",
                    creation("ChainTypeManager"),
                    CTM_RUNTIME.to_vec(),
                    Vec::new(),
                ),
                (
                    "L1InteropFeeManager.sol",
                    "L1InteropFeeManager",
                    creation("L1InteropFeeManager"),
                    FEE_MANAGER_RUNTIME.to_vec(),
                    Vec::new(),
                ),
                (
                    REVIEWED_PROXY.0,
                    REVIEWED_PROXY.1,
                    creation(REVIEWED_PROXY.1),
                    PROXY_RUNTIME.to_vec(),
                    Vec::new(),
                ),
            ],
        )
        .with_constructor(
            "ChainTypeManager",
            &[
                ("_bridgehub", "address"),
                ("_l1BytecodesSupplier", "address"),
                ("_permissionlessValidator", "address"),
                ("_l1InteropFeeManager", "address"),
            ],
        )
        .with_constructor("L1InteropFeeManager", &[("_bridgehub", "address")])
    }

    #[test]
    fn a_row_is_classified_by_the_on_chain_semantics() {
        assert_eq!(classify_row(OLD, &row(NOTIFIER)), RowVerdict::Departs);
        assert_eq!(
            classify_row(NEW, &row(NOTIFIER)),
            RowVerdict::AlreadyApplied
        );
        assert_eq!(classify_row(OTHER, &row(NOTIFIER)), RowVerdict::Mismatch);
        // A self-edge is its own verdict whatever is live, never "Departs".
        let self_edge = ProxyUpgradeRow {
            implNew: OLD,
            ..row(NOTIFIER)
        };
        for live in [OLD, OTHER] {
            assert_eq!(classify_row(live, &self_edge), RowVerdict::SelfEdge);
        }
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
                reported: Default::default(),
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
        let answers = || {
            let mut answers = vec![addr(OLD), Bytes::from_static(CTM_RUNTIME)];
            answers.extend(kept_immutables());
            answers
        };
        let result = run(&inventory("ChainTypeManager", CTM), &answers(), None).await;
        assert_eq!(result.errors, 0);
        let result = run(&inventory("ChainTypeManager", OTHER), &answers(), None).await;
        assert_eq!(result.errors, 1);
    }

    /// The `(implementation, live CTM)` answers of the four CTM immutables, in read order, each
    /// kept unchanged across the swap.
    fn kept_immutables() -> Vec<Bytes> {
        vec![addr(Address::repeat_byte(0x42)); 2 * CtmImmutable::ALL.len()]
    }

    // ───────────────────────── the CTM implementation's immutables ─────────────────────────

    const VALIDATOR: Address = Address::repeat_byte(0x7A);

    /// Drives the CTM row of a CTM-domain inventory whose PermissionlessValidator slot is
    /// `validator_row` (inert when `None`), with the four immutables answering per `answer`. The
    /// implementation's getters are mocked as their raw answers, so a reverting one is queued as
    /// a failure.
    async fn run_ctm_row(
        validator_row: Option<Address>,
        reported: ReportedSingletons,
        answer: impl Fn(CtmImmutable) -> (Option<Address>, Option<Address>),
    ) -> VerificationResult {
        run_ctm_row_with(validator_row, reported, answer, &[]).await
    }

    /// [`run_ctm_row`], with `extra` answers queued right after the immutable `extra_after`'s two.
    async fn run_ctm_row_with(
        validator_row: Option<Address>,
        reported: ReportedSingletons,
        answer: impl Fn(CtmImmutable) -> (Option<Address>, Option<Address>),
        extra: &[(CtmImmutable, Option<Bytes>)],
    ) -> VerificationResult {
        run_ctm_row_reviewed(validator_row, reported, answer, extra, NEW, None).await
    }

    /// [`run_ctm_row_with`] for a row installing `implementation`, then — when `construction`
    /// names the records and the reviewer's inputs — every identified implementation's
    /// construction ([`verify_inventory_construction`]), which reads nothing here.
    async fn run_ctm_row_reviewed(
        validator_row: Option<Address>,
        reported: ReportedSingletons,
        answer: impl Fn(CtmImmutable) -> (Option<Address>, Option<Address>),
        extra: &[(CtmImmutable, Option<Bytes>)],
        implementation: Address,
        construction: Option<(&MemberDeployments, &ReviewedEnv)>,
    ) -> VerificationResult {
        let mut rows = inventory("ChainTypeManager", CTM);
        rows[slot_of("ChainTypeManager")].implNew = implementation;
        if let Some(proxy) = validator_row {
            rows[slot_of("PermissionlessValidator")] = ProxyUpgradeRow {
                proxy,
                expectedOldImpl: Address::repeat_byte(0x0A),
                implNew: Address::repeat_byte(0x0B),
                callInitializeUpgrade: false,
            };
        }
        let asserter = Asserter::new();
        asserter.push_success(&addr(OLD));
        asserter.push_success(&Bytes::from_static(CTM_RUNTIME));
        for immutable in CtmImmutable::ALL {
            let (arriving, live) = answer(immutable);
            for value in [arriving, live] {
                match value {
                    Some(value) => asserter.push_success(&addr(value)),
                    None => asserter.push_failure_msg("execution reverted"),
                }
            }
            for (after, value) in extra {
                if *after == immutable {
                    match value {
                        Some(value) => asserter.push_success(value),
                        None => asserter.push_failure_msg("execution reverted"),
                    }
                }
            }
        }
        if validator_row.is_some() {
            // The PermissionlessValidator row is read after the CTM's own (slot order): its
            // discovery, departure and code are not what this drives, so they fail uniformly.
            for _ in 0..3 {
                asserter.push_failure_msg("outside the immutables check");
            }
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let outcome = verify_inventory(
            &provider,
            &build(),
            &mut result,
            &InventoryReview {
                inventory: Inventory::CtmDomain,
                rows: &rows,
                domain_admin: DOMAIN_ADMIN,
                anchor: Some(CTM),
                departure_unreadable: None,
                reported,
            },
        )
        .await;
        // The PermissionlessValidator row's code read fails as a transport error, ending the run
        // after the CTM row was judged.
        if validator_row.is_none() {
            let outcome = outcome.unwrap();
            assert!(asserter.read_q().is_empty(), "every answer was read");
            if let Some((records, env)) = construction {
                let review = MemberReview::new(records, env, None, None);
                verify_inventory_construction(&provider, &build(), &mut result, &review, &outcome)
                    .await
                    .unwrap();
            }
        }
        result
    }

    fn immutable_errors(result: &VerificationResult) -> Vec<&String> {
        result
            .error_messages
            .iter()
            .filter(|e| e.contains("the new implementation's"))
            .collect()
    }

    /// Item: the new implementation keeps every immutable the live CTM answers.
    #[tokio::test]
    async fn a_new_ctm_implementation_keeping_the_live_immutables_passes() {
        let result = run_ctm_row(None, Default::default(), |_| {
            (Some(VALIDATOR), Some(VALIDATOR))
        })
        .await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// Code identity masks `PERMISSIONLESS_VALIDATOR`, which `DiamondInit` writes into every new
    /// chain: a new implementation built over another validator than the live one fails.
    #[tokio::test]
    async fn a_new_ctm_implementation_changing_an_immutable_fails() {
        let result = run_ctm_row(None, Default::default(), |immutable| {
            if immutable == CtmImmutable::PermissionlessValidator {
                (Some(OTHER), Some(VALIDATOR))
            } else {
                (Some(VALIDATOR), Some(VALIDATOR))
            }
        })
        .await;
        assert_eq!(result.errors, 1);
        assert!(
            result.has_error("PERMISSIONLESS_VALIDATOR is"),
            "{:?}",
            result.error_messages
        );
        assert!(result.has_error("the live CTM's own PERMISSIONLESS_VALIDATOR()"));
    }

    /// Zero is always an error, even when the live CTM answers zero too.
    #[tokio::test]
    async fn a_zero_immutable_fails() {
        let result = run_ctm_row(None, Default::default(), |immutable| {
            if immutable == CtmImmutable::InteropFeeManager {
                (Some(Address::ZERO), Some(Address::ZERO))
            } else {
                (Some(VALIDATOR), Some(VALIDATOR))
            }
        })
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("L1_INTEROP_FEE_MANAGER is zero"));
    }

    /// A live CTM that does not answer a getter: the value falls back to the inventory's row of the
    /// slot it names, and with no such row nothing establishes it.
    #[tokio::test]
    async fn an_immutable_the_live_ctm_does_not_answer_falls_back_to_its_inventory_row() {
        let answer = |arriving: Address| {
            move |immutable: CtmImmutable| match immutable {
                CtmImmutable::PermissionlessValidator => (Some(arriving), None),
                _ => (Some(VALIDATOR), Some(VALIDATOR)),
            }
        };
        let result = run_ctm_row(Some(VALIDATOR), Default::default(), answer(VALIDATOR)).await;
        assert!(
            immutable_errors(&result).is_empty(),
            "{:?}",
            result.error_messages
        );

        let result = run_ctm_row(Some(VALIDATOR), Default::default(), answer(OTHER)).await;
        assert_eq!(immutable_errors(&result).len(), 1);
        assert!(result.has_error("the inventory's PermissionlessValidator row is"));

        let result = run_ctm_row(None, Default::default(), answer(VALIDATOR)).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("PERMISSIONLESS_VALIDATOR is") && result.has_error("unverified"));
    }

    /// `BRIDGE_HUB` has no fallback, not even the package's `bridgehub_proxy_addr`.
    #[tokio::test]
    async fn the_bridgehub_does_not_fall_back() {
        const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
        let answer = |bridgehub: (Address, Option<Address>)| {
            move |immutable: CtmImmutable| match immutable {
                CtmImmutable::BridgeHub => (Some(bridgehub.0), bridgehub.1),
                _ => (Some(VALIDATOR), Some(VALIDATOR)),
            }
        };
        let reported = ReportedSingletons {
            bridgehub: Some(BRIDGEHUB),
            ..Default::default()
        };
        let result = run_ctm_row(None, reported, answer((BRIDGEHUB, Some(BRIDGEHUB)))).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);

        for reported in [reported, Default::default()] {
            let result = run_ctm_row(None, reported, answer((BRIDGEHUB, None))).await;
            assert_eq!(result.errors, 1, "{:?}", result.error_messages);
            assert!(result.has_error("BRIDGE_HUB is") && result.has_error("unverified"));
        }
    }

    /// The reads that establish a proxy only the package reports, in order: its code, its
    /// EIP-1967 admin and implementation slots (each as a storage word), the implementation's code.
    fn reported_proxy(
        proxy_code: &'static [u8],
        admin: Address,
        implementation: Address,
        implementation_code: &'static [u8],
    ) -> Vec<(CtmImmutable, Option<Bytes>)> {
        [
            Bytes::from_static(proxy_code),
            addr(admin),
            addr(implementation),
            Bytes::from_static(implementation_code),
        ]
        .into_iter()
        .map(|answer| (CtmImmutable::InteropFeeManager, Some(answer)))
        .collect()
    }

    /// A singleton this upgrade introduces — the v35 bootstrap's `L1InteropFeeManager`: the live
    /// CTM does not name it yet and no row upgrades it — is established from the package's
    /// report only when it runs the reviewed proxy, the CTM-domain ProxyAdmin is its admin, and its
    /// implementation runs the reviewed contract of its slot.
    #[tokio::test]
    async fn a_singleton_only_the_package_reports_must_be_a_reviewed_ctm_domain_proxy() {
        const FEE_MANAGER: Address = Address::repeat_byte(0xFE);
        const FEE_MANAGER_IMPL: Address = Address::repeat_byte(0xFF);
        let reported = ReportedSingletons {
            interop_fee_manager: Some(FEE_MANAGER),
            ..Default::default()
        };
        let answer = |arriving: Address| {
            move |immutable: CtmImmutable| match immutable {
                CtmImmutable::InteropFeeManager => (Some(arriving), None),
                _ => (Some(VALIDATOR), Some(VALIDATOR)),
            }
        };
        let established = |code: &'static [u8]| {
            reported_proxy(PROXY_RUNTIME, DOMAIN_ADMIN, FEE_MANAGER_IMPL, code)
        };

        let result = run_ctm_row_with(
            None,
            reported,
            answer(FEE_MANAGER),
            &established(FEE_MANAGER_RUNTIME),
        )
        .await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);

        let result = run_ctm_row_with(
            None,
            reported,
            answer(OTHER),
            &established(FEE_MANAGER_RUNTIME),
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(
            result.has_error("the package's interop_fee_manager_proxy_addr, a CTM-domain proxy")
        );

        // Not administered by the CTM-domain ProxyAdmin: nothing behind it is read.
        let result = run_ctm_row_with(
            None,
            reported,
            answer(FEE_MANAGER),
            &reported_proxy(PROXY_RUNTIME, OTHER, FEE_MANAGER_IMPL, FEE_MANAGER_RUNTIME)[..2],
        )
        .await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error(&format!(
            "is administered by {OTHER}, not the CTM-domain ProxyAdmin {DOMAIN_ADMIN}"
        )));

        // Not a proxy at all, though it would answer `implementation()` with the reviewed
        // implementation: neither its slots nor that implementation are read.
        let result = run_ctm_row_with(
            None,
            reported,
            answer(FEE_MANAGER),
            &reported_proxy(
                b"a contract answering implementation()",
                DOMAIN_ADMIN,
                FEE_MANAGER_IMPL,
                FEE_MANAGER_RUNTIME,
            )[..1],
        )
        .await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error(&format!(
            "the package's interop_fee_manager_proxy_addr {FEE_MANAGER} at {FEE_MANAGER} runs \
             code"
        )));
        assert!(result.has_error("not the reviewed build of TransparentUpgradeableProxy"));

        // Running another contract than the slot's.
        let result = run_ctm_row_with(
            None,
            reported,
            answer(FEE_MANAGER),
            &established(CTM_RUNTIME),
        )
        .await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("interop_fee_manager_proxy_addr"));
    }

    /// An implementation that does not answer a getter is not a CTM this review can judge.
    #[tokio::test]
    async fn an_unreadable_immutable_fails() {
        let result = run_ctm_row(None, Default::default(), |immutable| {
            if immutable == CtmImmutable::BytecodesSupplier {
                (None, Some(VALIDATOR))
            } else {
                (Some(VALIDATOR), Some(VALIDATOR))
            }
        })
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("L1_BYTECODES_SUPPLIER()"));
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

    /// An inventory whose length is not the enum's.
    #[tokio::test]
    async fn an_inventory_of_the_wrong_length_fails() {
        let result = run(&vec![inert(); 3], &[], None).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("constructor refuses such an inventory"));
    }

    // ───────────────────────── row shape ─────────────────────────

    /// A malformed row is an error from the row alone: nothing is read for it, so it fails the
    /// same whatever is live.
    #[tokio::test]
    async fn a_malformed_row_fails_without_reading_live_state() {
        for (bad, needle) in [
            (
                ProxyUpgradeRow {
                    proxy: Address::ZERO,
                    ..row(NOTIFIER)
                },
                "zero address as its proxy",
            ),
            (
                ProxyUpgradeRow {
                    expectedOldImpl: Address::ZERO,
                    ..row(NOTIFIER)
                },
                "departs from the zero address",
            ),
            (
                ProxyUpgradeRow {
                    expectedOldImpl: NEW,
                    ..row(NOTIFIER)
                },
                "self-edge",
            ),
        ] {
            let mut rows = inventory("ServerNotifier", NOTIFIER);
            rows[CTM_CONTRACT_SERVER_NOTIFIER_SLOT] = bad;
            let result = run(&rows, &[], None).await;
            assert_eq!(result.errors, 1, "{needle}: {:?}", result.error_messages);
            assert!(result.has_error(needle), "{:?}", result.error_messages);
        }
    }

    /// Two participating rows naming one proxy: the first is held to live state as usual, the
    /// second is reported and not read.
    #[tokio::test]
    async fn a_proxy_named_by_two_rows_fails() {
        let mut rows = inventory("ServerNotifier", NOTIFIER);
        rows[slot_of("L1InteropFeeManager")] = ProxyUpgradeRow {
            implNew: Address::repeat_byte(0x0C),
            ..row(NOTIFIER)
        };
        let result = run(
            &rows,
            &[
                addr(NOTIFIER),
                addr(OLD),
                Bytes::from_static(NOTIFIER_RUNTIME),
            ],
            None,
        )
        .await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("a second time (slot 19 names it too)"));
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
                reported: Default::default(),
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
                if member == "ChainTypeManager" {
                    for answer in kept_immutables() {
                        asserter.push_success(&answer);
                    }
                }
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
                        reported: Default::default(),
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

    // ───────────────────────── the implementations' construction ─────────────────────────

    const SALT: alloy::primitives::B256 = alloy::primitives::B256::repeat_byte(0x5A);

    /// The record of `contract` built from `args`, keyed where it lands.
    fn recorded(contract: &str, args: Vec<u8>) -> (Address, MemberDeployments) {
        let address = canonical_create2_address(SALT, &creation(contract), &args);
        let record = MemberDeploymentRecord {
            contract: contract.to_string(),
            create2_factory: DETERMINISTIC_CREATE2_FACTORY,
            create2_salt: SALT,
            constructor_args: Bytes::from(args),
        };
        (address, [(address, record)].into_iter().collect())
    }

    /// The ServerNotifier row installing `implementation`, then its construction against
    /// `records`.
    async fn run_notifier_row(
        implementation: Address,
        records: &MemberDeployments,
    ) -> VerificationResult {
        let mut rows = inventory("ServerNotifier", NOTIFIER);
        rows[CTM_CONTRACT_SERVER_NOTIFIER_SLOT].implNew = implementation;
        let asserter = Asserter::new();
        for answer in [
            addr(NOTIFIER),
            addr(OLD),
            Bytes::from_static(NOTIFIER_RUNTIME),
        ] {
            asserter.push_success(&answer);
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let outcome = verify_inventory(
            &provider,
            &build(),
            &mut result,
            &InventoryReview {
                inventory: Inventory::CtmDomain,
                rows: &rows,
                domain_admin: DOMAIN_ADMIN,
                anchor: Some(CTM),
                departure_unreadable: None,
                reported: Default::default(),
            },
        )
        .await
        .unwrap();
        let env = ReviewedEnv::default();
        verify_inventory_construction(
            &provider,
            &build(),
            &mut result,
            &MemberReview::new(records, &env, None, None),
            &outcome,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty());
        result
    }

    /// A row installs an implementation its prepare deployed, so it needs a record.
    #[tokio::test]
    async fn a_recorded_implementation_passes_and_an_unrecorded_one_fails() {
        let (implementation, records) = recorded("ServerNotifier", Vec::new());
        let result = run_notifier_row(implementation, &records).await;
        assert_eq!(
            (result.errors, result.warnings),
            (0, 0),
            "{:?}",
            result.error_messages
        );
        let result = run_notifier_row(implementation, &MemberDeployments::new()).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("a row installs only an implementation its prepare deployed"));
    }

    /// The constructor arguments of a new CTM implementation, in declaration order.
    fn ctm_args(validator: Address, fee_manager: Address) -> Vec<u8> {
        (VALIDATOR, VALIDATOR, validator, fee_manager).abi_encode_params()
    }

    /// A CTM implementation built over another PermissionlessValidator than the live CTM's fails
    /// twice, independently: through its getter, and through its record.
    #[tokio::test]
    async fn a_ctm_implementation_recorded_over_another_permissionless_validator_fails() {
        let env = ReviewedEnv::for_test(None, Some(VALIDATOR));
        let kept = |validator: Address| {
            move |immutable: CtmImmutable| match immutable {
                CtmImmutable::PermissionlessValidator => (Some(validator), Some(VALIDATOR)),
                _ => (Some(VALIDATOR), Some(VALIDATOR)),
            }
        };
        let (implementation, records) =
            recorded("ChainTypeManager", ctm_args(VALIDATOR, VALIDATOR));
        let result = run_ctm_row_reviewed(
            None,
            Default::default(),
            kept(VALIDATOR),
            &[],
            implementation,
            Some((&records, &env)),
        )
        .await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);

        let (implementation, records) = recorded("ChainTypeManager", ctm_args(OTHER, VALIDATOR));
        let result = run_ctm_row_reviewed(
            None,
            Default::default(),
            kept(OTHER),
            &[],
            implementation,
            Some((&records, &env)),
        )
        .await;
        assert_eq!(result.errors, 2, "{:?}", result.error_messages);
        assert!(result.has_error("the new implementation's PERMISSIONLESS_VALIDATOR is"));
        assert!(result.has_error("ChainTypeManager._permissionlessValidator is"));
    }

    /// The implementation behind a proxy only the package reports — the v35 bootstrap's
    /// `L1InteropFeeManager` — is the prepare's deployment like a row's `implNew`: held to its
    /// record, with its `_bridgehub` the reviewed Bridgehub.
    #[tokio::test]
    async fn a_reported_proxy_implementation_is_held_to_its_record() {
        const FEE_MANAGER: Address = Address::repeat_byte(0xFE);
        const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
        let reported = ReportedSingletons {
            interop_fee_manager: Some(FEE_MANAGER),
            ..Default::default()
        };
        let answer = |immutable: CtmImmutable| match immutable {
            CtmImmutable::BridgeHub => (Some(BRIDGEHUB), Some(BRIDGEHUB)),
            CtmImmutable::InteropFeeManager => (Some(FEE_MANAGER), None),
            _ => (Some(VALIDATOR), Some(VALIDATOR)),
        };
        let (implementation, mut records) = recorded(
            "ChainTypeManager",
            (BRIDGEHUB, VALIDATOR, VALIDATOR, FEE_MANAGER).abi_encode_params(),
        );
        let env = ReviewedEnv::for_test(None, Some(BRIDGEHUB));
        let run = |fee_manager_impl: Address, records: MemberDeployments| {
            let env = &env;
            async move {
                run_ctm_row_reviewed(
                    None,
                    reported,
                    answer,
                    &reported_proxy(
                        PROXY_RUNTIME,
                        DOMAIN_ADMIN,
                        fee_manager_impl,
                        FEE_MANAGER_RUNTIME,
                    ),
                    implementation,
                    Some((&records, env)),
                )
                .await
            }
        };

        let (genuine, genuine_record) = recorded("L1InteropFeeManager", BRIDGEHUB.abi_encode());
        let mut with_genuine = records.clone();
        with_genuine.extend(genuine_record);
        let result = run(genuine, with_genuine).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);

        let (foreign, foreign_record) = recorded("L1InteropFeeManager", OTHER.abi_encode());
        let mut with_foreign = records.clone();
        with_foreign.extend(foreign_record);
        let result = run(foreign, with_foreign).await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error(&format!(
            "L1InteropFeeManager._bridgehub is {OTHER}, but env test's bridgehub_proxy_addr is \
             {BRIDGEHUB}"
        )));

        records.retain(|address, _| *address == implementation);
        let result = run(genuine, records).await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("the package introduces the proxy"));
    }
}
