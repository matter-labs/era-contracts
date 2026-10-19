//! Was each member a package NEWLY installs built by the reviewed constructor, from argument
//! values the review holds independently?
//!
//! Code identity ([`super::provenance`]) masks a member's immutable slots, so it proves the
//! member's code but not the values its constructor wrote there — a facet built for another chain
//! id, or an implementation built over another Bridgehub, runs the reviewed code. Every prepare
//! therefore records how it deployed each contract (`[member_deployments]`, [`super::records`]):
//! the artifact, the CREATE2 factory, the salt and the exact constructor arguments. For each new
//! member the review
//!
//! 1. re-derives the address from the REVIEWED creation code, the recorded arguments and the
//!    recorded salt through the deterministic factory, and requires it to be the member's — which
//!    proves the code AND every immutable by construction, as [`super::construction`] does for
//!    the objects; and
//! 2. holds each decoded argument against the source [`CONSTRUCTOR_EXPECTATIONS`] names for it:
//!    the reviewer's inputs ([`ReviewedEnv`]: the env's permanent values and the Bridgehub under
//!    review) or live state found through them, re-read now — never against anything the package
//!    supplies. The package's CTM and Bridgehub are only cross-checked against the reviewed
//!    Bridgehub; a mismatch leaves every argument that needs it unestablished.
//!
//! The record is untrusted input: a record that does not describe the deployment fails the
//! derivation, and a genuine one built over a wrong value fails the argument check. A member the
//! departing side already names is carried over, reviewed when it was installed, and needs no
//! record. Each argument source is read at most once, and only when an argument needs it.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};

use alloy::dyn_abi::{DynSolType, DynSolValue};
use alloy::primitives::{Address, U256};
use alloy::providers::Provider;

use crate::common::env_config::EnvConfig;
use crate::common::forge::scripts::member_deployments::{
    MemberDeploymentRecord, MemberDeployments,
};
use crate::upgrade_verification::report::VerificationResult;

use super::construction::{
    canonical_create2_address, ReviewedBuild, DETERMINISTIC_CREATE2_FACTORY,
};
use super::members::SubVerifierGetter;
use super::provenance::{classify_code, CodeVerdict};
use super::rows::{discover_slot_proxy, CtmImmutable, CtmImmutableExpectations, Inventory};
use super::views::{BridgehubView, CtmView, L1AssetRouterView, ZkChainGettersView};

/// Where the value a constructor argument must have comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum ArgSource {
    /// `eth_chainId`; the env's `l1_chain_id`, when it declares one, must agree.
    L1ChainId,
    /// The env's `testnet_verifier`.
    IsTestnet,
    /// The reviewed Bridgehub ([`ReviewedEnv`]); the package's CTM's `BRIDGE_HUB()` and its
    /// `bridgehub_proxy_addr`, when it names them, must agree.
    Bridgehub,
    /// The live ecosystem proxy of the `L1EcosystemContract` member, discovered through the
    /// reviewed Bridgehub ([`discover_slot_proxy`]).
    EcosystemProxy(&'static str),
    /// The asset router's `L1_WETH_TOKEN()`.
    L1WethToken,
    /// The Bridgehub's `MAX_NUMBER_OF_ZK_CHAINS()`.
    MaxNumberOfZkChains,
    /// The asset router's `owner()`, which the core prepare builds ecosystem implementations for.
    EcosystemOwner,
    /// The env's `rollup_da_manager` for the CTM and the `getRollupDAManager()` of the first chain
    /// the reviewed Bridgehub registers on it (what the prepare resolves); when both are known
    /// they must agree.
    RollupDaManager,
    /// The value the CTM row's getter check establishes for this immutable ([`super::rows`]).
    CtmImmutable(CtmImmutable),
    /// Any non-zero address running the reviewed build of one of these contracts.
    ReviewedContract(&'static [&'static str]),
    /// The sub-verifier the verifier-tree walk read through this getter on this node.
    SubVerifier(SubVerifierGetter),
}

use ArgSource::*;

/// The source of every constructor argument of every member contract, by parameter name in
/// declaration order. A contract without parameters is listed with none; a contract missing from
/// the table, or a parameter without an entry, is unverified.
pub(super) const CONSTRUCTOR_EXPECTATIONS: &[(&str, &[(&str, ArgSource)])] = &[
    (
        "AdminFacet",
        &[
            ("_l1ChainId", L1ChainId),
            ("_rollupDAManager", RollupDaManager),
        ],
    ),
    ("GettersFacet", &[]),
    (
        "MailboxFacet",
        &[
            ("_l1ChainId", L1ChainId),
            ("_chainAssetHandler", EcosystemProxy("L1ChainAssetHandler")),
            ("_eip7702Checker", ReviewedContract(&["EIP7702Checker"])),
            ("_isTestnet", IsTestnet),
        ],
    ),
    ("ExecutorFacet", &[]),
    (
        "MigratorFacet",
        &[("_l1ChainId", L1ChainId), ("_isTestnet", IsTestnet)],
    ),
    ("CommitterFacet", &[("_l1ChainId", L1ChainId)]),
    ("DiamondInit", &[]),
    ("L1GenesisUpgrade", &[]),
    (
        "MultiProofTestnetVerifier",
        &[("_innerVerifier", SubVerifier(SubVerifierGetter::Inner))],
    ),
    (
        "MultiProofVerifier",
        &[
            (
                "_airbenderVerifier",
                SubVerifier(SubVerifierGetter::Airbender),
            ),
            (
                "_ziskRangeVerifier",
                SubVerifier(SubVerifierGetter::ZiskRange),
            ),
        ],
    ),
    (
        "ZKsyncOSTestnetVerifier",
        &[("_plonkVerifier", SubVerifier(SubVerifierGetter::Plonk))],
    ),
    (
        "ZKsyncOSVerifier",
        &[("_plonkVerifier", SubVerifier(SubVerifierGetter::Plonk))],
    ),
    ("ZKsyncOSVerifierPlonk", &[]),
    (
        "ZiskTestnetVerifier",
        &[("_innerVerifier", SubVerifier(SubVerifierGetter::Inner))],
    ),
    (
        "ZiskVerifier",
        &[("_plonkVerifier", SubVerifier(SubVerifierGetter::Plonk))],
    ),
    ("DefaultUpgrade", &[]),
    ("BootstrapUpgrade", &[]),
    ("L2DefaultDelegateCalldataComposer", &[]),
    (
        "L1Bridgehub",
        &[
            ("_owner", EcosystemOwner),
            ("_maxNumberOfZKChains", MaxNumberOfZkChains),
        ],
    ),
    (
        "L1ChainAssetHandler",
        &[("_owner", EcosystemOwner), ("_bridgehub", Bridgehub)],
    ),
    (
        "L1MessageRoot",
        &[
            ("_bridgehub", Bridgehub),
            ("_chainAssetHandler", EcosystemProxy("L1ChainAssetHandler")),
        ],
    ),
    (
        "L1Nullifier",
        &[
            ("_bridgehub", Bridgehub),
            ("_messageRoot", EcosystemProxy("L1MessageRoot")),
        ],
    ),
    (
        "L1AssetRouter",
        &[
            ("_l1WethToken", L1WethToken),
            ("_bridgehub", Bridgehub),
            ("_l1Nullifier", EcosystemProxy("L1Nullifier")),
        ],
    ),
    (
        "L1NativeTokenVault",
        &[
            ("_wethToken", L1WethToken),
            ("_assetRouter", EcosystemProxy("L1AssetRouter")),
            ("_l1Nullifier", EcosystemProxy("L1Nullifier")),
        ],
    ),
    (
        "L1InteropHandler",
        &[
            ("_messageRoot", EcosystemProxy("L1MessageRoot")),
            ("_l1AssetRouter", EcosystemProxy("L1AssetRouter")),
        ],
    ),
    (
        "CTMDeploymentTracker",
        &[
            ("_bridgehub", Bridgehub),
            ("_l1AssetRouter", EcosystemProxy("L1AssetRouter")),
        ],
    ),
    ("ChainRegistrationSender", &[("_bridgehub", Bridgehub)]),
    (
        "ChainTypeManager",
        &[
            ("_bridgehub", Bridgehub),
            ("_interopCenter", CtmImmutable(CtmImmutable::InteropCenter)),
            (
                "_l1BytecodesSupplier",
                CtmImmutable(CtmImmutable::BytecodesSupplier),
            ),
            (
                "_permissionlessValidator",
                CtmImmutable(CtmImmutable::PermissionlessValidator),
            ),
            (
                "_l1InteropFeeManager",
                CtmImmutable(CtmImmutable::InteropFeeManager),
            ),
        ],
    ),
    ("ValidatorTimelock", &[("_bridgehubAddr", Bridgehub)]),
    ("MultisigCommitter", &[("_bridgehubAddr", Bridgehub)]),
    ("BytecodesSupplier", &[]),
    ("PermissionlessValidator", &[]),
    ("ServerNotifier", &[]),
    ("L1InteropFeeManager", &[("_bridgehub", Bridgehub)]),
    ("EIP7702Checker", &[]),
];

/// The reviewer's inputs an argument may be held against: the env's permanent values and the
/// Bridgehub of the ecosystem under review.
#[derive(Debug, Default)]
pub(crate) struct ReviewedEnv {
    /// The env the permanent values come from; `None` without `--env`.
    name: Option<String>,
    testnet_verifier: Option<bool>,
    l1_chain_id: Option<u64>,
    /// The Bridgehub under review and where the review takes it from: `--expected-bridgehub`,
    /// else the env's `bridgehub_proxy_addr`.
    bridgehub: Option<(Address, String)>,
    /// `[[ctm_contracts.ctms]]`: every CTM the env lists, with the `rollup_da_manager` it
    /// declares for it.
    ctms: BTreeMap<Address, Option<Address>>,
}

impl ReviewedEnv {
    /// The values of `config` (when `--env` names one), with the Bridgehub `expected_bridgehub`
    /// names in place of the env's when given.
    pub(crate) fn new(config: Option<&EnvConfig>, expected_bridgehub: Option<Address>) -> Self {
        let bridgehub = match (expected_bridgehub, config) {
            (Some(bridgehub), _) => Some((bridgehub, "the reviewer's --expected-bridgehub".into())),
            (None, Some(config)) => Some((
                config.bridgehub(),
                format!("env {}'s bridgehub_proxy_addr", config.env),
            )),
            (None, None) => None,
        };
        Self {
            name: config.map(|config| config.env.clone()),
            testnet_verifier: config.and_then(EnvConfig::testnet_verifier),
            l1_chain_id: config.and_then(EnvConfig::l1_chain_id),
            bridgehub,
            ctms: config
                .map(|config| {
                    config
                        .ctms()
                        .iter()
                        .map(|ctm| (ctm.proxy, ctm.rollup_da_manager))
                        .collect()
                })
                .unwrap_or_default(),
        }
    }

    /// The env's name for the report.
    fn env(&self) -> String {
        match &self.name {
            Some(name) => format!("env {name}"),
            None => "no --env".to_string(),
        }
    }

    /// An env named `test` declaring `testnet_verifier` and `bridgehub_proxy_addr`, for tests.
    #[cfg(test)]
    pub(crate) fn for_test(testnet_verifier: Option<bool>, bridgehub: Option<Address>) -> Self {
        Self {
            name: Some("test".to_string()),
            testnet_verifier,
            bridgehub: bridgehub
                .map(|bridgehub| (bridgehub, "env test's bridgehub_proxy_addr".to_string())),
            ..Default::default()
        }
    }
}

/// Per-member inputs an argument source may need beyond the review's.
#[derive(Clone, Copy)]
pub(super) enum ArgContext<'c> {
    None,
    /// The sub-verifiers the verifier-tree walk read on this node.
    SubVerifiers(&'c [(SubVerifierGetter, Address)]),
    /// The values the CTM row's getter check established for the CTM's immutables.
    CtmImmutables(&'c CtmImmutableExpectations),
}

/// An argument's expected value and where it comes from, or why nothing establishes it.
type Established = Result<(DynSolValue, String), String>;

/// The records of a package and the sources its members' arguments are held against.
pub(crate) struct MemberReview<'a> {
    records: &'a MemberDeployments,
    env: &'a ReviewedEnv,
    /// The CTM the package upgrades, through which the RollupDAManager is found; held against
    /// the reviewed Bridgehub before it is used.
    ctm: Option<Address>,
    /// The core prepare's `bridgehub_proxy_addr`, held against the reviewed Bridgehub.
    reported_bridgehub: Option<Address>,
    resolved: RefCell<HashMap<ArgSource, Established>>,
    consulted: RefCell<BTreeSet<Address>>,
}

impl<'a> MemberReview<'a> {
    pub(crate) fn new(
        records: &'a MemberDeployments,
        env: &'a ReviewedEnv,
        ctm: Option<Address>,
        reported_bridgehub: Option<Address>,
    ) -> Self {
        Self {
            records,
            env,
            ctm,
            reported_bridgehub,
            resolved: RefCell::new(HashMap::new()),
            consulted: RefCell::new(BTreeSet::new()),
        }
    }

    /// Whether the package records a deployment at `address`.
    pub(super) fn has_record(&self, address: Address) -> bool {
        self.records.contains_key(&address)
    }

    /// Prints the records no check of this review consulted: deployments of the run that no
    /// object the package installs names. Everything installed is checked where it is named, so
    /// these are informational.
    pub(crate) fn report_unconsulted(&self, result: &VerificationResult) {
        let consulted = self.consulted.borrow();
        let unconsulted: Vec<String> = self
            .records
            .iter()
            .filter(|(address, _)| !consulted.contains(*address))
            .map(|(address, record)| format!("{} at {address}", record.contract))
            .collect();
        if !unconsulted.is_empty() {
            result.print_info(&format!(
                "  {} recorded deployment(s) no check of this review consulted: {}",
                unconsulted.len(),
                unconsulted.join(", ")
            ));
        }
    }

    async fn establish<P: Provider>(
        &self,
        provider: &P,
        source: ArgSource,
        context: ArgContext<'_>,
    ) -> Established {
        match source {
            IsTestnet => {
                return match self.env.testnet_verifier {
                    Some(testnet) => Ok((
                        DynSolValue::Bool(testnet),
                        format!("{}'s testnet_verifier", self.env.env()),
                    )),
                    None => Err(format!(
                        "{} declares no testnet_verifier to hold it against",
                        self.env.env()
                    )),
                }
            }
            CtmImmutable(immutable) => {
                let ArgContext::CtmImmutables(expectations) = context else {
                    return Err("no CTM immutable is established for this member".into());
                };
                return match expectations.iter().find(|(i, _)| *i == immutable) {
                    Some((_, Some((value, source)))) => {
                        Ok((DynSolValue::Address(*value), source.clone()))
                    }
                    _ => Err(format!(
                        "neither the live CTM nor the package establishes its {}",
                        immutable.getter()
                    )),
                };
            }
            SubVerifier(getter) => {
                let ArgContext::SubVerifiers(read) = context else {
                    return Err("no verifier-tree read names it".into());
                };
                return match read.iter().find(|(g, _)| *g == getter) {
                    Some((_, address)) => Ok((
                        DynSolValue::Address(*address),
                        format!("the {}() the verifier tree read on it", getter.name()),
                    )),
                    None => Err(format!("its {}() could not be read", getter.name())),
                };
            }
            ReviewedContract(_) => unreachable!("judged by the code at the recorded value"),
            _ => {}
        }
        if let Some(held) = self.resolved.borrow().get(&source) {
            return held.clone();
        }
        let established = Box::pin(self.read_live(provider, source)).await;
        self.resolved
            .borrow_mut()
            .insert(source, established.clone());
        established
    }

    /// The reviewed Bridgehub, as [`Self::establish`] holds it.
    async fn bridgehub<P: Provider>(&self, provider: &P) -> Result<(Address, String), String> {
        let established = Box::pin(self.establish(provider, Bridgehub, ArgContext::None)).await;
        match established? {
            (DynSolValue::Address(bridgehub), source) => Ok((bridgehub, source)),
            (other, _) => Err(format!("{other:?} is not an address")),
        }
    }

    /// The sources read from live state, each at most once per review.
    async fn read_live<P: Provider>(&self, provider: &P, source: ArgSource) -> Established {
        match source {
            L1ChainId => {
                let live = provider
                    .get_chain_id()
                    .await
                    .map_err(|e| format!("eth_chainId could not be read ({e})"))?;
                match self.env.l1_chain_id {
                    Some(declared) if declared != live => Err(format!(
                        "the RPC's chain id {live} is not {}'s l1_chain_id {declared}",
                        self.env.env()
                    )),
                    _ => Ok((
                        DynSolValue::Uint(U256::from(live), 256),
                        "the L1's chain id".to_string(),
                    )),
                }
            }
            Bridgehub => self.read_bridgehub(provider).await,
            EcosystemProxy(member) => {
                let (bridgehub, _) = self.bridgehub(provider).await?;
                match discover_slot_proxy(provider, Inventory::Ecosystem, member, bridgehub).await?
                {
                    Some(proxy) if !proxy.is_zero() => Ok((
                        DynSolValue::Address(proxy),
                        format!("the live {member}, discovered through the Bridgehub {bridgehub}"),
                    )),
                    Some(_) => Err(format!(
                        "the Bridgehub {bridgehub} names no {member} (the zero address)"
                    )),
                    None => Err(format!("{member} is no ecosystem proxy")),
                }
            }
            L1WethToken | EcosystemOwner => {
                let router = match Box::pin(self.establish(
                    provider,
                    EcosystemProxy("L1AssetRouter"),
                    ArgContext::None,
                ))
                .await?
                {
                    (DynSolValue::Address(router), _) => router,
                    (other, _) => return Err(format!("{other:?} is not an address")),
                };
                let view = L1AssetRouterView::new(router, provider);
                let (read, getter) = if source == L1WethToken {
                    (view.L1_WETH_TOKEN().call().await, "L1_WETH_TOKEN()")
                } else {
                    (view.owner().call().await, "owner()")
                };
                let value = read.map_err(|e| {
                    format!("the asset router {router}'s {getter} could not be read ({e})")
                })?;
                Ok((
                    DynSolValue::Address(value),
                    format!("the asset router {router}'s {getter}"),
                ))
            }
            MaxNumberOfZkChains => {
                let (bridgehub, _) = self.bridgehub(provider).await?;
                let value = BridgehubView::new(bridgehub, provider)
                    .MAX_NUMBER_OF_ZK_CHAINS()
                    .call()
                    .await
                    .map_err(|e| {
                        format!("the Bridgehub's MAX_NUMBER_OF_ZK_CHAINS() could not be read ({e})")
                    })?;
                Ok((
                    DynSolValue::Uint(value, 256),
                    format!("the Bridgehub {bridgehub}'s MAX_NUMBER_OF_ZK_CHAINS()"),
                ))
            }
            RollupDaManager => self.rollup_da_manager(provider).await,
            IsTestnet | CtmImmutable(_) | ReviewedContract(_) | SubVerifier(_) => {
                unreachable!("not read from live state")
            }
        }
    }

    /// The reviewed Bridgehub, once the package's CTM and its `bridgehub_proxy_addr` (whichever
    /// it names) agree with it.
    async fn read_bridgehub<P: Provider>(&self, provider: &P) -> Established {
        let Some((reviewed, source)) = self.env.bridgehub.clone() else {
            return Err(
                "neither --env nor --expected-bridgehub names the Bridgehub under review".into(),
            );
        };
        if reviewed.is_zero() {
            return Err(format!("{source} is the zero address"));
        }
        if let Some(reported) = self.reported_bridgehub {
            if reported != reviewed {
                return Err(format!(
                    "the package's bridgehub_proxy_addr {reported} is not {source} {reviewed}"
                ));
            }
        }
        if let Some(ctm) = self.ctm {
            let live = CtmView::new(ctm, provider)
                .BRIDGE_HUB()
                .call()
                .await
                .map_err(|e| {
                    format!("the package's CTM {ctm}'s BRIDGE_HUB() could not be read ({e})")
                })?;
            if live != reviewed {
                return Err(format!(
                    "the package's CTM {ctm} answers BRIDGE_HUB() {live}, not {source} {reviewed}"
                ));
            }
        }
        Ok((DynSolValue::Address(reviewed), source))
    }

    async fn rollup_da_manager<P: Provider>(&self, provider: &P) -> Established {
        let Some(ctm) = self.ctm else {
            return Err("the package names no CTM whose RollupDAManager it is".into());
        };
        if !self.env.ctms.is_empty() && !self.env.ctms.contains_key(&ctm) {
            return Err(format!(
                "{} lists the CTM(s) {}, not the package's CTM {ctm}",
                self.env.env(),
                self.env
                    .ctms
                    .keys()
                    .map(Address::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        let declared = self.env.ctms.get(&ctm).copied().flatten();
        if declared.is_some_and(|declared| declared.is_zero()) {
            return Err(format!(
                "{} declares the zero address as the CTM's rollup_da_manager",
                self.env.env()
            ));
        }
        let from_chain = self.rollup_da_manager_of_a_chain(provider, ctm).await;
        match (declared, from_chain) {
            (Some(declared), Ok(Some((live, chain)))) if declared != live => Err(format!(
                "{}'s rollup_da_manager {declared} is not chain {chain}'s getRollupDAManager() \
                 {live}",
                self.env.env()
            )),
            (Some(declared), _) => Ok((
                DynSolValue::Address(declared),
                format!("{}'s rollup_da_manager for the CTM", self.env.env()),
            )),
            (None, Ok(Some((live, chain)))) if live.is_zero() => Err(format!(
                "chain {chain}'s getRollupDAManager() is the zero address"
            )),
            (None, Ok(Some((live, chain)))) => Ok((
                DynSolValue::Address(live),
                format!("chain {chain}'s getRollupDAManager(), the first chain on the CTM"),
            )),
            (None, Ok(None)) => Err(format!(
                "the reviewed Bridgehub registers no chain on the CTM {ctm} and {} declares no \
                 rollup_da_manager for it",
                self.env.env()
            )),
            (None, Err(why)) => Err(why),
        }
    }

    /// The `getRollupDAManager()` of the first chain the reviewed Bridgehub registers on `ctm`,
    /// with its chain id.
    async fn rollup_da_manager_of_a_chain<P: Provider>(
        &self,
        provider: &P,
        ctm: Address,
    ) -> Result<Option<(Address, U256)>, String> {
        let (bridgehub, _) = self.bridgehub(provider).await?;
        let view = BridgehubView::new(bridgehub, provider);
        let ids = view
            .getAllZKChainChainIDs()
            .call()
            .await
            .map_err(|e| format!("the Bridgehub's chains could not be enumerated ({e})"))?;
        for id in ids {
            let chain_ctm = view
                .chainTypeManager(id)
                .call()
                .await
                .map_err(|e| format!("chain {id}'s CTM could not be read ({e})"))?;
            if chain_ctm != ctm {
                continue;
            }
            let diamond = view
                .getZKChain(id)
                .call()
                .await
                .map_err(|e| format!("chain {id}'s diamond could not be read ({e})"))?;
            let manager = ZkChainGettersView::new(diamond, provider)
                .getRollupDAManager()
                .call()
                .await
                .map_err(|e| {
                    format!("chain {id}'s getRollupDAManager() could not be read ({e})")
                })?;
            return Ok(Some((manager, id)));
        }
        Ok(None)
    }
}

/// One member to hold to its record.
pub(super) struct Member<'s> {
    pub(super) label: &'s str,
    pub(super) address: Address,
    /// The contracts its role admits.
    pub(super) admitted: &'static [&'static str],
    /// The contract code identity found it to run.
    pub(super) identified: &'static str,
    /// What already names it on the departing side, when something does: then it needs no record.
    pub(super) carried_over: Option<String>,
    /// Why it must have been deployed by the package's prepares when nothing carries it over.
    pub(super) new_because: &'s str,
    pub(super) context: ArgContext<'s>,
}

/// Holds `member` to its construction record (see the module docs). Each failing step reports one
/// error and ends the check, except the argument step, which reports per argument.
pub(super) async fn expect_member_construction<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &MemberReview<'_>,
    member: Member<'_>,
) -> anyhow::Result<()> {
    let Member {
        label,
        address,
        admitted,
        identified,
        carried_over,
        new_because,
        context,
    } = member;
    if let Some(source) = carried_over {
        result.report_ok(&format!(
            "{label} at {address} is carried over from {source}: no construction record is needed"
        ));
        return Ok(());
    }
    let Some(record) = review.records.get(&address) else {
        result.report_error(&format!(
            "{label} at {address} is new — {new_because} — but the package records no \
             construction for it (`member_deployments`): the values its constructor wrote into \
             its immutable slots are unverified. The prepare that deployed it writes the record; \
             regenerate the package with this commit's prepare"
        ));
        return Ok(());
    };
    review.consulted.borrow_mut().insert(address);
    let Some(args) = derive(build, result, label, address, admitted, identified, record) else {
        return Ok(());
    };
    judge_arguments(
        provider,
        build,
        result,
        review,
        label,
        &record.contract,
        args,
        context,
    )
    .await
}

/// The record's factory, contract and arguments, and the address they derive: the decoded
/// arguments with their parameter names when the record describes this deployment, `None` with
/// the failure reported otherwise.
fn derive(
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
    admitted: &[&str],
    identified: &str,
    record: &MemberDeploymentRecord,
) -> Option<Vec<(String, DynSolValue)>> {
    let contract = record.contract.as_str();
    if record.create2_factory != DETERMINISTIC_CREATE2_FACTORY {
        result.report_error(&format!(
            "{label} at {address}: its record names CREATE2 factory {}, not the deterministic \
             deployment proxy {DETERMINISTIC_CREATE2_FACTORY} every prepare deploys through",
            record.create2_factory
        ));
        return None;
    }
    if !admitted.contains(&contract) {
        result.report_error(&format!(
            "{label} at {address}: its record names {contract}, which this role does not admit \
             ({})",
            admitted.join(" or ")
        ));
        return None;
    }
    if contract != identified {
        result.report_error(&format!(
            "{label} at {address}: its record names {contract}, but the live code is the \
             reviewed {identified}"
        ));
        return None;
    }
    let artifact = match build.get(contract) {
        Ok(artifact) => artifact,
        Err(why) => {
            result.report_error(&format!(
                "{label} at {address}: its construction cannot be verified — {why}"
            ));
            return None;
        }
    };
    let inputs = artifact.constructor_inputs();
    let types: Vec<DynSolType> = inputs.iter().map(|(_, ty)| ty.clone()).collect();
    let decoded = DynSolType::Tuple(types.clone())
        .abi_decode_params(&record.constructor_args)
        .ok()
        .filter(|value| value.abi_encode_params() == record.constructor_args[..]);
    let Some(DynSolValue::Tuple(values)) = decoded else {
        result.report_error(&format!(
            "{label} at {address}: the recorded constructor arguments ({} bytes) are not exactly \
             the ABI encoding of {contract}({}): CREATE2 hashes every byte, so a loosely decoded \
             record would describe init code the constructor never reads",
            record.constructor_args.len(),
            types
                .iter()
                .map(|ty| ty.sol_type_name().into_owned())
                .collect::<Vec<_>>()
                .join(", ")
        ));
        return None;
    };
    let derived = canonical_create2_address(
        record.create2_salt,
        artifact.creation_code(),
        &record.constructor_args,
    );
    if derived != address {
        result.report_error(&format!(
            "{label} at {address} is NOT the reviewed {contract} built from its recorded \
             constructor arguments: the reviewed creation code ({}) run on them under the \
             recorded salt {} lands at {derived}. The record does not describe this deployment, \
             or the code there was not built by the reviewed constructor",
            artifact.artifact_file(),
            record.create2_salt
        ));
        return None;
    }
    result.report_ok(&format!(
        "{label} at {address} IS the reviewed {contract} built from its recorded constructor \
         arguments (CREATE2 salt {})",
        record.create2_salt
    ));
    Some(
        inputs
            .iter()
            .map(|(name, _)| name.clone())
            .zip(values)
            .collect(),
    )
}

/// Holds each decoded argument against the source [`CONSTRUCTOR_EXPECTATIONS`] names for it.
#[allow(clippy::too_many_arguments)]
async fn judge_arguments<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &MemberReview<'_>,
    label: &str,
    contract: &str,
    args: Vec<(String, DynSolValue)>,
    context: ArgContext<'_>,
) -> anyhow::Result<()> {
    let Some(expectations) = CONSTRUCTOR_EXPECTATIONS
        .iter()
        .find(|(name, _)| *name == contract)
        .map(|(_, params)| *params)
    else {
        result.report_error(&format!(
            "{label}: this verifier holds no expectations for {contract}'s constructor, so the \
             values it was built from are unverified"
        ));
        return Ok(());
    };
    for (param, _) in expectations {
        if !args.iter().any(|(name, _)| name == param) {
            result.report_error(&format!(
                "{label}: this verifier expects {contract}'s constructor to take {param}, which \
                 the reviewed build's constructor does not declare: the expectations no longer \
                 describe the build"
            ));
        }
    }
    for (param, value) in args {
        let shown = show(&value);
        let Some((_, source)) = expectations.iter().find(|(name, _)| *name == param) else {
            result.report_error(&format!(
                "{label}: {contract}.{param} = {shown} has no reviewed expectation in this \
                 verifier: unverified"
            ));
            continue;
        };
        if let ReviewedContract(names) = source {
            judge_reviewed_contract(
                provider, build, result, review, label, contract, &param, &value, names,
            )
            .await?;
            continue;
        }
        match review.establish(provider, *source, context).await {
            Ok((expected, from)) if expected == value => {
                result.report_ok(&format!("{label}: {contract}.{param} is {shown} — {from}"))
            }
            Ok((expected, from)) => result.report_error(&format!(
                "{label}: {contract}.{param} is {shown}, but {from} is {}",
                show(&expected)
            )),
            Err(why) => result.report_error(&format!(
                "{label}: {contract}.{param} is {shown}, and nothing establishes the value it must \
                 have ({why}): unverified"
            )),
        }
    }
    Ok(())
}

/// An argument that must name a contract running the reviewed build of one of `names`. A
/// recorded deployment found there counts as consulted.
#[allow(clippy::too_many_arguments)]
async fn judge_reviewed_contract<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    review: &MemberReview<'_>,
    label: &str,
    contract: &str,
    param: &str,
    value: &DynSolValue,
    names: &'static [&'static str],
) -> anyhow::Result<()> {
    let expectation = names.join(" or ");
    let target = match value {
        DynSolValue::Address(target) if !target.is_zero() => *target,
        other => {
            result.report_error(&format!(
                "{label}: {contract}.{param} is {}, but it must be a deployed {expectation}",
                show(other)
            ));
            return Ok(());
        }
    };
    let code = provider.get_code_at(target).await?;
    match classify_code(build, &code, names) {
        CodeVerdict::Reviewed { name, .. } => {
            review.consulted.borrow_mut().insert(target);
            result.report_ok(&format!(
                "{label}: {contract}.{param} is {target}, which runs the reviewed {name}"
            ))
        }
        _ => result.report_error(&format!(
            "{label}: {contract}.{param} is {target}, but the code there ({} bytes) is not the \
             reviewed build of {expectation}",
            code.len()
        )),
    }
    Ok(())
}

fn show(value: &DynSolValue) -> String {
    match value {
        DynSolValue::Address(address) => address.to_string(),
        DynSolValue::Uint(value, _) => value.to_string(),
        DynSolValue::Bool(value) => value.to_string(),
        other => format!("{other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::registry::members::{FACETS, MEMBER_ARTIFACTS, VERIFIERS};
    use crate::upgrade_verification::registry::provenance::CodeIdentity;
    use alloy::primitives::{Bytes, B256, U64};
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    const SALT: B256 = B256::repeat_byte(0x5A);
    const CHAIN_ID: u64 = 1;
    const BRIDGEHUB: Address = Address::repeat_byte(0xB0);
    const CTM: Address = Address::repeat_byte(0xC7);
    const DA_MANAGER: Address = Address::repeat_byte(0xDA);
    const DIAMOND: Address = Address::repeat_byte(0xD1);
    const HANDLER: Address = Address::repeat_byte(0xCA);
    const CHECKER: Address = Address::repeat_byte(0xEC);
    const OTHER: Address = Address::repeat_byte(0x03);
    const CHECKER_RUNTIME: &[u8] = b"the reviewed EIP7702Checker runtime";

    fn creation(name: &str) -> Vec<u8> {
        format!("the creation code of {name}").into_bytes()
    }

    /// A build of the members these tests deploy, each with the constructor it declares.
    fn build() -> ReviewedBuild {
        let contracts: &[(&'static str, &[(&str, &str)])] = &[
            (
                "AdminFacet",
                &[("_l1ChainId", "uint256"), ("_rollupDAManager", "address")],
            ),
            ("CommitterFacet", &[("_l1ChainId", "uint256")]),
            (
                "MigratorFacet",
                &[("_l1ChainId", "uint256"), ("_isTestnet", "bool")],
            ),
            (
                "MailboxFacet",
                &[
                    ("_l1ChainId", "uint256"),
                    ("_chainAssetHandler", "address"),
                    ("_eip7702Checker", "address"),
                    ("_isTestnet", "bool"),
                ],
            ),
            ("GettersFacet", &[]),
            ("EIP7702Checker", &[]),
            ("ValidatorTimelock", &[("_bridgehubAddr", "address")]),
            (
                "L1MessageRoot",
                &[("_bridgehub", "address"), ("_chainAssetHandler", "address")],
            ),
            (
                "L1Bridgehub",
                &[("_owner", "address"), ("_maxNumberOfZKChains", "uint256")],
            ),
            ("ZKsyncOSTestnetVerifier", &[("_plonkVerifier", "address")]),
            ("Unexpected", &[]),
        ];
        let mut build = ReviewedBuild::from_artifacts(
            CodeIdentity::empty(),
            contracts
                .iter()
                .map(|(name, _)| {
                    let runtime = if *name == "EIP7702Checker" {
                        CHECKER_RUNTIME.to_vec()
                    } else {
                        format!("the runtime of {name}").into_bytes()
                    };
                    (*name, *name, creation(name), runtime, Vec::new())
                })
                .collect(),
        );
        for (name, inputs) in contracts {
            build = build.with_constructor(name, inputs);
        }
        build
    }

    /// The record of `contract` built from `args` under `salt`.
    fn record_under(salt: B256, contract: &str, args: Vec<u8>) -> MemberDeploymentRecord {
        MemberDeploymentRecord {
            contract: contract.to_string(),
            create2_factory: DETERMINISTIC_CREATE2_FACTORY,
            create2_salt: salt,
            constructor_args: Bytes::from(args),
        }
    }

    fn record(contract: &str, args: Vec<u8>) -> MemberDeploymentRecord {
        record_under(SALT, contract, args)
    }

    /// Where the deterministic factory lands `record`'s deployment.
    fn landing(record: &MemberDeploymentRecord) -> Address {
        canonical_create2_address(
            record.create2_salt,
            &creation(&record.contract),
            &record.constructor_args,
        )
    }

    /// `record` keyed at `address`.
    fn at(address: Address, record: MemberDeploymentRecord) -> MemberDeployments {
        [(address, record)].into_iter().collect()
    }

    /// A new member of `admitted` running `contract`, which the departing side does not name.
    fn member(
        address: Address,
        admitted: &'static [&'static str],
        identified: &'static str,
    ) -> Member<'static> {
        Member {
            label: "the member",
            address,
            admitted,
            identified,
            carried_over: None,
            new_because: "the test installs it",
            context: ArgContext::None,
        }
    }

    /// An env named `test`: its Bridgehub, its testnet verifier flag, and the CTMs it lists.
    fn env(
        bridgehub: Option<Address>,
        testnet: Option<bool>,
        ctms: &[(Address, Option<Address>)],
    ) -> ReviewedEnv {
        ReviewedEnv {
            ctms: ctms.iter().copied().collect(),
            ..ReviewedEnv::for_test(testnet, bridgehub)
        }
    }

    /// Holds `member` to `records` with the package naming `ctm` and `reported_bridgehub`, over
    /// a mocked L1 that `answers` queues, and requires every queued answer to be read.
    async fn hold(
        records: &MemberDeployments,
        env: &ReviewedEnv,
        (ctm, reported_bridgehub): (Option<Address>, Option<Address>),
        member: Member<'_>,
        answers: impl FnOnce(&Asserter),
    ) -> VerificationResult {
        let asserter = Asserter::new();
        answers(&asserter);
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let review = MemberReview::new(records, env, ctm, reported_bridgehub);
        expect_member_construction(&provider, &build(), &mut result, &review, member)
            .await
            .unwrap();
        assert!(asserter.read_q().is_empty(), "every answer was read");
        result
    }

    fn address(asserter: &Asserter, value: Address) {
        asserter.push_success(&Bytes::from(value.abi_encode()));
    }

    fn chain_id(asserter: &Asserter) {
        asserter.push_success(&U64::from(CHAIN_ID));
    }

    /// The reads that find the RollupDAManager of the one chain registered on the CTM: the CTM's
    /// `BRIDGE_HUB()` (the Bridgehub cross-check), the chain ids, the chain's CTM and diamond,
    /// then its `getRollupDAManager()`.
    fn chain_on_the_ctm(asserter: &Asserter, manager: Address) {
        address(asserter, BRIDGEHUB);
        asserter.push_success(&Bytes::from(vec![U256::from(10)].abi_encode()));
        address(asserter, CTM);
        address(asserter, DIAMOND);
        address(asserter, manager);
    }

    fn admin_record(chain: u64, manager: Address) -> MemberDeploymentRecord {
        record(
            "AdminFacet",
            (U256::from(chain), manager).abi_encode_params(),
        )
    }

    // ───────────────────────── derivation ─────────────────────────

    /// A genuine record whose every argument holds: AdminFacet built for this L1 over the
    /// RollupDAManager the env declares and the chain on the CTM runs.
    #[tokio::test]
    async fn a_recorded_member_rederives_and_its_arguments_hold() {
        let record = admin_record(CHAIN_ID, DA_MANAGER);
        let facet = landing(&record);
        let result = hold(
            &at(facet, record),
            &env(Some(BRIDGEHUB), None, &[(CTM, Some(DA_MANAGER))]),
            (Some(CTM), Some(BRIDGEHUB)),
            member(facet, FACETS, "AdminFacet"),
            |asserter| {
                chain_id(asserter);
                chain_on_the_ctm(asserter, DA_MANAGER);
            },
        )
        .await;
        assert_eq!(
            (result.errors, result.warnings),
            (0, 0),
            "{:?}",
            result.error_messages
        );
    }

    /// The record's salt is not the one the member was deployed under: the derivation lands
    /// elsewhere, and nothing is read.
    #[tokio::test]
    async fn a_wrong_salt_fails() {
        let deployed = record("CommitterFacet", U256::from(CHAIN_ID).abi_encode());
        let facet = landing(&deployed);
        let lying = MemberDeploymentRecord {
            create2_salt: B256::repeat_byte(0x5B),
            ..deployed
        };
        let result = hold(
            &at(facet, lying),
            &ReviewedEnv::default(),
            (None, None),
            member(facet, FACETS, "CommitterFacet"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("is NOT the reviewed CommitterFacet built from its recorded"));
    }

    /// A record claiming the expected value for a member deployed over another cannot lie its way
    /// through: CREATE2 hashes the arguments, so the claimed ones derive another address.
    #[tokio::test]
    async fn tampered_arguments_fail() {
        let facet = landing(&admin_record(CHAIN_ID, OTHER));
        let result = hold(
            &at(facet, admin_record(CHAIN_ID, DA_MANAGER)),
            &env(Some(BRIDGEHUB), None, &[(CTM, Some(DA_MANAGER))]),
            (Some(CTM), Some(BRIDGEHUB)),
            member(facet, FACETS, "AdminFacet"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("is NOT the reviewed AdminFacet"));
    }

    /// A member deployed by plain CREATE (from an EOA or a factory of its own) is at no address
    /// its record, or any record, derives through the deterministic factory.
    #[tokio::test]
    async fn a_member_deployed_by_plain_create_fails() {
        let deployed = Address::repeat_byte(0xEE).create(7);
        let result = hold(
            &at(
                deployed,
                record("CommitterFacet", U256::from(CHAIN_ID).abi_encode()),
            ),
            &ReviewedEnv::default(),
            (None, None),
            member(deployed, FACETS, "CommitterFacet"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("is NOT the reviewed CommitterFacet"));
    }

    /// The genuine construction of a member built over a wrong value: the record describes it
    /// exactly, so it re-derives, and the argument check is what fails.
    #[tokio::test]
    async fn a_genuine_construction_with_a_wrong_immutable_value_fails() {
        let record = record("CommitterFacet", U256::from(5).abi_encode());
        let facet = landing(&record);
        let result = hold(
            &at(facet, record),
            &ReviewedEnv::default(),
            (None, None),
            member(facet, FACETS, "CommitterFacet"),
            chain_id,
        )
        .await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("CommitterFacet._l1ChainId is 5, but the L1's chain id is 1"));
    }

    /// A record naming another factory — even one its address derives under — is not a
    /// deployment through the deterministic proxy every prepare uses.
    #[tokio::test]
    async fn a_wrong_factory_fails() {
        let mut record = record("CommitterFacet", U256::from(CHAIN_ID).abi_encode());
        record.create2_factory = OTHER;
        let mut init_code = creation("CommitterFacet");
        init_code.extend_from_slice(&record.constructor_args);
        let facet = OTHER.create2(SALT, alloy::primitives::keccak256(&init_code));
        let result = hold(
            &at(facet, record),
            &ReviewedEnv::default(),
            (None, None),
            member(facet, FACETS, "CommitterFacet"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("its record names CREATE2 factory"));
    }

    #[tokio::test]
    async fn an_unrecorded_new_member_fails() {
        let result = hold(
            &MemberDeployments::new(),
            &ReviewedEnv::default(),
            (None, None),
            member(OTHER, FACETS, "CommitterFacet"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("is new — the test installs it — but the package records no"));
    }

    #[tokio::test]
    async fn a_departing_member_needs_no_record() {
        let result = hold(
            &MemberDeployments::new(),
            &ReviewedEnv::default(),
            (None, None),
            Member {
                carried_over: Some("the departing release".to_string()),
                ..member(OTHER, FACETS, "CommitterFacet")
            },
            |_| {},
        )
        .await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// The exact ABI encoding plus 32 more bytes: CREATE2 derives the address from all of them,
    /// but the constructor never reads the tail, so the record describes no construction the
    /// review can hold to values.
    #[tokio::test]
    async fn trailing_bytes_in_the_arguments_fail() {
        let mut args = U256::from(CHAIN_ID).abi_encode();
        args.extend_from_slice(&[0; 32]);
        let record = record("CommitterFacet", args);
        let facet = landing(&record);
        let result = hold(
            &at(facet, record),
            &ReviewedEnv::default(),
            (None, None),
            member(facet, FACETS, "CommitterFacet"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("are not exactly the ABI encoding of CommitterFacet(uint256)"));
    }

    /// The record must name the contract code identity found there, and one the role admits.
    #[tokio::test]
    async fn a_record_naming_another_contract_fails() {
        let getters = record("GettersFacet", Vec::new());
        let facet = landing(&getters);
        let result = hold(
            &at(facet, getters),
            &ReviewedEnv::default(),
            (None, None),
            member(facet, FACETS, "AdminFacet"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("but the live code is the reviewed AdminFacet"));

        let checker = record("EIP7702Checker", Vec::new());
        let facet = landing(&checker);
        let result = hold(
            &at(facet, checker),
            &ReviewedEnv::default(),
            (None, None),
            member(facet, FACETS, "EIP7702Checker"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("which this role does not admit"));
    }

    /// A recorded contract the build does not hold cannot be re-derived.
    #[tokio::test]
    async fn a_record_of_an_unbuilt_contract_fails() {
        let executor = record("ExecutorFacet", Vec::new());
        let facet = landing(&executor);
        let result = hold(
            &at(facet, executor),
            &ReviewedEnv::default(),
            (None, None),
            member(facet, FACETS, "ExecutorFacet"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("its construction cannot be verified"));
    }

    // ───────────────────────── the arguments ─────────────────────────

    /// An argument nothing establishes is unverified, never passed: no env for the testnet flag,
    /// no source at all for the RollupDAManager, an env and a chain that disagree, a CTM no chain
    /// is registered on, and a CTM the env does not list.
    #[tokio::test]
    async fn an_unestablished_expectation_fails() {
        let migrator = record(
            "MigratorFacet",
            (U256::from(CHAIN_ID), true).abi_encode_params(),
        );
        let facet = landing(&migrator);
        let result = hold(
            &at(facet, migrator),
            &ReviewedEnv::default(),
            (None, None),
            member(facet, FACETS, "MigratorFacet"),
            chain_id,
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("no --env declares no testnet_verifier"));

        let admin = admin_record(CHAIN_ID, DA_MANAGER);
        let facet = landing(&admin);
        let records = at(facet, admin);
        let run = |env: ReviewedEnv, answers: fn(&Asserter)| {
            let records = &records;
            async move {
                hold(
                    records,
                    &env,
                    (Some(CTM), None),
                    member(facet, FACETS, "AdminFacet"),
                    answers,
                )
                .await
            }
        };
        let result = run(ReviewedEnv::default(), chain_id).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("neither --env nor --expected-bridgehub names the Bridgehub"));

        let result = run(
            env(Some(BRIDGEHUB), None, &[(CTM, Some(DA_MANAGER))]),
            |asserter| {
                chain_id(asserter);
                chain_on_the_ctm(asserter, OTHER);
            },
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("is not chain 10's getRollupDAManager()"));

        let result = run(env(Some(BRIDGEHUB), None, &[]), |asserter| {
            chain_id(asserter);
            address(asserter, BRIDGEHUB);
            asserter.push_success(&Bytes::from(Vec::<U256>::new().abi_encode()));
        })
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("registers no chain on the CTM"));

        let result = run(
            env(Some(BRIDGEHUB), None, &[(OTHER, Some(DA_MANAGER))]),
            chain_id,
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("not the package's CTM"));

        // With no env value, the chain on the CTM establishes it.
        let result = run(env(Some(BRIDGEHUB), None, &[]), |asserter| {
            chain_id(asserter);
            chain_on_the_ctm(asserter, DA_MANAGER);
        })
        .await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);
    }

    /// The Bridgehub is the reviewer's — the env's `bridgehub_proxy_addr` or
    /// `--expected-bridgehub` — never the package's: a package naming another Bridgehub, or a
    /// CTM built over another one, leaves every argument that needs it unestablished, including
    /// the proxies discovered through it.
    #[tokio::test]
    async fn the_bridgehub_is_the_reviewed_one() {
        let timelock = record("ValidatorTimelock", BRIDGEHUB.abi_encode());
        let deployed = landing(&timelock);
        let records = at(deployed, timelock);
        let run = |env: ReviewedEnv, anchors, answers: fn(&Asserter)| {
            let records = &records;
            async move {
                hold(
                    records,
                    &env,
                    anchors,
                    member(deployed, &["ValidatorTimelock"], "ValidatorTimelock"),
                    answers,
                )
                .await
            }
        };
        let reviewed = || env(Some(BRIDGEHUB), None, &[]);
        let result = run(reviewed(), (Some(CTM), Some(BRIDGEHUB)), |asserter| {
            address(asserter, BRIDGEHUB)
        })
        .await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);

        let result = run(reviewed(), (None, Some(OTHER)), |_| {}).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error(&format!(
            "the package's bridgehub_proxy_addr {OTHER} is not env test's bridgehub_proxy_addr \
             {BRIDGEHUB}"
        )));

        let result = run(reviewed(), (Some(CTM), None), |asserter| {
            address(asserter, OTHER)
        })
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error(&format!("answers BRIDGE_HUB() {OTHER}, not env test's")));

        let result = run(ReviewedEnv::default(), (Some(CTM), Some(BRIDGEHUB)), |_| {}).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("neither --env nor --expected-bridgehub"));
    }

    /// The scenario a package-supplied Bridgehub would open: a core-only package naming its own
    /// Bridgehub X, whose `chainAssetHandler()` answers the real proxy, and an implementation
    /// built over X. Against the reviewed Bridgehub both arguments are unestablished and nothing
    /// is read through X; built over the reviewed one, the same implementation passes.
    #[tokio::test]
    async fn an_ecosystem_implementation_is_held_to_the_reviewed_bridgehub() {
        let run = |bridgehub: Address| async move {
            let root = record("L1MessageRoot", (bridgehub, HANDLER).abi_encode_params());
            let implementation = landing(&root);
            hold(
                &at(implementation, root),
                &env(Some(BRIDGEHUB), None, &[]),
                (None, Some(bridgehub)),
                member(implementation, &["L1MessageRoot"], "L1MessageRoot"),
                |asserter| {
                    if bridgehub == BRIDGEHUB {
                        address(asserter, HANDLER);
                    }
                },
            )
            .await
        };
        let result = run(BRIDGEHUB).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);
        let result = run(OTHER).await;
        assert_eq!(result.errors, 2, "{:?}", result.error_messages);
        assert!(result.has_error("L1MessageRoot._bridgehub is"));
        assert!(result.has_error("L1MessageRoot._chainAssetHandler is"));
    }

    /// The ecosystem's owner and chain cap, read through the reviewed Bridgehub's asset router
    /// and the Bridgehub itself.
    #[tokio::test]
    async fn the_ecosystem_owner_and_the_chain_cap_are_read_live() {
        const ROUTER: Address = Address::repeat_byte(0xA5);
        const OWNER: Address = Address::repeat_byte(0x60);
        let run = |owner: Address, cap: u64| async move {
            let bridgehub = record("L1Bridgehub", (owner, U256::from(cap)).abi_encode_params());
            let implementation = landing(&bridgehub);
            hold(
                &at(implementation, bridgehub),
                &env(Some(BRIDGEHUB), None, &[]),
                (None, None),
                member(implementation, &["L1Bridgehub"], "L1Bridgehub"),
                |asserter| {
                    address(asserter, ROUTER);
                    address(asserter, OWNER);
                    asserter.push_success(&Bytes::from(U256::from(100).abi_encode()));
                },
            )
            .await
        };
        assert_eq!(run(OWNER, 100).await.errors, 0);
        let result = run(OTHER, 99).await;
        assert_eq!(result.errors, 2, "{:?}", result.error_messages);
        assert!(result.has_error(&format!("the asset router {ROUTER}'s owner() is {OWNER}")));
        assert!(result.has_error("MAX_NUMBER_OF_ZK_CHAINS() is 100"));
    }

    /// The env's `l1_chain_id`, when declared, must be the RPC's.
    #[tokio::test]
    async fn the_l1_chain_id_must_be_the_envs() {
        let record = record("CommitterFacet", U256::from(CHAIN_ID).abi_encode());
        let facet = landing(&record);
        let env = ReviewedEnv {
            l1_chain_id: Some(11155111),
            ..ReviewedEnv::for_test(None, None)
        };
        let result = hold(
            &at(facet, record),
            &env,
            (None, None),
            member(facet, FACETS, "CommitterFacet"),
            chain_id,
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("the RPC's chain id 1 is not env test's l1_chain_id 11155111"));
    }

    /// A constructor parameter the expectations do not name is unverified, and so is an
    /// expectation the build's constructor does not declare, and a contract without any.
    #[tokio::test]
    async fn a_parameter_without_an_expectation_fails() {
        let extended = build().with_constructor(
            "CommitterFacet",
            &[("_l1ChainId", "uint256"), ("_extra", "uint256")],
        );
        let record = record(
            "CommitterFacet",
            (U256::from(CHAIN_ID), U256::from(7)).abi_encode_params(),
        );
        let facet = landing(&record);
        let records = at(facet, record);
        let env = ReviewedEnv::default();
        let review = MemberReview::new(&records, &env, None, None);
        let asserter = Asserter::new();
        chain_id(&asserter);
        let provider = ProviderBuilder::new().connect_mocked_client(asserter);
        let mut result = VerificationResult::default();
        expect_member_construction(
            &provider,
            &extended,
            &mut result,
            &review,
            member(facet, FACETS, "CommitterFacet"),
        )
        .await
        .unwrap();
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("CommitterFacet._extra = 7 has no reviewed expectation"));

        let narrowed = build().with_constructor("AdminFacet", &[("_l1ChainId", "uint256")]);
        let record = record_under(SALT, "AdminFacet", U256::from(CHAIN_ID).abi_encode());
        let facet = landing(&record);
        let records = at(facet, record);
        let review = MemberReview::new(&records, &env, None, None);
        let asserter = Asserter::new();
        chain_id(&asserter);
        let provider = ProviderBuilder::new().connect_mocked_client(asserter);
        let mut result = VerificationResult::default();
        expect_member_construction(
            &provider,
            &narrowed,
            &mut result,
            &review,
            member(facet, FACETS, "AdminFacet"),
        )
        .await
        .unwrap();
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("expects AdminFacet's constructor to take _rollupDAManager"));

        let unexpected = record_under(SALT, "Unexpected", Vec::new());
        let deployed = landing(&unexpected);
        let result = hold(
            &at(deployed, unexpected),
            &ReviewedEnv::default(),
            (None, None),
            member(deployed, &["Unexpected"], "Unexpected"),
            |_| {},
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("holds no expectations for Unexpected's constructor"));
    }

    /// A Mailbox's `_eip7702Checker` must run the reviewed checker, and a zero checker is no
    /// checker; the chain asset handler is the live one, the testnet flag the env's.
    #[tokio::test]
    async fn the_eip7702_checker_must_be_the_reviewed_one() {
        let run = |checker: Address, checker_code: Option<&'static [u8]>| async move {
            let mailbox = record(
                "MailboxFacet",
                (U256::from(CHAIN_ID), HANDLER, checker, true).abi_encode_params(),
            );
            let facet = landing(&mailbox);
            hold(
                &at(facet, mailbox),
                &env(Some(BRIDGEHUB), Some(true), &[]),
                (None, None),
                member(facet, FACETS, "MailboxFacet"),
                |asserter| {
                    chain_id(asserter);
                    address(asserter, HANDLER);
                    if let Some(code) = checker_code {
                        asserter.push_success(&Bytes::from_static(code));
                    }
                },
            )
            .await
        };
        let result = run(CHECKER, Some(CHECKER_RUNTIME)).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);
        let result = run(CHECKER, Some(b"a checker that admits every account")).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("is not the reviewed build of EIP7702Checker"));
        let result = run(Address::ZERO, None).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("but it must be a deployed EIP7702Checker"));
    }

    /// A verifier node's sub-verifier argument is the one the walk read through its getter.
    #[tokio::test]
    async fn a_verifier_record_must_match_the_walk() {
        const PLONK: Address = Address::repeat_byte(0x9A);
        let verifier = record("ZKsyncOSTestnetVerifier", PLONK.abi_encode());
        let deployed = landing(&verifier);
        let records = at(deployed, verifier);
        for (read, errors) in [(PLONK, 0), (OTHER, 1)] {
            let subs = [(SubVerifierGetter::Plonk, read)];
            let result = hold(
                &records,
                &ReviewedEnv::default(),
                (None, None),
                Member {
                    context: ArgContext::SubVerifiers(&subs),
                    ..member(deployed, VERIFIERS, "ZKsyncOSTestnetVerifier")
                },
                |_| {},
            )
            .await;
            assert_eq!(result.errors, errors, "{:?}", result.error_messages);
        }
    }

    /// A CTM implementation's arguments are the values the getter check established — its
    /// `_bridgehub` the reviewed Bridgehub, whatever the getter check found — and one nothing
    /// establishes is unverified.
    #[tokio::test]
    async fn a_ctm_implementation_is_held_to_the_established_immutables() {
        let args = (
            BRIDGEHUB,
            OTHER,
            Address::repeat_byte(0x5B),
            Address::repeat_byte(0x7A),
            Address::repeat_byte(0xFE),
        );
        let ctm_build = ReviewedBuild::from_artifacts(
            CodeIdentity::empty(),
            vec![(
                "ChainTypeManager",
                "ChainTypeManager",
                creation("ChainTypeManager"),
                Vec::new(),
                Vec::new(),
            )],
        )
        .with_constructor(
            "ChainTypeManager",
            &[
                ("_bridgehub", "address"),
                ("_interopCenter", "address"),
                ("_l1BytecodesSupplier", "address"),
                ("_permissionlessValidator", "address"),
                ("_l1InteropFeeManager", "address"),
            ],
        );
        let record = record("ChainTypeManager", args.abi_encode_params());
        let implementation = landing(&record);
        let records = at(implementation, record);
        let established = |validator: Option<Address>| -> CtmImmutableExpectations {
            vec![
                (CtmImmutable::BridgeHub, Some((args.0, "a".to_string()))),
                (CtmImmutable::InteropCenter, Some((args.1, "b".to_string()))),
                (
                    CtmImmutable::BytecodesSupplier,
                    Some((args.2, "c".to_string())),
                ),
                (
                    CtmImmutable::PermissionlessValidator,
                    validator.map(|v| (v, "the live CTM's own PERMISSIONLESS_VALIDATOR()".into())),
                ),
                (
                    CtmImmutable::InteropFeeManager,
                    Some((args.4, "e".to_string())),
                ),
            ]
        };
        for (bridgehub, validator, errors, needle) in [
            (Some(BRIDGEHUB), Some(args.3), 0, String::new()),
            (
                Some(BRIDGEHUB),
                Some(Address::repeat_byte(0x7B)),
                1,
                "ChainTypeManager._permissionlessValidator is".to_string(),
            ),
            (
                Some(BRIDGEHUB),
                None,
                1,
                "neither the live CTM nor the package establishes".to_string(),
            ),
            (
                Some(OTHER),
                Some(args.3),
                1,
                format!(
                    "ChainTypeManager._bridgehub is {BRIDGEHUB}, but env test's \
                     bridgehub_proxy_addr is {OTHER}"
                ),
            ),
            (
                None,
                Some(args.3),
                1,
                "neither --env nor --expected-bridgehub".to_string(),
            ),
        ] {
            let expectations = established(validator);
            let env = ReviewedEnv::for_test(None, bridgehub);
            let review = MemberReview::new(&records, &env, None, None);
            let provider = ProviderBuilder::new().connect_mocked_client(Asserter::new());
            let mut result = VerificationResult::default();
            expect_member_construction(
                &provider,
                &ctm_build,
                &mut result,
                &review,
                Member {
                    context: ArgContext::CtmImmutables(&expectations),
                    ..member(implementation, &["ChainTypeManager"], "ChainTypeManager")
                },
            )
            .await
            .unwrap();
            assert_eq!(result.errors, errors, "{:?}", result.error_messages);
            if errors > 0 {
                assert!(result.has_error(&needle), "{:?}", result.error_messages);
            }
        }
    }

    // ───────────────────────── the reviewer's inputs ─────────────────────────

    /// `--expected-bridgehub` replaces the env's Bridgehub; the env's CTMs and permanent values
    /// are read as declared.
    #[test]
    fn the_reviewed_env_takes_the_bridgehub_the_reviewer_names() {
        let stage = EnvConfig::load("stage").unwrap();
        let reviewed = ReviewedEnv::new(Some(&stage), None);
        assert_eq!(
            reviewed.bridgehub,
            Some((
                stage.bridgehub(),
                "env stage's bridgehub_proxy_addr".to_string()
            ))
        );
        assert_eq!(reviewed.testnet_verifier, stage.testnet_verifier());
        assert_eq!(reviewed.l1_chain_id, stage.l1_chain_id());
        for ctm in stage.ctms() {
            assert_eq!(reviewed.ctms.get(&ctm.proxy), Some(&ctm.rollup_da_manager));
        }
        let overridden = ReviewedEnv::new(Some(&stage), Some(OTHER));
        assert_eq!(
            overridden.bridgehub,
            Some((OTHER, "the reviewer's --expected-bridgehub".to_string()))
        );
        assert_eq!(ReviewedEnv::new(None, None).bridgehub, None);
    }

    // ───────────────────────── the tables against the sources ─────────────────────────

    const L1_CONTRACTS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../l1-contracts");

    fn read(path: &str) -> String {
        std::fs::read_to_string(format!("{L1_CONTRACTS}/{path}")).unwrap()
    }

    /// The parameter names of the first `constructor(...)` in `source`, in order.
    fn constructor_parameters(source: &str) -> Vec<String> {
        let Some((_, rest)) = source.split_once("constructor(") else {
            return Vec::new();
        };
        let (inputs, _) = rest.split_once(')').unwrap();
        inputs
            .split(',')
            .filter_map(|input| input.split_whitespace().last())
            .map(str::to_string)
            .collect()
    }

    /// Every member contract's constructor parameters, as the production sources declare them,
    /// are exactly the parameters [`CONSTRUCTOR_EXPECTATIONS`] names for it, in order — so a
    /// constructor that gains, loses or renames a parameter fails here rather than as an
    /// unverified argument in a review — and the table names no contract the build does not load.
    #[test]
    fn every_member_constructor_parameter_has_an_expectation() {
        fn walk(dir: &std::path::Path, out: &mut BTreeMap<String, std::path::PathBuf>) {
            for entry in std::fs::read_dir(dir).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    walk(&path, out);
                } else if path.extension().is_some_and(|e| e == "sol") {
                    out.insert(
                        path.file_name().unwrap().to_string_lossy().into_owned(),
                        path,
                    );
                }
            }
        }
        let mut sources = BTreeMap::new();
        walk(
            &std::path::Path::new(L1_CONTRACTS).join("contracts"),
            &mut sources,
        );
        for (file, name) in MEMBER_ARTIFACTS {
            let source = std::fs::read_to_string(&sources[*file]).unwrap();
            assert!(
                source.matches("constructor(").count() <= 1,
                "{file} declares more than one constructor"
            );
            let (_, expectations) = CONSTRUCTOR_EXPECTATIONS
                .iter()
                .find(|(contract, _)| contract == name)
                .unwrap_or_else(|| panic!("{name} has no constructor expectations"));
            let expected: Vec<&str> = expectations.iter().map(|(param, _)| *param).collect();
            assert_eq!(
                constructor_parameters(&source),
                expected,
                "{name}'s constructor parameters"
            );
        }
        for (contract, _) in CONSTRUCTOR_EXPECTATIONS {
            assert!(
                MEMBER_ARTIFACTS.iter().any(|(_, name)| name == contract),
                "{contract} has expectations but no artifact"
            );
        }
    }

    /// Every prepare path records the members it deploys and writes the record into every
    /// version of its output: both deploy helpers record, and each write of the two prepare
    /// outputs (and of the trimmed harness output) carries the table under the key the loader
    /// reads.
    #[test]
    fn the_prepares_record_every_member_deployment() {
        let utils = read("deploy-scripts/utils/deploy/DeployUtils.sol");
        for helper in [
            "deploySimpleContract",
            "deployTuppWithContractAndProxyAdmin",
        ] {
            let body = utils
                .split_once(&format!("function {helper}("))
                .unwrap()
                .1
                .split_once("\n    }\n")
                .unwrap()
                .0;
            assert!(
                body.contains("_recordMemberDeployment("),
                "{helper} does not record what it deploys"
            );
        }
        assert!(utils.contains(
            "vm.serializeString(\n            \"root\",\n            MemberDeploymentsRecord.RECORD_KEY,"
        ));
        assert!(read("deploy-scripts/utils/MemberDeploymentsRecord.sol")
            .contains("string internal constant RECORD_KEY = \"member_deployments\";"));
        for prepare in [
            "deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol",
            "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol",
        ] {
            let source = read(prepare);
            let writes = source
                .lines()
                .filter(|line| line.trim_start().starts_with("vm.writeToml("))
                .count();
            assert!(writes > 0, "{prepare} writes no output");
            assert_eq!(
                source.matches("serializeMemberDeployments();").count(),
                writes,
                "{prepare}: every write of the output carries the record"
            );
        }
        let trimmed = read("test/foundry/l1/integration/_EcosystemUpgradeForTests.sol");
        assert!(trimmed.contains(
            "_vm.serializeString(\"root\", MemberDeploymentsRecord.RECORD_KEY, _memberDeployments);"
        ));
        assert!(
            read("test/foundry/l1/integration/_EcosystemUpgradeForTests_v36.sol").contains(
                "_memberDeployments: MemberDeploymentsRecord.serialize(memberDeployments)"
            )
        );
    }
}
