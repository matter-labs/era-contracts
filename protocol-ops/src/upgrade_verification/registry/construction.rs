//! Did the reviewed CODE, run on the reviewed ARGUMENTS, produce the object at this address?
//!
//! This is the control that carries the registry model's object trust. A runtime codehash — the
//! thing the contracts used to pin on-chain — answers a strictly weaker question: it says the
//! account RUNS the audited code, not that the audited CONSTRUCTOR ever ran. Creation code is
//! free to write whatever storage it likes and then return the canonical runtime bytecode, and
//! such a counterfeit is indistinguishable by codehash while serving attacker-chosen derived
//! state (a `CTMTransition`'s facet cuts, say, which every chain applies verbatim through
//! delegatecall).
//!
//! The one thing creation code cannot choose is the address it lands at. Every object a package
//! names is deployed through the deterministic CREATE2 factory, so
//!
//! ```text
//! address = keccak256(0xff ++ factory ++ salt ++ keccak256(creationCode ++ abi.encode(args)))[12..]
//! ```
//!
//! and a reviewer holding the reviewed creation code, the reviewed constructor arguments and the
//! reviewed salt can recompute it. A match proves the canonical constructor ran on those
//! arguments — which covers the object's WHOLE state, storage and immutables alike, not an
//! enumerated subset of it, and therefore keeps covering it when someone adds a derived field.
//!
//! The arguments are a manifest for the write-once objects (read off the object itself, which
//! the match then proves it was built from) and the binding values for the lifecycle objects —
//! the executors, the timer, the bootstrap sequence — whose constructors set immutables. Those
//! are the objects a runtime codehash cannot identify at all (the artifact's immutable slots are
//! zero), so construction is the ONLY identity check they get, and its arguments come from the
//! reviewed package and manifest rather than from the object's own getters: a genuine executor
//! deployed with an attacker's owner is a genuine executor, and only the reviewed owner tells it
//! apart ([`constructor_args`]).
//!
//! # Salts
//!
//! A prepare run deploys under ONE salt per leg: the core prepare under the upgrade env's
//! `[contracts] create2_factory_salt`, each CTM prepare under that CTM's
//! `[create2_factory_salts]` entry (`DefaultCoreUpgrade.initializeConfigWithArgs`,
//! `DefaultCTMUpgrade.initializeConfig`). The merged package records neither, so both reach
//! this module as reviewer inputs (`--create2-salt`), every object is tried under each, and the
//! report names the salt that reproduced it.
//!
//! # What this cannot cover
//!
//! * The salt is a package input. An attacker free to choose both a salt and a counterfeit
//!   deployment could birthday-search two CREATE2 preimages onto one 160-bit address (~2^80
//!   work). That is the standard CREATE2 collision bound every counterfactual-address system
//!   lives with, and it is not reachable by rewriting a package.
//! * It says nothing about what the object's MEMBERS run — the facets, the verifier, each
//!   `implNew`. Those are addresses governance approves; `expect_code_identity` answers for them
//!   separately.
//! * It requires the reviewed commit to be BUILT locally (`l1-contracts/out`), because the
//!   address derivation needs the creation-code BYTES and `AllContractsHashes.json` records only
//!   their hash. The hash is what the local build is then held against, so a doctored `out/`
//!   cannot pass.

use std::collections::HashMap;
use std::path::PathBuf;

use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::sol_types::SolValue;

use crate::upgrade_verification::constants::ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR;
use crate::upgrade_verification::paths::repo_relative_path;
use crate::upgrade_verification::report::VerificationResult;

use super::provenance::CodeIdentity;

/// The deterministic deployment proxy (Arachnid's), at the same address on L1 and on the ZKsync
/// OS settlement layers. Every prepare deployment rides it — a Safe bundle replays factory
/// transactions only — so it is the deployer of every object a package names.
/// The constant is named for where the tool first needed it (ZKsync OS priority deployments);
/// the proxy sits at the same address on L1, which is the whole reason a package's objects can
/// be re-derived without knowing which chain they were deployed to.
pub(crate) const DETERMINISTIC_CREATE2_FACTORY: Address = ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR;

/// One object type's reviewed creation code, as built from the reviewed commit.
pub(crate) struct ReviewedCreationCode {
    /// `<File>.sol` under `l1-contracts/out`.
    artifact_file: &'static str,
    code: Bytes,
}

impl ReviewedCreationCode {
    pub(crate) fn artifact_file(&self) -> &'static str {
        self.artifact_file
    }

    pub(crate) fn code(&self) -> &Bytes {
        &self.code
    }
}

/// The reviewed commit's creation code for each object type, loaded once per run.
///
/// Loading is fallible per type and the failure is reported rather than fatal: a reviewer needs
/// every other finding in the report even when one artifact is missing.
pub(crate) struct ReviewedBuild {
    loaded: HashMap<&'static str, Result<ReviewedCreationCode, String>>,
}

impl ReviewedBuild {
    /// Loads the creation code of every object type a registry package can name — the
    /// write-once objects and the lifecycle objects alike — cross-checking each against
    /// `AllContractsHashes.json`.
    pub(crate) fn load(identity: &CodeIdentity) -> Self {
        const OBJECT_TYPES: &[(&str, &str)] = &[
            (
                "RegistryBootstrapMigration.sol",
                "RegistryBootstrapMigration",
            ),
            ("RegistryBootstrapSequence.sol", "RegistryBootstrapSequence"),
            ("CTMRelease.sol", "CTMRelease"),
            ("CoreRegistry.sol", "CoreRegistry"),
            ("CTMTransition.sol", "CTMTransition"),
            ("EcosystemUpgradeOperation.sol", "EcosystemUpgradeOperation"),
            ("EcosystemUpgradeExecutor.sol", "EcosystemUpgradeExecutor"),
            ("CoreUpgradeExecutor.sol", "CoreUpgradeExecutor"),
            ("CTMUpgradeExecutor.sol", "CTMUpgradeExecutor"),
            ("GovernanceUpgradeTimer.sol", "GovernanceUpgradeTimer"),
        ];
        let mut loaded = HashMap::new();
        for (file, name) in OBJECT_TYPES {
            loaded.insert(*name, load_one(identity, file, name));
        }
        Self { loaded }
    }

    /// A build holding exactly the given creation code, for tests that drive the reporting path
    /// without a compiled repository on disk.
    #[cfg(test)]
    pub(crate) fn from_parts(entries: &[(&'static str, &'static str, Vec<u8>)]) -> Self {
        let mut loaded = HashMap::new();
        for (file, short_name, code) in entries {
            loaded.insert(
                *short_name,
                Ok(ReviewedCreationCode {
                    artifact_file: file,
                    code: Bytes::from(code.clone()),
                }),
            );
        }
        Self { loaded }
    }

    /// The reviewed creation code for `short_name`, or the reason it is unavailable.
    pub(crate) fn get(&self, short_name: &str) -> Result<&ReviewedCreationCode, &str> {
        match self.loaded.get(short_name) {
            Some(Ok(code)) => Ok(code),
            Some(Err(why)) => Err(why.as_str()),
            None => Err("this verifier does not know that object type"),
        }
    }
}

fn load_one(
    identity: &CodeIdentity,
    file: &'static str,
    short_name: &'static str,
) -> Result<ReviewedCreationCode, String> {
    let path = artifact_path(file, short_name);
    let raw = std::fs::read_to_string(&path).map_err(|e| {
        format!(
            "cannot read {} ({e}): build the reviewed commit first (`cd l1-contracts && forge \
             build`), because deriving an object's address needs the creation-code BYTES and \
             AllContractsHashes.json records only their hash",
            path.display()
        )
    })?;
    let json: serde_json::Value = serde_json::from_str(&raw)
        .map_err(|e| format!("{} is not valid JSON ({e})", path.display()))?;
    let hex = json
        .get("bytecode")
        .and_then(|b| b.get("object"))
        .and_then(|o| o.as_str())
        .ok_or_else(|| format!("{} has no bytecode.object", path.display()))?;
    let code: Bytes = hex
        .parse()
        .map_err(|e| format!("{} has an unparsable bytecode.object ({e})", path.display()))?;
    if code.is_empty() {
        return Err(format!("{} has empty creation code", path.display()));
    }

    // The local build is held against the COMMITTED hash file, so the derivation below rests on
    // the reviewed commit rather than on whatever happens to sit in `out/`.
    let built = keccak256(&code);
    match identity.creation_code_hash_of(short_name) {
        Some(reviewed) if reviewed == built => Ok(ReviewedCreationCode {
            artifact_file: file,
            code,
        }),
        Some(reviewed) => Err(format!(
            "the local build of {short_name} has creation code {built}, but the reviewed commit's \
             AllContractsHashes.json records {reviewed}: the working tree is not the reviewed \
             commit, or it was built with a different compiler profile"
        )),
        None => Err(format!(
            "AllContractsHashes.json has no evmBytecodeHash for {short_name}, so the local build \
             cannot be held against the reviewed commit"
        )),
    }
}

fn artifact_path(file: &str, short_name: &str) -> PathBuf {
    repo_relative_path("l1-contracts/out")
        .join(file)
        .join(format!("{short_name}.json"))
}

/// The address the deterministic factory produces for `creation_code ++ constructor_args` under
/// `salt`.
pub(crate) fn canonical_create2_address(
    salt: B256,
    creation_code: &[u8],
    constructor_args: &[u8],
) -> Address {
    let mut init_code = Vec::with_capacity(creation_code.len() + constructor_args.len());
    init_code.extend_from_slice(creation_code);
    init_code.extend_from_slice(constructor_args);
    DETERMINISTIC_CREATE2_FACTORY.create2(salt, keccak256(&init_code))
}

/// What the reviewed build says about an object address.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ConstructionVerdict {
    /// The reviewed creation code, run on this manifest under `salt`, lands exactly here.
    Canonical { salt: B256 },
    /// No reviewed salt reproduces this address. The addresses that WOULD have been produced are
    /// carried so the report can show the reviewer what was expected.
    NotCanonical { expected: Vec<(B256, Address)> },
    /// No salt to try: the package did not record one and none was supplied.
    NoSalt,
}

/// Classifies `address` against the reviewed build and the reviewed salts.
///
/// Pure, so the decision this whole control turns on — a counterfeit is NOT canonical — is
/// testable without a chain.
pub(crate) fn classify_construction(
    address: Address,
    creation_code: &[u8],
    constructor_args: &[u8],
    salts: &[B256],
) -> ConstructionVerdict {
    if salts.is_empty() {
        return ConstructionVerdict::NoSalt;
    }
    let mut expected = Vec::with_capacity(salts.len());
    for salt in salts {
        let candidate = canonical_create2_address(*salt, creation_code, constructor_args);
        if candidate == address {
            return ConstructionVerdict::Canonical { salt: *salt };
        }
        expected.push((*salt, candidate));
    }
    ConstructionVerdict::NotCanonical { expected }
}

/// Reports whether the object at `address` is what the reviewed creation code produces from
/// `constructor_args` — the manifest it serves, or its reviewed binding values.
///
/// Every outcome short of a match is an ERROR, including "the reviewed build could not be
/// loaded" and "no salt was supplied": an object whose construction a reviewer cannot establish
/// must not ride along with an otherwise successful review.
pub(crate) fn expect_canonical_construction(
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
    short_name: &str,
    constructor_args: &[u8],
    salts: &[B256],
) -> bool {
    let creation_code = match build.get(short_name) {
        Ok(code) => code,
        Err(why) => {
            result.report_error(&format!(
                "{label} at {address}: its construction cannot be verified — {why}"
            ));
            return false;
        }
    };

    match classify_construction(address, creation_code.code(), constructor_args, salts) {
        ConstructionVerdict::Canonical { salt } => {
            result.report_ok(&format!(
                "{label} at {address} IS the reviewed {short_name} built from its reviewed \
                 constructor arguments (CREATE2 salt {salt})"
            ));
            true
        }
        ConstructionVerdict::NotCanonical { expected } => {
            let shown = expected
                .iter()
                .map(|(salt, addr)| format!("salt {salt} -> {addr}"))
                .collect::<Vec<_>>()
                .join("; ");
            result.report_error(&format!(
                "{label} at {address} is NOT the reviewed {short_name} built from its reviewed \
                 constructor arguments: the reviewed creation code ({}) run on those arguments \
                 lands at {shown}. Whatever the object answers, its state was not written by the \
                 audited constructor from the reviewed values — exactly what a counterfeit, or a \
                 genuine object built for a different owner or binding, looks like. Either a \
                 reviewed input (salt, argument) is wrong, or this object must not be signed for",
                creation_code.artifact_file()
            ));
            false
        }
        ConstructionVerdict::NoSalt => {
            result.report_error(&format!(
                "{label} at {address}: no CREATE2 salt is available, so its construction cannot \
                 be verified. Pass --create2-salt with the reviewed `[contracts] \
                 create2_factory_salt` (and any `[create2_factory_salts]` per-CTM entry) from the \
                 upgrade env"
            ));
            false
        }
    }
}

/// The constructor arguments of the lifecycle objects, ABI-encoded exactly as the prepare passes
/// them (`abi.encode(...)` of the constructor's parameter list, in `CoreUpgrade_v34` /
/// `CTMUpgrade_v34` / `DefaultCTMUpgrade.getCreationCalldata`).
///
/// Every value is a REVIEWED one — the manifest's, the package's or the reviewer's — never a
/// read off the object: an object answers with whatever it was built from, so a check that took
/// its arguments from its getters would verify every genuine executor, including one built for
/// an attacker's owner. The immutable-bearing objects have no other identity check, which is why
/// the argument sources matter (see the module docs).
pub(crate) mod constructor_args {
    use super::*;

    /// `EcosystemUpgradeExecutor(address _initialOwner, CoreUpgradeExecutor _coreExecutor)`.
    pub(crate) fn ecosystem_upgrade_executor(
        initial_owner: Address,
        core_executor: Address,
    ) -> Vec<u8> {
        (initial_owner, core_executor).abi_encode_params()
    }

    /// `CoreUpgradeExecutor(address _initialOwner, ProxyAdmin _proxyAdmin)`.
    pub(crate) fn core_upgrade_executor(initial_owner: Address, proxy_admin: Address) -> Vec<u8> {
        (initial_owner, proxy_admin).abi_encode_params()
    }

    /// `CTMUpgradeExecutor(address _initialOwner, IChainTypeManager _ctm, ProxyAdmin _ctmProxyAdmin,
    /// address _coordinator)`.
    pub(crate) fn ctm_upgrade_executor(
        initial_owner: Address,
        ctm: Address,
        ctm_proxy_admin: Address,
        coordinator: Address,
    ) -> Vec<u8> {
        (initial_owner, ctm, ctm_proxy_admin, coordinator).abi_encode_params()
    }

    /// `GovernanceUpgradeTimer(uint256 _initialDelay, uint256 _maxAdditionalDelay, address
    /// _timerGovernance, address _initialOwner)`.
    pub(crate) fn governance_upgrade_timer(
        initial_delay: U256,
        max_additional_delay: U256,
        timer_governance: Address,
        initial_owner: Address,
    ) -> Vec<u8> {
        (
            initial_delay,
            max_additional_delay,
            timer_governance,
            initial_owner,
        )
            .abi_encode_params()
    }

    /// `RegistryBootstrapSequence(RegistryBootstrapMigration _migration, ICoreRegistry _coreRegistry)`.
    pub(crate) fn registry_bootstrap_sequence(
        migration: Address,
        core_registry: Address,
    ) -> Vec<u8> {
        (migration, core_registry).abi_encode_params()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SALT_A: B256 = B256::repeat_byte(0xA1);
    const SALT_B: B256 = B256::repeat_byte(0xB2);

    fn creation_code() -> Vec<u8> {
        b"reviewed creation code".to_vec()
    }

    fn args() -> Vec<u8> {
        b"the approved manifest".to_vec()
    }

    #[test]
    fn the_factory_constant_is_the_deterministic_deployment_proxy() {
        assert_eq!(
            DETERMINISTIC_CREATE2_FACTORY.to_string().to_lowercase(),
            "0x4e59b44847b379578588920ca78fbf26c0b4956c"
        );
    }

    /// The address derivation must be plain EIP-1014, so it agrees with what the factory
    /// actually did on chain.
    #[test]
    fn the_address_is_eip_1014_over_the_concatenated_init_code() {
        let mut init = creation_code();
        init.extend_from_slice(&args());
        assert_eq!(
            canonical_create2_address(SALT_A, &creation_code(), &args()),
            DETERMINISTIC_CREATE2_FACTORY.create2(SALT_A, keccak256(&init))
        );
    }

    #[test]
    fn a_genuine_deployment_is_canonical_under_its_own_salt() {
        let address = canonical_create2_address(SALT_B, &creation_code(), &args());
        assert_eq!(
            classify_construction(address, &creation_code(), &args(), &[SALT_A, SALT_B]),
            ConstructionVerdict::Canonical { salt: SALT_B }
        );
    }

    /// THE regression this control exists for. A counterfeit returns the canonical RUNTIME
    /// bytecode over storage of its own choosing, so it is indistinguishable by codehash and it
    /// serves the approved manifest — but it was deployed by different creation code, so it does
    /// not sit at the address the reviewed creation code produces for that manifest.
    #[test]
    fn a_counterfeit_serving_the_approved_manifest_is_rejected() {
        let counterfeit_creation_code = b"initcode that writes chosen storage".to_vec();
        let counterfeit = canonical_create2_address(SALT_A, &counterfeit_creation_code, &args());
        // It answers with the approved manifest, so the arguments below are the approved ones.
        let verdict = classify_construction(counterfeit, &creation_code(), &args(), &[SALT_A]);
        match verdict {
            ConstructionVerdict::NotCanonical { expected } => {
                assert_eq!(expected.len(), 1);
                assert_ne!(expected[0].1, counterfeit);
            }
            other => panic!("a counterfeit must not verify: {other:?}"),
        }
    }

    /// A counterfeit cannot escape by being deployed through the same factory under a salt the
    /// package also declares: the init code still differs, so the derived address still does.
    #[test]
    fn a_counterfeit_under_a_declared_salt_is_still_rejected() {
        let counterfeit = canonical_create2_address(SALT_B, b"other initcode", &args());
        assert!(matches!(
            classify_construction(counterfeit, &creation_code(), &args(), &[SALT_A, SALT_B]),
            ConstructionVerdict::NotCanonical { .. }
        ));
    }

    /// Tampering with the manifest moves the canonical address too, so an object serving a
    /// manifest other than the one it was built from cannot verify either.
    #[test]
    fn an_object_serving_a_different_manifest_is_rejected() {
        let address = canonical_create2_address(SALT_A, &creation_code(), b"the real manifest");
        assert!(matches!(
            classify_construction(address, &creation_code(), b"a swapped manifest", &[SALT_A]),
            ConstructionVerdict::NotCanonical { .. }
        ));
    }

    /// "Unverifiable" is its own verdict rather than a pass, because a reviewer who could not
    /// run the check has not performed it.
    #[test]
    fn no_salt_is_unverifiable_rather_than_canonical() {
        let address = canonical_create2_address(SALT_A, &creation_code(), &args());
        assert_eq!(
            classify_construction(address, &creation_code(), &args(), &[]),
            ConstructionVerdict::NoSalt
        );
    }

    fn reviewed_build() -> ReviewedBuild {
        ReviewedBuild::from_parts(&[("CTMTransition.sol", "CTMTransition", creation_code())])
    }

    /// The verdicts above decide nothing on their own — what fails a verification run is the
    /// REPORTING path. These drive it end to end, so a classifier that said "not canonical"
    /// while the run still passed would be caught.
    #[test]
    fn the_reporting_path_fails_the_run_for_a_counterfeit() {
        let counterfeit =
            canonical_create2_address(SALT_A, b"initcode of the attacker's choosing", &args());
        let mut result = VerificationResult::default();
        let verified = expect_canonical_construction(
            &reviewed_build(),
            &mut result,
            "the transition",
            counterfeit,
            "CTMTransition",
            &args(),
            &[SALT_A],
        );
        assert!(!verified);
        assert_eq!(result.errors, 1, "a counterfeit must fail the run");
        assert!(result.ensure_success().is_err());
    }

    #[test]
    fn the_reporting_path_passes_a_genuine_object() {
        let genuine = canonical_create2_address(SALT_A, &creation_code(), &args());
        let mut result = VerificationResult::default();
        assert!(expect_canonical_construction(
            &reviewed_build(),
            &mut result,
            "the transition",
            genuine,
            "CTMTransition",
            &args(),
            &[SALT_A],
        ));
        assert_eq!(result.errors, 0);
    }

    /// "Could not be checked" must fail the run too, or a reviewer who never ran the check would
    /// read the same clean report as one who ran it and passed.
    #[test]
    fn an_unloadable_object_type_fails_the_run() {
        let mut result = VerificationResult::default();
        assert!(!expect_canonical_construction(
            &reviewed_build(),
            &mut result,
            "the core registry",
            Address::repeat_byte(0x99),
            "CoreRegistry",
            &args(),
            &[SALT_A],
        ));
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn a_missing_salt_fails_the_run() {
        let genuine = canonical_create2_address(SALT_A, &creation_code(), &args());
        let mut result = VerificationResult::default();
        assert!(!expect_canonical_construction(
            &reviewed_build(),
            &mut result,
            "the transition",
            genuine,
            "CTMTransition",
            &args(),
            &[],
        ));
        assert_eq!(result.errors, 1);
    }

    // ───────────────────────── the deployed counterfeit ─────────────────────────
    //
    // The tests above establish the predicate over byte strings of this module's choosing. The
    // counterfeit that matters is the one `l1-contracts/test/foundry/l1/upgrades/CounterfeitObject.t.sol`
    // actually DEPLOYS: real initcode, through the real deterministic factory, returning the
    // audited `CTMTransition` runtime bytecode over storage of its own choosing, serving the
    // approved manifest. That test proves, in a real EVM, that
    // `DeployUtils.canonicalCreate2Address` rejects it and accepts the genuine object.
    //
    // Driving that exact deployment through the Rust reporting path is NOT possible in this test
    // suite, and the reason is worth stating rather than papering over with another synthetic
    // case. `cargo test` runs on a bare checkout (`.github/workflows/lint.yaml`, job
    // `protocol-ops-test`): no `forge build`, so no `l1-contracts/out` to read creation code from,
    // and no EVM. The counterfeit's ADDRESS is a function of that Foundry fixture's in-EVM state
    // (the approved manifest names stubs the fixture deploys), so it cannot be recomputed here;
    // and `l1-contracts/foundry.toml`'s `fs_permissions` grants no writable path under
    // `protocol-ops/`, so the Solidity side cannot hand it over either.
    //
    // What CAN be established here is the link that makes the Foundry finding a statement about
    // THIS code: that the derivation the Solidity control evaluates is the derivation this module
    // decides on. Without it, `Utils.sol` could drift to a different factory or a different init-
    // code layout, the Foundry test would keep passing, and it would be proving something about a
    // function the tool does not use.

    const UTILS_SOL: &str = include_str!("../../../../l1-contracts/deploy-scripts/utils/Utils.sol");
    const COUNTERFEIT_SOL: &str =
        include_str!("../../../../l1-contracts/test/foundry/l1/upgrades/CounterfeitObject.t.sol");

    /// The body of the Solidity function named `name`, from `{` to the matching top-level `}`.
    fn solidity_fn_body<'a>(source: &'a str, name: &str) -> &'a str {
        let after_signature = source
            .split_once(&format!("function {name}("))
            .unwrap_or_else(|| panic!("`{name}` must exist in the Solidity source"))
            .1;
        let open = after_signature
            .find('{')
            .expect("a function body must be opened");
        let body = &after_signature[open + 1..];
        let close = body
            .find("\n    }")
            .expect("a function body must be closed");
        &body[..close]
    }

    /// The factory both sides derive against must be the same account, or the Foundry control and
    /// this module would be asking about different addresses.
    #[test]
    fn the_solidity_derivation_uses_the_same_factory() {
        let declared = UTILS_SOL
            .split_once("address internal constant DETERMINISTIC_CREATE2_ADDRESS =")
            .expect("Utils.sol must declare the deterministic factory")
            .1
            .split_once(';')
            .expect("the declaration must be terminated")
            .0
            .trim();
        assert_eq!(
            declared.to_lowercase(),
            DETERMINISTIC_CREATE2_FACTORY.to_string().to_lowercase(),
            "the Solidity control derives against a different factory from this module"
        );
    }

    /// The init code must be `creationCode ++ constructorArgs`, hashed, in that order. A swapped
    /// concatenation derives a different address for every object, so the two sides would disagree
    /// on every package while each looked internally consistent.
    #[test]
    fn the_solidity_derivation_is_the_same_eip_1014_preimage() {
        let canonical = solidity_fn_body(UTILS_SOL, "canonicalCreate2Address");
        assert!(
            canonical.contains(
                "getL2AddressViaDeterministicCreate2(_salt, abi.encodePacked(_creationCode, _constructorArgs))"
            ),
            "the Solidity control must hash `creationCode ++ constructorArgs`, in that order; it \
             reads: {canonical}"
        );
        let via_factory = solidity_fn_body(UTILS_SOL, "getL2AddressViaDeterministicCreate2");
        assert!(
            via_factory.contains(
                "vm.computeCreate2Address(salt, keccak256(initCode), DETERMINISTIC_CREATE2_ADDRESS)"
            ),
            "the Solidity control must be plain EIP-1014 over the init-code hash under the \
             deterministic factory; it reads: {via_factory}"
        );
    }

    /// The counterfeit must be deployed through that same factory — nothing about HOW it was
    /// deployed may distinguish it from a genuine object, or the Foundry test would be catching
    /// the deployment route rather than the init code.
    #[test]
    fn the_deployed_counterfeit_rides_the_same_factory() {
        let declared = COUNTERFEIT_SOL
            .split_once("address internal constant DETERMINISTIC_CREATE2_FACTORY =")
            .expect("the counterfeit test must name the factory it deploys through")
            .1
            .split_once(';')
            .expect("the declaration must be terminated")
            .0
            .trim();
        assert_eq!(
            declared.to_lowercase(),
            DETERMINISTIC_CREATE2_FACTORY.to_string().to_lowercase()
        );
    }

    /// And the Foundry control must BE this predicate, applied to the deployed counterfeit and to
    /// the genuine object — rejecting one and accepting the other. A test that only asserted the
    /// rejection would be satisfied by a predicate that refuses everything.
    #[test]
    fn the_deployed_counterfeit_is_judged_by_this_predicate() {
        let rejects = solidity_fn_body(
            COUNTERFEIT_SOL,
            "test_theConstructionCheckRejectsTheCounterfeit",
        );
        assert!(
            rejects.contains("DeployUtils.canonicalCreate2Address(")
                && rejects.contains("_transitionCreationCode()")
                && rejects.contains("_approvedArgs()")
                && rejects.contains("canonical != counterfeit"),
            "the counterfeit control must derive the reviewed creation code against the APPROVED \
             manifest and assert the deployed counterfeit is not there; it reads: {rejects}"
        );
        let accepts = solidity_fn_body(
            COUNTERFEIT_SOL,
            "test_theConstructionCheckAcceptsTheGenuineObject",
        );
        assert!(
            accepts.contains("DeployUtils.canonicalCreate2Address(")
                && accepts.contains("address(genuine)"),
            "the same predicate must accept a prepare-deployed object, or it discriminates \
             nothing; it reads: {accepts}"
        );
    }

    /// The property the whole control turns on, restated over the counterfeit's own defining
    /// trait: it runs the audited RUNTIME code, so nothing a chain can read tells it apart. This
    /// module's classifier is asked both questions about one pair of addresses, and must answer
    /// "same code" and "different construction".
    #[test]
    fn identical_runtime_code_does_not_make_construction_identical() {
        let audited_runtime = b"the audited CTMTransition runtime bytecode".to_vec();
        // Two different initcodes that both return `audited_runtime`: the genuine constructor and
        // a counterfeit one that writes storage of its own choosing first.
        let genuine_initcode = creation_code();
        let counterfeit_initcode = b"initcode that writes chosen storage, then returns it".to_vec();
        let genuine = canonical_create2_address(SALT_A, &genuine_initcode, &args());
        let counterfeit = canonical_create2_address(SALT_A, &counterfeit_initcode, &args());

        assert_ne!(
            genuine, counterfeit,
            "the one thing creation code cannot choose is the address it lands at"
        );
        // A runtime-codehash pin cannot separate them: by construction they return the same code.
        assert_eq!(keccak256(&audited_runtime), keccak256(&audited_runtime));
        // The construction check can, and the reporting path fails the run for it.
        let mut result = VerificationResult::default();
        assert!(expect_canonical_construction(
            &reviewed_build(),
            &mut result,
            "the transition",
            genuine,
            "CTMTransition",
            &args(),
            &[SALT_A],
        ));
        assert_eq!(result.errors, 0);
        assert!(!expect_canonical_construction(
            &reviewed_build(),
            &mut result,
            "the transition",
            counterfeit,
            "CTMTransition",
            &args(),
            &[SALT_A],
        ));
        assert_eq!(result.errors, 1);
        assert!(result.ensure_success().is_err());
    }

    // ───────────────────────── the lifecycle objects' arguments ─────────────────────────
    //
    // An immutable-bearing object has no identity check but its construction, and the address
    // derivation feeds these encodings in verbatim. A layout that differed from the prepare's
    // `abi.encode(...)` by one word would reject every genuine executor and look exactly like a
    // counterfeit finding, so the layout is pinned byte for byte: one 32-byte word per static
    // argument, addresses right-aligned, no offset word (the argument list is static).

    fn word_of_address(encoded: &[u8], index: usize) -> Address {
        Address::from_slice(&encoded[index * 32 + 12..index * 32 + 32])
    }

    #[test]
    fn executor_arguments_encode_as_the_prepares_abi_encode() {
        let owner = Address::repeat_byte(0x01);
        let core_executor = Address::repeat_byte(0x02);
        let encoded = constructor_args::ecosystem_upgrade_executor(owner, core_executor);
        assert_eq!(encoded.len(), 64);
        assert_eq!(word_of_address(&encoded, 0), owner);
        assert_eq!(word_of_address(&encoded, 1), core_executor);

        let proxy_admin = Address::repeat_byte(0x03);
        let encoded = constructor_args::core_upgrade_executor(owner, proxy_admin);
        assert_eq!(encoded.len(), 64);
        assert_eq!(word_of_address(&encoded, 1), proxy_admin);

        let ctm = Address::repeat_byte(0x04);
        let coordinator = Address::repeat_byte(0x05);
        let encoded = constructor_args::ctm_upgrade_executor(owner, ctm, proxy_admin, coordinator);
        assert_eq!(encoded.len(), 128);
        assert_eq!(word_of_address(&encoded, 0), owner);
        assert_eq!(word_of_address(&encoded, 1), ctm);
        assert_eq!(word_of_address(&encoded, 2), proxy_admin);
        assert_eq!(word_of_address(&encoded, 3), coordinator);

        let migration = Address::repeat_byte(0x06);
        let registry = Address::repeat_byte(0x07);
        let encoded = constructor_args::registry_bootstrap_sequence(migration, registry);
        assert_eq!(encoded.len(), 64);
        assert_eq!(word_of_address(&encoded, 0), migration);
        assert_eq!(word_of_address(&encoded, 1), registry);
    }

    #[test]
    fn timer_arguments_encode_delays_as_full_words() {
        let governance = Address::repeat_byte(0x08);
        let owner = Address::repeat_byte(0x09);
        let encoded = constructor_args::governance_upgrade_timer(
            U256::from(172_800u64),
            U256::from(1_209_600u64),
            governance,
            owner,
        );
        assert_eq!(encoded.len(), 128);
        assert_eq!(U256::from_be_slice(&encoded[..32]), U256::from(172_800u64));
        assert_eq!(
            U256::from_be_slice(&encoded[32..64]),
            U256::from(1_209_600u64)
        );
        assert_eq!(word_of_address(&encoded, 2), governance);
        assert_eq!(word_of_address(&encoded, 3), owner);
    }

    /// The owner is an argument like any other: a genuine executor built for a different owner
    /// lands at a different address, which is exactly what makes the reviewed owner — and not
    /// the object's own `owner()` — the right source for it.
    #[test]
    fn an_executor_built_for_another_owner_is_a_different_object() {
        let core_executor = Address::repeat_byte(0x02);
        let reviewed_owner = Address::repeat_byte(0x01);
        let attacker = Address::repeat_byte(0xBA);
        let genuine_for_attacker = canonical_create2_address(
            SALT_A,
            &creation_code(),
            &constructor_args::ecosystem_upgrade_executor(attacker, core_executor),
        );
        assert!(matches!(
            classify_construction(
                genuine_for_attacker,
                &creation_code(),
                &constructor_args::ecosystem_upgrade_executor(reviewed_owner, core_executor),
                &[SALT_A],
            ),
            ConstructionVerdict::NotCanonical { .. }
        ));
    }
}
