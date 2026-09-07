//! Index over a local Foundry build, and metadata-tolerant comparison of
//! deployed runtime code against it.
//!
//! Deployed runtime code differs from `deployedBytecode.object` in two
//! legitimate ways: `immutable` values are substituted in at construction
//! time, and the trailing CBOR metadata carries an IPFS digest over the
//! compilation's metadata JSON — which moves with the build environment
//! (remappings picked up from `node_modules`, compilation unit, …) even when
//! every executable byte is identical. Both are normalised away here, and the
//! immutable values are then read back out and checked individually.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use alloy::primitives::keccak256;
use anyhow::Context;
use serde::Deserialize;

/// `a2 64 "ipfs" 58 22` — the CBOR header solc emits before the 34-byte
/// multihash of the metadata JSON.
const CBOR_IPFS_TAG: [u8; 8] = [0xa2, 0x64, 0x69, 0x70, 0x66, 0x73, 0x58, 0x22];
const CBOR_IPFS_DIGEST_LEN: usize = 34;

/// How closely deployed code matches a local artifact.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodeMatch {
    /// Byte-for-byte identical once immutables are masked, metadata included.
    Exact,
    /// Identical in every executable byte; only CBOR metadata digests differ.
    /// `digests` counts how many had to be blanked — more than one means the
    /// contract embeds a child contract's creation code (e.g. the CTM embeds
    /// `DiamondProxy`, the NTV embeds `BeaconProxy`), which carries its own
    /// metadata trailer.
    MetadataOnly { digests: usize },
}

impl CodeMatch {
    pub fn label(self) -> String {
        match self {
            Self::Exact => "exact".to_string(),
            Self::MetadataOnly { digests } => format!("metadata-only ({digests} cbor digest(s))"),
        }
    }
}

/// One `immutable` slot's value, read out of deployed runtime code.
#[derive(Debug, Clone)]
pub struct ImmutableValue {
    /// Source-declaration name when the contract has a name table, else
    /// `#<index>`. Names are positional: solc reports immutables by AST id,
    /// and ascending AST id is declaration order.
    pub name: String,
    pub raw: Vec<u8>,
    /// The use sites of this immutable do not all carry `raw`.
    pub inconsistent: bool,
    /// How many use sites were read.
    pub occurrences: usize,
}

impl ImmutableValue {
    pub fn as_address(&self) -> Option<alloy::primitives::Address> {
        (self.raw.len() == 32 && self.raw[..12].iter().all(|b| *b == 0))
            .then(|| alloy::primitives::Address::from_slice(&self.raw[12..]))
    }

    pub fn as_u256(&self) -> alloy::primitives::U256 {
        alloy::primitives::U256::from_be_slice(&self.raw)
    }

    pub fn as_b256(&self) -> alloy::primitives::FixedBytes<32> {
        let mut out = [0u8; 32];
        let n = self.raw.len().min(32);
        out[32 - n..].copy_from_slice(&self.raw[self.raw.len() - n..]);
        out.into()
    }
}

#[derive(Debug)]
pub struct Artifact {
    pub name: String,
    /// Directory the artifact came from, e.g. `L1Bridgehub.sol`.
    pub file: String,
    /// Which build tree it was found in, for reporting.
    pub source: String,
    pub deployed_code: Vec<u8>,
    /// Every `(start, length)` an immutable is spliced into. Solc repeats a
    /// slot at each use site, and all of them must be masked before two
    /// builds can be compared.
    immutable_slots: Vec<(usize, usize)>,
    /// Every occurrence of each immutable, grouped and in declaration order —
    /// one entry per source-level `immutable`, which is what the value tables
    /// label.
    immutables: Vec<Vec<(usize, usize)>>,
    /// Selectors derived from the artifact ABI, independent of `evmole`.
    pub abi_selectors: HashSet<[u8; 4]>,
}

impl Artifact {
    /// Zeroes every immutable slot so two builds of the same contract with
    /// different constructor arguments compare equal.
    fn mask_immutables(&self, code: &[u8]) -> Vec<u8> {
        let mut out = code.to_vec();
        for (start, len) in &self.immutable_slots {
            if start + len <= out.len() {
                out[*start..start + len].fill(0);
            }
        }
        out
    }

    /// Compares `deployed` against this artifact, normalising immutables and
    /// CBOR metadata. `None` when the code is a different contract.
    pub fn compare(&self, deployed: &[u8]) -> Option<CodeMatch> {
        if deployed.len() != self.deployed_code.len() {
            return None;
        }
        let masked_deployed = self.mask_immutables(deployed);
        let masked_local = self.mask_immutables(&self.deployed_code);
        if masked_deployed == masked_local {
            return Some(CodeMatch::Exact);
        }
        let offsets = cbor_digest_offsets(&masked_local);
        if offsets.is_empty() {
            return None;
        }
        (blank_at(&masked_deployed, &offsets) == blank_at(&masked_local, &offsets)).then_some(
            CodeMatch::MetadataOnly {
                digests: offsets.len(),
            },
        )
    }

    /// Reads each immutable's value out of deployed runtime code.
    ///
    /// Solc splices the same value at every use site, so a runtime whose
    /// occurrences disagree has been tampered with at one of them — masking
    /// hides that from `compare`, which is why `inconsistent` is carried out
    /// here rather than left implicit.
    pub fn immutable_values(&self, deployed: &[u8]) -> Vec<ImmutableValue> {
        let names = immutable_names(&self.name);
        self.immutables
            .iter()
            .enumerate()
            .filter_map(|(i, occurrences)| {
                let readable: Vec<Vec<u8>> = occurrences
                    .iter()
                    .filter(|(start, len)| start + len <= deployed.len())
                    .map(|(start, len)| deployed[*start..start + len].to_vec())
                    .collect();
                let first = readable.first()?.clone();
                Some(ImmutableValue {
                    name: names
                        .and_then(|n| n.get(i).copied())
                        .map(str::to_string)
                        .unwrap_or_else(|| format!("#{i}")),
                    inconsistent: readable.iter().any(|value| *value != first),
                    occurrences: readable.len(),
                    raw: first,
                })
            })
            .collect()
    }

    /// An artifact with no immutables, for tests in sibling modules.
    #[cfg(test)]
    pub fn for_test(name: &str, deployed_code: Vec<u8>) -> Self {
        Self {
            name: name.to_string(),
            file: format!("{name}.sol"),
            source: "test".to_string(),
            deployed_code,
            immutable_slots: Vec::new(),
            immutables: Vec::new(),
            abi_selectors: HashSet::new(),
        }
    }

    pub fn has_immutable_names(&self) -> bool {
        immutable_names(&self.name).is_some_and(|n| n.len() == self.immutables.len())
    }
}

/// Offsets of the CBOR metadata IPFS digests in `code`.
///
/// Only ever computed from the *local* artifact. Deriving them from the
/// deployed code as well would let a crafted runtime introduce its own
/// blanking windows by embedding the tag in executable code, and hide 34
/// bytes of difference behind each one.
fn cbor_digest_offsets(code: &[u8]) -> Vec<usize> {
    let mut offsets = Vec::new();
    let mut cursor = 0usize;
    while let Some(offset) = find_subslice(&code[cursor..], &CBOR_IPFS_TAG) {
        let digest_start = cursor + offset + CBOR_IPFS_TAG.len();
        if digest_start + CBOR_IPFS_DIGEST_LEN > code.len() {
            break;
        }
        offsets.push(digest_start);
        cursor = digest_start + CBOR_IPFS_DIGEST_LEN;
    }
    offsets
}

/// Blanks `code` at the given digest offsets.
fn blank_at(code: &[u8], offsets: &[usize]) -> Vec<u8> {
    let mut out = code.to_vec();
    for start in offsets {
        out[*start..start + CBOR_IPFS_DIGEST_LEN].fill(0);
    }
    out
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

pub struct ArtifactIndex {
    by_len: HashMap<usize, Vec<Arc<Artifact>>>,
    by_name: HashMap<String, Arc<Artifact>>,
}

impl ArtifactIndex {
    /// Loads every artifact with non-empty deployed bytecode from the given
    /// Foundry `out/` directories.
    pub fn load(out_dirs: &[(String, PathBuf)]) -> anyhow::Result<Self> {
        let mut by_len: HashMap<usize, Vec<Arc<Artifact>>> = HashMap::new();
        let mut by_name: HashMap<String, Arc<Artifact>> = HashMap::new();

        for (source, dir) in out_dirs {
            anyhow::ensure!(
                dir.is_dir(),
                "Foundry output directory {} does not exist — build the contracts first \
                 (`yarn da build:foundry && yarn l1 build:foundry`)",
                dir.display()
            );
            for artifact in read_out_dir(source, dir)? {
                let artifact = Arc::new(artifact);
                by_len
                    .entry(artifact.deployed_code.len())
                    .or_default()
                    .push(artifact.clone());
                // First writer wins: `out/` can hold same-named artifacts from
                // test doubles, and the production one sorts first by path.
                by_name
                    .entry(artifact.name.clone())
                    .or_insert_with(|| artifact.clone());
            }
        }

        anyhow::ensure!(
            !by_name.is_empty(),
            "no artifacts with deployed bytecode found; is the build up to date?"
        );
        Ok(Self { by_len, by_name })
    }

    /// Builds an index straight from artifacts, for tests that need a known
    /// local build rather than a Foundry `out/` directory.
    #[cfg(test)]
    pub fn from_artifacts(artifacts: Vec<Artifact>) -> Self {
        let mut by_len: HashMap<usize, Vec<Arc<Artifact>>> = HashMap::new();
        let mut by_name: HashMap<String, Arc<Artifact>> = HashMap::new();
        for artifact in artifacts {
            let artifact = Arc::new(artifact);
            by_len
                .entry(artifact.deployed_code.len())
                .or_default()
                .push(artifact.clone());
            by_name.insert(artifact.name.clone(), artifact);
        }
        Self { by_len, by_name }
    }

    pub fn get(&self, name: &str) -> Option<&Arc<Artifact>> {
        self.by_name.get(name)
    }

    /// Number of distinct contracts indexed, for the run header.
    pub fn contract_count(&self) -> usize {
        self.by_name.len()
    }

    /// Every artifact whose code matches `deployed`, best match kind first.
    /// More than one name is normal — a contract and its test subclass can
    /// compile to identical runtime code.
    pub fn identify(&self, deployed: &[u8]) -> Vec<(Arc<Artifact>, CodeMatch)> {
        let mut hits: Vec<_> = self
            .by_len
            .get(&deployed.len())
            .into_iter()
            .flatten()
            .filter_map(|artifact| {
                artifact
                    .compare(deployed)
                    .map(|kind| (artifact.clone(), kind))
            })
            .collect();
        hits.sort_by_key(|(artifact, kind)| {
            (!matches!(kind, CodeMatch::Exact), artifact.name.clone())
        });
        hits
    }
}

fn read_out_dir(source: &str, dir: &Path) -> anyhow::Result<Vec<Artifact>> {
    let mut out = Vec::new();
    let mut sol_dirs: Vec<PathBuf> = std::fs::read_dir(dir)
        .with_context(|| format!("reading {}", dir.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect();
    sol_dirs.sort();

    for sol_dir in sol_dirs {
        let file = sol_dir
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .to_string();
        let mut jsons: Vec<PathBuf> = std::fs::read_dir(&sol_dir)
            .with_context(|| format!("reading {}", sol_dir.display()))?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
            .collect();
        jsons.sort();
        for path in jsons {
            if let Some(artifact) = read_artifact(source, &file, &path)? {
                out.push(artifact);
            }
        }
    }
    Ok(out)
}

#[derive(Deserialize)]
struct RawArtifact {
    #[serde(default)]
    abi: Vec<AbiEntry>,
    #[serde(rename = "deployedBytecode", default)]
    deployed_bytecode: Option<RawBytecode>,
}

#[derive(Deserialize)]
struct RawBytecode {
    #[serde(default)]
    object: String,
    #[serde(rename = "immutableReferences", default)]
    immutable_references: BTreeMap<String, Vec<RawImmutableRef>>,
}

#[derive(Deserialize)]
struct RawImmutableRef {
    start: usize,
    length: usize,
}

#[derive(Deserialize)]
struct AbiEntry {
    #[serde(rename = "type", default)]
    kind: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    inputs: Vec<AbiParam>,
}

#[derive(Deserialize)]
struct AbiParam {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    components: Vec<AbiParam>,
}

impl AbiParam {
    fn canonical(&self) -> String {
        match self.kind.strip_prefix("tuple") {
            Some(suffix) => {
                let inner: Vec<String> = self.components.iter().map(AbiParam::canonical).collect();
                format!("({}){suffix}", inner.join(","))
            }
            None => self.kind.clone(),
        }
    }
}

fn read_artifact(source: &str, file: &str, path: &Path) -> anyhow::Result<Option<Artifact>> {
    let contents = std::fs::read_to_string(path)
        .with_context(|| format!("reading artifact {}", path.display()))?;
    let Ok(raw) = serde_json::from_str::<RawArtifact>(&contents) else {
        // `out/` also holds build-info and other non-artifact JSON.
        return Ok(None);
    };
    let Some(bytecode) = raw.deployed_bytecode else {
        return Ok(None);
    };
    let object = bytecode.object.trim_start_matches("0x");
    if object.is_empty() {
        return Ok(None);
    }
    // Unlinked libraries leave `__$…$__` placeholders in the hex.
    let Ok(deployed_code) = alloy::hex::decode(object) else {
        return Ok(None);
    };

    // Ascending AST id is declaration order, which is how the name tables and
    // the deploy scripts' constructor arguments are ordered.
    let mut by_declaration: Vec<(u64, Vec<(usize, usize)>)> = Vec::new();
    let mut immutable_slots: Vec<(usize, usize)> = Vec::new();
    for (ast_id, refs) in &bytecode.immutable_references {
        let ast_id = ast_id.parse::<u64>().unwrap_or(u64::MAX);
        let occurrences: Vec<(usize, usize)> = refs
            .iter()
            .map(|entry| (entry.start, entry.length))
            .collect();
        immutable_slots.extend(occurrences.iter().copied());
        if !occurrences.is_empty() {
            by_declaration.push((ast_id, occurrences));
        }
    }
    by_declaration.sort();

    let name = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_default()
        .to_string();

    let abi_selectors = raw
        .abi
        .iter()
        .filter(|entry| entry.kind == "function")
        .map(|entry| {
            let args: Vec<String> = entry.inputs.iter().map(AbiParam::canonical).collect();
            let signature = format!("{}({})", entry.name, args.join(","));
            let hash = keccak256(signature.as_bytes());
            [hash[0], hash[1], hash[2], hash[3]]
        })
        .filter(|selector| selector != &crate::common::evm_selectors::GET_NAME_SELECTOR)
        .collect();

    Ok(Some(Artifact {
        name,
        file: file.to_string(),
        source: source.to_string(),
        deployed_code,
        immutable_slots,
        immutables: by_declaration
            .into_iter()
            .map(|(_, occurrences)| occurrences)
            .collect(),
        abi_selectors,
    }))
}

/// Declaration-ordered immutable names, so the report can label the values it
/// reads back out of deployed code. Solc reports immutables by AST id only;
/// there is no name in the artifact unless the AST is emitted.
fn immutable_names(contract: &str) -> Option<&'static [&'static str]> {
    Some(match contract {
        "L1Bridgehub" => &[
            "ETH_TOKEN_ASSET_ID",
            "L1_CHAIN_ID",
            "MAX_NUMBER_OF_ZK_CHAINS",
        ],
        "L1MessageRoot" => &["BRIDGE_HUB", "CHAIN_ASSET_HANDLER", "ERA_GATEWAY_CHAIN_ID"],
        "L1ChainAssetHandler" => &["ETH_TOKEN_ASSET_ID", "L1_CHAIN_ID", "BRIDGEHUB"],
        "CTMDeploymentTracker" => &["BRIDGE_HUB", "L1_ASSET_ROUTER"],
        "ChainRegistrationSender" => &["BRIDGE_HUB"],
        "L1AssetRouter" => &[
            "BRIDGE_HUB",
            "ERA_CHAIN_ID",
            "L1_WETH_TOKEN",
            "ETH_TOKEN_ASSET_ID",
            "ERA_DIAMOND_PROXY",
            "L1_NULLIFIER",
        ],
        "L1NativeTokenVault" => &[
            "WETH_TOKEN",
            "ASSET_ROUTER",
            "BASE_TOKEN_ASSET_ID",
            "L1_CHAIN_ID",
            "L1_NULLIFIER",
        ],
        "L1Nullifier" => &["BRIDGE_HUB", "MESSAGE_ROOT"],
        "L1InteropHandler" => &["MESSAGE_ROOT", "L1_ASSET_ROUTER"],
        "ZKsyncOSChainTypeManager" | "EraChainTypeManager" => &[
            "BRIDGE_HUB",
            "INTEROP_CENTER",
            "L1_BYTECODES_SUPPLIER",
            "PERMISSIONLESS_VALIDATOR",
        ],
        "ValidatorTimelock" | "MultisigCommitter" => &["BRIDGEHUB"],
        "ZKsyncOSVerifier" | "ZKsyncOSTestnetVerifier" => &["PLONK_VERIFIER"],
        "EraDualVerifier" | "EraTestnetVerifier" => &["FFLONK_VERIFIER", "PLONK_VERIFIER"],
        "AdminFacet" => &["L1_CHAIN_ID", "ROLLUP_DA_MANAGER"],
        "MailboxFacet" => &[
            "EIP_7702_CHECKER",
            "L1_CHAIN_ID",
            "CHAIN_ASSET_HANDLER",
            "PAUSE_DEPOSITS_TIME_WINDOW_START",
        ],
        "MigratorFacet" => &[
            "L1_CHAIN_ID",
            "CHAIN_MIGRATION_TIME_WINDOW_START",
            "PAUSE_DEPOSITS_TIME_WINDOW_START",
        ],
        "CommitterFacet" => &["L1_CHAIN_ID", "COMMIT_TIMESTAMP_NOT_OLDER"],
        "DiamondInit" => &["IS_ZKSYNC_OS"],
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_two_trailers(first: u8, second: u8) -> Vec<u8> {
        let mut code = vec![0x60, 0x80];
        code.extend_from_slice(&CBOR_IPFS_TAG);
        code.extend_from_slice(&[first; CBOR_IPFS_DIGEST_LEN]);
        code.extend_from_slice(&[0x11, 0x22]);
        code.extend_from_slice(&CBOR_IPFS_TAG);
        code.extend_from_slice(&[second; CBOR_IPFS_DIGEST_LEN]);
        code
    }

    fn artifact_of(code: Vec<u8>, immutables: Vec<Vec<(usize, usize)>>) -> Artifact {
        let immutable_slots = immutables.iter().flatten().copied().collect();
        Artifact {
            name: "T".into(),
            file: "T.sol".into(),
            source: "test".into(),
            deployed_code: code,
            immutable_slots,
            immutables,
            abi_selectors: HashSet::new(),
        }
    }

    #[test]
    fn blanks_the_digests_and_nothing_else() {
        let code = with_two_trailers(0xAA, 0xBB);
        let offsets = cbor_digest_offsets(&code);
        assert_eq!(offsets, vec![10, 10 + CBOR_IPFS_DIGEST_LEN + 2 + 8]);

        let mut expected = code.clone();
        for start in &offsets {
            expected[*start..start + CBOR_IPFS_DIGEST_LEN].fill(0);
        }
        // Full-buffer equality: every byte outside the two digests survives,
        // so a mutation that zeroed more than the metadata would fail here.
        assert_eq!(blank_at(&code, &offsets), expected);
    }

    #[test]
    fn a_changed_executable_byte_is_not_metadata() {
        let artifact = artifact_of(with_two_trailers(0xAA, 0xBB), vec![]);
        let mut tampered = with_two_trailers(0xCC, 0xDD);
        assert_eq!(
            artifact.compare(&tampered),
            Some(CodeMatch::MetadataOnly { digests: 2 })
        );
        // The two bytes between the trailers are executable, not metadata.
        tampered[10 + CBOR_IPFS_DIGEST_LEN] = 0x99;
        assert_eq!(artifact.compare(&tampered), None);
    }

    #[test]
    fn a_forged_tag_cannot_open_a_new_blanking_window() {
        // Local code has one trailer; the deployed code embeds a second tag to
        // try to hide 34 bytes of difference behind it.
        let mut local = vec![0x60u8; 60];
        local.extend_from_slice(&CBOR_IPFS_TAG);
        local.extend_from_slice(&[0xAA; CBOR_IPFS_DIGEST_LEN]);
        let artifact = artifact_of(local.clone(), vec![]);

        let mut forged = local.clone();
        forged[..CBOR_IPFS_TAG.len()].copy_from_slice(&CBOR_IPFS_TAG);
        forged[CBOR_IPFS_TAG.len()..CBOR_IPFS_TAG.len() + CBOR_IPFS_DIGEST_LEN].fill(0x77);
        assert_eq!(artifact.compare(&forged), None);
    }

    #[test]
    fn masks_immutables_before_comparing() {
        let artifact = artifact_of(vec![0x60, 0x00, 0x00, 0x00, 0x5b], vec![vec![(1, 3)]]);
        assert_eq!(
            artifact.compare(&[0x60, 0xde, 0xad, 0xbe, 0x5b]),
            Some(CodeMatch::Exact)
        );
        assert_eq!(artifact.compare(&[0x61, 0xde, 0xad, 0xbe, 0x5b]), None);
        assert_eq!(artifact.compare(&[0x60, 0xde, 0xad, 0xbe]), None);
    }

    #[test]
    fn flags_an_immutable_whose_use_sites_disagree() {
        // One immutable spliced at two offsets, as solc emits for a value read
        // from two places. `compare` masks both, so only the read-back catches
        // a runtime that carries a different value at the second one.
        let artifact = artifact_of(
            vec![0x60, 0x00, 0x00, 0x5b, 0x00, 0x00, 0x5b],
            vec![vec![(1, 2), (4, 2)]],
        );

        let consistent = [0x60, 0xbe, 0xef, 0x5b, 0xbe, 0xef, 0x5b];
        assert_eq!(artifact.compare(&consistent), Some(CodeMatch::Exact));
        let values = artifact.immutable_values(&consistent);
        assert_eq!(values[0].occurrences, 2);
        assert!(!values[0].inconsistent);
        assert_eq!(values[0].raw, vec![0xbe, 0xef]);

        let tampered = [0x60, 0xbe, 0xef, 0x5b, 0xde, 0xad, 0x5b];
        assert_eq!(artifact.compare(&tampered), Some(CodeMatch::Exact));
        assert!(artifact.immutable_values(&tampered)[0].inconsistent);
    }

    #[test]
    fn canonicalises_tuple_abi_types() {
        let param = AbiParam {
            kind: "tuple[]".into(),
            components: vec![
                AbiParam {
                    kind: "address".into(),
                    components: vec![],
                },
                AbiParam {
                    kind: "uint256".into(),
                    components: vec![],
                },
            ],
        };
        assert_eq!(param.canonical(), "(address,uint256)[]");
    }
}
