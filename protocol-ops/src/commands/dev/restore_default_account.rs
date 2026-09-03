//! Restore the reviewed v31 `DefaultAccount` artifact after a `system-contracts` build.
//!
//! The EraVM build is not bit-reproducible: a fresh build can differ from the reviewed
//! bytecode in its trailing 32-byte metadata word only, which still changes the bytecode
//! hash and trips the CTM upgrade's `default aa hash factory dep mismatch` check. When the
//! executable prefix is byte-identical to the reviewed one, this swaps the metadata word
//! back so the artifact hashes to the pinned `default_aa_hash`. Anything else is an error.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use sha2::{Digest, Sha256};

use crate::common::files::read_json_file;
use crate::common::logger;

/// The reviewed v31 DefaultAccount: its hash, and the executable prefix + metadata word a
/// canonical build emits.
const CANONICAL_DEFAULT_ACCOUNT_HASH: &str =
    "0x010005f9d84c1863bf21a9393f2fd1631af92aab68f12c35dba580c8d7a06146";
const CANONICAL_DEFAULT_ACCOUNT_EXECUTABLE_SHA256: &str =
    "28c736311a2f872a0b8ff289b0ae35266f1ccd402885435fd9ffd2a154a39a96";
const CANONICAL_DEFAULT_ACCOUNT_METADATA_WORD: &str =
    "3ad06056e66b778b11945dd3cf11269b479679b45850c25af96c8ca9f309acb0";
const METADATA_WORD_BYTES: usize = 32;
// EraVM bytecode hash: sha256 with byte 0 = version, byte 1 = 0, bytes 2-3 = length in 32-byte words.
const ERAVM_WORD_BYTES: usize = 32;
const ERAVM_HASH_VERSION: u8 = 1;
const MAX_ERAVM_BYTECODE_WORDS: usize = 0xffff;
const DEFAULT_ACCOUNT_CONTRACT_NAME: &str = "system-contracts/DefaultAccount";

#[derive(Debug, Clone, Parser)]
pub struct RestoreDefaultAccountArgs {
    /// The built foundry artifact, e.g. `system-contracts/zkout/DefaultAccount.sol/DefaultAccount.json`.
    pub artifact: PathBuf,
    /// The env's v31 input TOML, whose `[contracts] default_aa_hash` pins the reviewed hash.
    pub environment: PathBuf,
    /// `AllContractsHashes.json`, which must agree with the pinned hash.
    pub hashes: PathBuf,
}

/// The EraVM bytecode hash of `bytecode` (see `system-contracts/Constants.sol`).
pub fn zk_bytecode_hash(bytecode: &[u8]) -> anyhow::Result<String> {
    anyhow::ensure!(
        bytecode.len().is_multiple_of(ERAVM_WORD_BYTES),
        "bytecode length {} is not word-aligned",
        bytecode.len()
    );
    let words = bytecode.len() / ERAVM_WORD_BYTES;
    anyhow::ensure!(
        words % 2 == 1 && words <= MAX_ERAVM_BYTECODE_WORDS,
        "invalid EraVM bytecode word length {words}"
    );
    let mut digest: [u8; 32] = Sha256::digest(bytecode).into();
    digest[0] = ERAVM_HASH_VERSION;
    digest[1] = 0;
    digest[2..4].copy_from_slice(&(words as u16).to_be_bytes());
    Ok(format!("0x{}", hex::encode(digest)))
}

pub fn restore_canonical_default_account(
    artifact_path: &Path,
    environment_path: &Path,
    hashes_path: &Path,
) -> anyhow::Result<()> {
    let environment: toml::Value = crate::common::files::read_toml_file(environment_path)?;
    let pinned = environment
        .get("contracts")
        .and_then(|contracts| contracts.get("default_aa_hash"))
        .and_then(toml::Value::as_str)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "{} has no [contracts] default_aa_hash",
                environment_path.display()
            )
        })?
        .to_lowercase();

    let hashes: Vec<serde_json::Value> = read_json_file(hashes_path)?;
    let reviewed: Vec<String> = hashes
        .iter()
        .filter(|entry| {
            entry
                .get("contractName")
                .and_then(serde_json::Value::as_str)
                == Some(DEFAULT_ACCOUNT_CONTRACT_NAME)
        })
        .filter_map(|entry| {
            entry
                .get("zkBytecodeHash")
                .and_then(serde_json::Value::as_str)
        })
        .map(str::to_lowercase)
        .collect();
    anyhow::ensure!(
        reviewed == [pinned.clone()],
        "pinned default_aa_hash {pinned} does not uniquely match AllContractsHashes.json: {reviewed:?}"
    );

    let mut artifact: serde_json::Value = read_json_file(artifact_path)?;
    let raw = artifact
        .pointer("/bytecode/object")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("{} has no bytecode.object", artifact_path.display()))?;
    let has_prefix = raw.starts_with("0x");
    let bytecode =
        hex::decode(raw.trim_start_matches("0x")).context("bytecode.object is not hex")?;
    let built = zk_bytecode_hash(&bytecode)?;
    if built == pinned {
        logger::info(format!(
            "DefaultAccount artifact already canonical: {built}"
        ));
        return Ok(());
    }
    anyhow::ensure!(
        pinned == CANONICAL_DEFAULT_ACCOUNT_HASH,
        "no canonical artifact registered for pinned hash {pinned} (build produced {built})"
    );
    anyhow::ensure!(
        bytecode.len() > METADATA_WORD_BYTES,
        "bytecode is too short to contain the metadata word"
    );
    let (executable, _metadata_word) = bytecode.split_at(bytecode.len() - METADATA_WORD_BYTES);
    let executable_sha256 = hex::encode(Sha256::digest(executable));
    anyhow::ensure!(
        executable_sha256 == CANONICAL_DEFAULT_ACCOUNT_EXECUTABLE_SHA256,
        "executable prefix changed: expected {CANONICAL_DEFAULT_ACCOUNT_EXECUTABLE_SHA256}, got {executable_sha256}"
    );
    let canonical = [
        executable,
        &hex::decode(CANONICAL_DEFAULT_ACCOUNT_METADATA_WORD)?,
    ]
    .concat();
    let restored = zk_bytecode_hash(&canonical)?;
    anyhow::ensure!(
        restored == pinned,
        "restored hash {restored} does not match pinned hash {pinned}"
    );

    let object = format!(
        "{}{}",
        if has_prefix { "0x" } else { "" },
        hex::encode(&canonical)
    );
    *artifact
        .pointer_mut("/bytecode/object")
        .expect("bytecode.object was read above") = serde_json::Value::String(object);
    let temporary = artifact_path.with_extension("json.tmp");
    fs::write(&temporary, serde_json::to_string(&artifact)? + "\n")?;
    fs::rename(&temporary, artifact_path).context("replace the artifact")?;
    logger::success(format!(
        "Restored canonical DefaultAccount artifact: {built} -> {restored}"
    ));
    Ok(())
}

pub fn run(args: RestoreDefaultAccountArgs) -> anyhow::Result<()> {
    restore_canonical_default_account(&args.artifact, &args.environment, &args.hashes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaves_an_artifact_unchanged_when_it_already_has_the_pinned_hash() {
        let dir = tempfile::tempdir().unwrap();
        let bytecode = vec![7u8; 32];
        let hash = zk_bytecode_hash(&bytecode).unwrap();
        let artifact = dir.path().join("DefaultAccount.json");
        let environment = dir.path().join("environment.toml");
        let hashes = dir.path().join("AllContractsHashes.json");
        let artifact_json = format!(
            r#"{{"bytecode":{{"object":"0x{}"}}}}"#,
            hex::encode(&bytecode)
        );
        fs::write(&artifact, &artifact_json).unwrap();
        fs::write(
            &environment,
            format!("[contracts]\ndefault_aa_hash = \"{hash}\"\n"),
        )
        .unwrap();
        fs::write(
            &hashes,
            format!(r#"[{{"contractName":"{DEFAULT_ACCOUNT_CONTRACT_NAME}","zkBytecodeHash":"{hash}"}}]"#),
        )
        .unwrap();
        restore_canonical_default_account(&artifact, &environment, &hashes).unwrap();
        assert_eq!(fs::read_to_string(&artifact).unwrap(), artifact_json);
    }

    #[test]
    fn rejects_an_even_word_bytecode_length() {
        let error = zk_bytecode_hash(&[0u8; 64]).unwrap_err().to_string();
        assert!(
            error.contains("invalid EraVM bytecode word length 2"),
            "{error}"
        );
    }
}
