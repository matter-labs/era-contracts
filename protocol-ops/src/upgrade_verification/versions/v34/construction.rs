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
//! The one thing creation code cannot choose is the address it lands at. Every registry object is
//! deployed through the deterministic CREATE2 factory, so
//!
//! ```text
//! address = keccak256(0xff ++ factory ++ salt ++ keccak256(creationCode ++ abi.encode(manifest)))[12..]
//! ```
//!
//! and a reviewer holding the reviewed creation code, the reviewed manifest and the reviewed salt
//! can recompute it. A match proves the canonical constructor ran on that manifest — which covers
//! the object's WHOLE state, not an enumerated subset of it, and therefore keeps covering it when
//! someone adds a derived field.
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

use alloy::primitives::{keccak256, Address, Bytes, B256};

use crate::upgrade_verification::constants::ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR;
use crate::upgrade_verification::paths::repo_relative_path;
use crate::upgrade_verification::verifiers::VerificationResult;

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
    /// Loads the creation code of every object type a v34 package can name, cross-checking each
    /// against `AllContractsHashes.json`.
    pub(crate) fn load(identity: &CodeIdentity) -> Self {
        const OBJECT_TYPES: &[(&str, &str)] = &[
            (
                "RegistryBootstrapMigration.sol",
                "RegistryBootstrapMigration",
            ),
            ("CTMRelease.sol", "CTMRelease"),
            ("CoreRegistry.sol", "CoreRegistry"),
            ("CTMTransition.sol", "CTMTransition"),
            ("EcosystemUpgradeOperation.sol", "EcosystemUpgradeOperation"),
        ];
        let mut loaded = HashMap::new();
        for (file, name) in OBJECT_TYPES {
            loaded.insert(*name, load_one(identity, file, name));
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

/// Reports whether the object at `address` is what the reviewed creation code produces from the
/// manifest it serves.
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
                "{label} at {address} IS the reviewed {short_name} built from the manifest it \
                 serves (CREATE2 salt {salt})"
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
                "{label} at {address} is NOT the reviewed {short_name} built from the manifest it \
                 serves: the reviewed creation code ({}) run on that manifest lands at {shown}. \
                 The object runs the right runtime code but its storage was written by something \
                 else — exactly what a counterfeit looks like. Either the salt under review is \
                 wrong, or this object was not produced by the audited constructor",
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
}
