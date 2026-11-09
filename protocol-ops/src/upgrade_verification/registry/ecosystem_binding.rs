//! The one root every registry package kind is verified against: the REVIEWED Bridgehub —
//! `--expected-bridgehub`, else the `--env`'s permanent-values `bridgehub_proxy_addr`.
//!
//! Every ecosystem lookup starts from it: the proxies an ecosystem inventory's slots must name
//! ([`super::rows`]), the live values a release's force deployments and a member's constructor
//! arguments are held against ([`super::genesis`], [`super::member_construction`]) and the chains
//! a bootstrap's departing verifier is read from. What the package names in the ecosystem — its
//! `bridgehub_proxy_addr`, the CTMs its legs drive, the ProxyAdmins its executors apply rows
//! through — is held against that root ([`bind_to_reviewed_ecosystem`]) and never used as one: a
//! Bridgehub the package chose could answer real proxies under the wrong getters, and a genuine
//! transition would then install one slot's implementation behind another slot's proxy.

use alloy::primitives::Address;
use alloy::providers::Provider;

use crate::upgrade_verification::constants::EIP1967_PROXY_ADMIN_SLOT;
use crate::upgrade_verification::report::VerificationResult;

use super::provenance::tolerate;
use super::views::{BridgehubView, CtmView};

/// The reviewed Bridgehub and where the review takes it from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ReviewedBridgehub {
    pub(crate) address: Address,
    /// "the reviewer's --expected-bridgehub" or "env <name>'s bridgehub_proxy_addr".
    pub(crate) source: String,
}

/// What a package names in the ecosystem, each held against the reviewed Bridgehub.
#[derive(Default)]
pub(super) struct EcosystemClaims {
    /// The package's own `bridgehub_proxy_addr`, when it names one.
    pub(super) reported_bridgehub: Option<Address>,
    /// Every CTM the package drives; one named twice is read once.
    pub(super) ctms: Vec<Address>,
    /// The ProxyAdmin the core executor applies the ecosystem rows through (its live
    /// `PROXY_ADMIN()`), when the package drives a core executor.
    pub(super) core_proxy_admin: Option<Address>,
    /// The CTM the CTM executor is bound to and the ProxyAdmin it upgrades the CTM domain
    /// through (its live `CHAIN_TYPE_MANAGER()` and `CTM_PROXY_ADMIN()`), when the package drives
    /// a CTM executor.
    pub(super) ctm_proxy_admin: Option<(Address, Address)>,
}

/// Holds `claims` against the reviewed Bridgehub: the package's Bridgehub must be it, every CTM
/// must be registered on it and built over it, the core executor's ProxyAdmin must administer it
/// and the CTM executor's must administer its CTM. `reviewed` is `None` only where no reviewed
/// Bridgehub exists, which `registry::verify` refuses before any check runs; it is an error here.
///
/// Reads, in order: per CTM, the Bridgehub's `chainTypeManagerIsRegistered(ctm)` and the CTM's
/// `BRIDGE_HUB()`; then the Bridgehub's EIP-1967 admin slot (with a core executor) and the CTM
/// proxy's (with a CTM executor).
pub(super) async fn bind_to_reviewed_ecosystem<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    reviewed: Option<&ReviewedBridgehub>,
    claims: &EcosystemClaims,
) {
    let Some(ReviewedBridgehub {
        address: bridgehub,
        source,
    }) = reviewed
    else {
        result.report_error(
            "no reviewed Bridgehub: the package's Bridgehub, CTMs and ProxyAdmins are held \
             against nothing, and its ecosystem slots cannot be discovered",
        );
        return;
    };
    let bridgehub = *bridgehub;
    match claims.reported_bridgehub {
        Some(reported) if reported == bridgehub => result.report_ok(&format!(
            "the core prepare's bridgehub_proxy_addr is the reviewed Bridgehub {bridgehub} \
             ({source})"
        )),
        Some(reported) => result.report_error(&format!(
            "the core prepare's bridgehub_proxy_addr {reported} is not the reviewed Bridgehub \
             {bridgehub} ({source}): the package was prepared against another ecosystem"
        )),
        None => {}
    }

    let registry = BridgehubView::new(bridgehub, provider);
    let mut seen: Vec<Address> = Vec::new();
    for &ctm in &claims.ctms {
        if seen.contains(&ctm) {
            continue;
        }
        seen.push(ctm);
        match tolerate(
            registry.chainTypeManagerIsRegistered(ctm).call().await,
            result,
            &format!("the reviewed Bridgehub's chainTypeManagerIsRegistered({ctm})"),
        ) {
            Some(true) => result.report_ok(&format!(
                "the CTM {ctm} is registered on the reviewed Bridgehub {bridgehub}"
            )),
            Some(false) => result.report_error(&format!(
                "the CTM {ctm} is not registered on the reviewed Bridgehub {bridgehub}: the CTM \
                 legs would land on a contract governance never registered in this ecosystem"
            )),
            None => {}
        }
        match tolerate(
            CtmView::new(ctm, provider).BRIDGE_HUB().call().await,
            result,
            &format!("the CTM {ctm}'s BRIDGE_HUB()"),
        ) {
            Some(built_over) if built_over == bridgehub => result.report_ok(&format!(
                "the CTM {ctm} is built over the reviewed Bridgehub"
            )),
            Some(built_over) => result.report_error(&format!(
                "the CTM {ctm} is built over Bridgehub {built_over}, not the reviewed {bridgehub}"
            )),
            None => {}
        }
    }

    if let Some(applied_through) = claims.core_proxy_admin {
        if let Some(admin) = admin_of(provider, result, bridgehub, "the reviewed Bridgehub").await {
            if admin == applied_through {
                result.report_ok(&format!(
                    "the core executor applies rows through ProxyAdmin {admin}, which administers \
                     the reviewed Bridgehub"
                ));
            } else {
                result.report_error(&format!(
                    "the core executor applies rows through ProxyAdmin {applied_through}, but the \
                     reviewed Bridgehub is administered by {admin}: its rows would not reach the \
                     ecosystem's proxies"
                ));
            }
        }
    }
    if let Some((ctm, applied_through)) = claims.ctm_proxy_admin {
        if let Some(admin) = admin_of(provider, result, ctm, "the CTM proxy").await {
            if admin == applied_through {
                result.report_ok(&format!(
                    "the CTM executor upgrades through ProxyAdmin {admin}, which administers the \
                     CTM proxy {ctm}"
                ));
            } else {
                result.report_error(&format!(
                    "the CTM executor upgrades through ProxyAdmin {applied_through}, but the CTM \
                     proxy {ctm} is administered by {admin}: its legs would not reach the CTM"
                ));
            }
        }
    }
}

/// A proxy's EIP-1967 admin slot: a transparent proxy answers `admin()` only to its admin.
async fn admin_of<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    proxy: Address,
    label: &str,
) -> Option<Address> {
    tolerate(
        provider
            .get_storage_at(proxy, EIP1967_PROXY_ADMIN_SLOT.into())
            .await,
        result,
        &format!("{label} {proxy}'s EIP-1967 admin slot"),
    )
    .map(|word| Address::from_word(word.into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::Bytes;
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
    const FORGED: Address = Address::repeat_byte(0xF0);
    const CTM: Address = Address::repeat_byte(0xC7);
    const OTHER_CTM: Address = Address::repeat_byte(0xC8);
    const ECO_ADMIN: Address = Address::repeat_byte(0xA0);
    const CTM_ADMIN: Address = Address::repeat_byte(0xA7);

    fn reviewed() -> ReviewedBridgehub {
        ReviewedBridgehub {
            address: BRIDGEHUB,
            source: "env test's bridgehub_proxy_addr".to_string(),
        }
    }

    fn word(value: impl SolValue) -> Bytes {
        Bytes::from(value.abi_encode())
    }

    /// Binds `claims` over `answers`, every answer read.
    async fn bind(claims: &EcosystemClaims, answers: &[Bytes]) -> VerificationResult {
        let asserter = Asserter::new();
        for answer in answers {
            asserter.push_success(answer);
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        bind_to_reviewed_ecosystem(&provider, &mut result, Some(&reviewed()), claims).await;
        assert!(asserter.read_q().is_empty(), "every answer was read");
        result
    }

    /// The package's Bridgehub is held against the reviewed one, with no read.
    #[tokio::test]
    async fn the_packages_bridgehub_must_be_the_reviewed_one() {
        let claims = |reported| EcosystemClaims {
            reported_bridgehub: reported,
            ..Default::default()
        };
        let result = bind(&claims(Some(BRIDGEHUB)), &[]).await;
        assert_eq!((result.errors, result.warnings), (0, 0));
        let result = bind(&claims(None), &[]).await;
        assert_eq!((result.errors, result.warnings), (0, 0));
        let result = bind(&claims(Some(FORGED)), &[]).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error(&format!(
            "the core prepare's bridgehub_proxy_addr {FORGED} is not the reviewed Bridgehub \
             {BRIDGEHUB} (env test's bridgehub_proxy_addr)"
        )));
    }

    /// Each CTM must be registered on the reviewed Bridgehub (read first) and built over it.
    #[tokio::test]
    async fn every_ctm_is_registered_on_and_built_over_the_reviewed_bridgehub() {
        let claims = EcosystemClaims {
            ctms: vec![CTM],
            ..Default::default()
        };
        let result = bind(&claims, &[word(true), word(BRIDGEHUB)]).await;
        assert_eq!((result.errors, result.warnings), (0, 0));

        let result = bind(&claims, &[word(false), word(BRIDGEHUB)]).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error(&format!(
            "the CTM {CTM} is not registered on the reviewed Bridgehub {BRIDGEHUB}"
        )));

        let result = bind(&claims, &[word(true), word(FORGED)]).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error(&format!(
            "the CTM {CTM} is built over Bridgehub {FORGED}, not the reviewed {BRIDGEHUB}"
        )));
    }

    /// A bound CTM and a reported one are both checked; one named twice is read once.
    #[tokio::test]
    async fn a_bound_and_a_reported_ctm_are_both_checked() {
        let both = EcosystemClaims {
            ctms: vec![CTM, OTHER_CTM],
            ..Default::default()
        };
        let result = bind(
            &both,
            &[word(true), word(BRIDGEHUB), word(false), word(BRIDGEHUB)],
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error(&format!("the CTM {OTHER_CTM} is not registered")));

        let same = EcosystemClaims {
            ctms: vec![CTM, CTM],
            ..Default::default()
        };
        let result = bind(&same, &[word(true), word(BRIDGEHUB)]).await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// Q3: the core executor's ProxyAdmin must administer the reviewed Bridgehub, and the CTM
    /// executor's the CTM proxy — read from their EIP-1967 admin slots.
    #[tokio::test]
    async fn both_executors_proxy_admins_must_administer_their_domains() {
        let claims = EcosystemClaims {
            core_proxy_admin: Some(ECO_ADMIN),
            ctm_proxy_admin: Some((CTM, CTM_ADMIN)),
            ..Default::default()
        };
        // A storage word reads back as the 32-byte word an address ABI-encodes to.
        let slot = word;
        let result = bind(&claims, &[slot(ECO_ADMIN), slot(CTM_ADMIN)]).await;
        assert_eq!((result.errors, result.warnings), (0, 0));

        let result = bind(&claims, &[slot(FORGED), slot(CTM_ADMIN)]).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error(&format!(
            "the core executor applies rows through ProxyAdmin {ECO_ADMIN}, but the reviewed \
             Bridgehub is administered by {FORGED}"
        )));

        let result = bind(&claims, &[slot(ECO_ADMIN), slot(FORGED)]).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error(&format!(
            "the CTM executor upgrades through ProxyAdmin {CTM_ADMIN}, but the CTM proxy {CTM} \
             is administered by {FORGED}"
        )));
    }

    /// Without a reviewed Bridgehub nothing is read and the binding is an error.
    #[tokio::test]
    async fn no_reviewed_bridgehub_binds_nothing() {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new().connect_mocked_client(asserter);
        let mut result = VerificationResult::default();
        bind_to_reviewed_ecosystem(
            &provider,
            &mut result,
            None,
            &EcosystemClaims {
                ctms: vec![CTM],
                ..Default::default()
            },
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("no reviewed Bridgehub"));
    }
}
