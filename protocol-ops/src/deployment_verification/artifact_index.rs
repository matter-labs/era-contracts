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
    /// First occurrence of each immutable, in declaration order — one entry
    /// per source-level `immutable`, which is what the value tables label.
    immutables: Vec<(usize, usize)>,
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
        let (blanked_deployed, digests) = blank_cbor_digests(&masked_deployed);
        let (blanked_local, _) = blank_cbor_digests(&masked_local);
        (blanked_deployed == blanked_local && digests > 0)
            .then_some(CodeMatch::MetadataOnly { digests })
    }

    /// Reads each immutable's value out of deployed runtime code.
    pub fn immutable_values(&self, deployed: &[u8]) -> Vec<ImmutableValue> {
        let names = immutable_names(&self.name);
        self.immutables
            .iter()
            .enumerate()
            .filter(|(_, (start, len))| start + len <= deployed.len())
            .map(|(i, (start, len))| ImmutableValue {
                name: names
                    .and_then(|n| n.get(i).copied())
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("#{i}")),
                raw: deployed[*start..start + len].to_vec(),
            })
            .collect()
    }

    pub fn has_immutable_names(&self) -> bool {
        immutable_names(&self.name).is_some_and(|n| n.len() == self.immutables.len())
    }
}

/// Blanks every CBOR metadata IPFS digest in `code`, returning the normalised
/// bytes and how many were blanked.
fn blank_cbor_digests(code: &[u8]) -> (Vec<u8>, usize) {
    let mut out = code.to_vec();
    let mut found = 0usize;
    let mut cursor = 0usize;
    while let Some(offset) = find_subslice(&out[cursor..], &CBOR_IPFS_TAG) {
        let digest_start = cursor + offset + CBOR_IPFS_TAG.len();
        let digest_end = digest_start + CBOR_IPFS_DIGEST_LEN;
        if digest_end > out.len() {
            break;
        }
        out[digest_start..digest_end].fill(0);
        found += 1;
        cursor = digest_end;
    }
    (out, found)
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
    let mut by_declaration: Vec<(u64, usize, usize)> = Vec::new();
    let mut immutable_slots: Vec<(usize, usize)> = Vec::new();
    for (ast_id, refs) in &bytecode.immutable_references {
        let ast_id = ast_id.parse::<u64>().unwrap_or(u64::MAX);
        immutable_slots.extend(refs.iter().map(|entry| (entry.start, entry.length)));
        // The same value is spliced at every use site, so the first is
        // enough to read it back.
        if let Some(first) = refs.first() {
            by_declaration.push((ast_id, first.start, first.length));
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
            .map(|(_, start, len)| (start, len))
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

    #[test]
    fn blanks_every_cbor_digest() {
        let mut code = vec![0x60, 0x80];
        code.extend_from_slice(&CBOR_IPFS_TAG);
        code.extend_from_slice(&[0xAA; CBOR_IPFS_DIGEST_LEN]);
        code.extend_from_slice(&[0x11, 0x22]);
        code.extend_from_slice(&CBOR_IPFS_TAG);
        code.extend_from_slice(&[0xBB; CBOR_IPFS_DIGEST_LEN]);

        let (blanked, count) = blank_cbor_digests(&code);
        assert_eq!(count, 2);
        assert!(blanked[10..10 + CBOR_IPFS_DIGEST_LEN]
            .iter()
            .all(|b| *b == 0));
        assert!(blanked.ends_with(&[0u8; CBOR_IPFS_DIGEST_LEN]));
    }

    #[test]
    fn masks_immutables_before_comparing() {
        let artifact = Artifact {
            name: "T".into(),
            file: "T.sol".into(),
            source: "test".into(),
            deployed_code: vec![0x60, 0x00, 0x00, 0x00, 0x5b],
            immutable_slots: vec![(1, 3)],
            immutables: vec![(1, 3)],
            abi_selectors: HashSet::new(),
        };
        assert_eq!(
            artifact.compare(&[0x60, 0xde, 0xad, 0xbe, 0x5b]),
            Some(CodeMatch::Exact)
        );
        assert_eq!(artifact.compare(&[0x61, 0xde, 0xad, 0xbe, 0x5b]), None);
        assert_eq!(artifact.compare(&[0x60, 0xde, 0xad, 0xbe]), None);
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
