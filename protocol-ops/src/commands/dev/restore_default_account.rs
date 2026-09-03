//! Restore the reviewed v31 `DefaultAccount` artifact after a `system-contracts` build.
//!
//! The EraVM build is not bit-reproducible: a fresh build can differ from the reviewed
//! bytecode in its trailing 32-byte compiler-metadata word only, which still changes the
//! bytecode hash and trips the CTM upgrade's `default aa hash factory dep mismatch` check.
//!
//! Everything this needs is committed data: the env's v31 input pins the reviewed hash
//! (`[contracts] default_aa_hash`, which must agree with `AllContractsHashes.json`) and the
//! reviewed build's metadata word (`default_aa_metadata_word`). Swapping that word into the
//! built bytecode must reproduce the pinned hash exactly; since the hash is a SHA-256, that
//! single check proves the executable part of the build is byte-identical to the review.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use sha2::{Digest, Sha256};

use crate::common::files::{read_json_file, read_toml_file};
use crate::common::logger;

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
    /// The env's v31 input TOML: `[contracts] default_aa_hash` pins the reviewed hash and
    /// `default_aa_metadata_word` the reviewed build's trailing metadata word.
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

fn hex_field<'a>(table: &'a toml::Value, key: &str) -> Option<&'a str> {
    table.get(key).and_then(toml::Value::as_str)
}

pub fn restore_canonical_default_account(
    artifact_path: &Path,
    environment_path: &Path,
    hashes_path: &Path,
) -> anyhow::Result<()> {
    let environment: toml::Value = read_toml_file(environment_path)?;
    let contracts = environment.get("contracts").ok_or_else(|| {
        anyhow::anyhow!("{} has no [contracts] table", environment_path.display())
    })?;
    let pinned = hex_field(contracts, "default_aa_hash")
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

    let metadata_word = hex_field(contracts, "default_aa_metadata_word").ok_or_else(|| {
        anyhow::anyhow!(
            "built DefaultAccount hashes to {built} but {} pins {pinned}, and the env has no \
             [contracts] default_aa_metadata_word to restore the reviewed build from",
            environment_path.display()
        )
    })?;
    let metadata_word = hex::decode(metadata_word.trim_start_matches("0x"))
        .context("default_aa_metadata_word is not hex")?;
    anyhow::ensure!(
        metadata_word.len() == METADATA_WORD_BYTES,
        "default_aa_metadata_word must be 32 bytes"
    );
    anyhow::ensure!(
        bytecode.len() > METADATA_WORD_BYTES,
        "bytecode is too short to contain the metadata word"
    );
    let executable = &bytecode[..bytecode.len() - METADATA_WORD_BYTES];
    let canonical = [executable, &metadata_word].concat();
    let restored = zk_bytecode_hash(&canonical)?;
    anyhow::ensure!(
        restored == pinned,
        "the build differs from the reviewed DefaultAccount beyond the metadata word: \
         restoring the pinned word gives {restored}, not {pinned}"
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

    struct Fixture {
        _dir: tempfile::TempDir,
        artifact: PathBuf,
        environment: PathBuf,
        hashes: PathBuf,
    }

    /// An artifact holding `built`, and an env/hashes pair pinning `reviewed` (+ its metadata word).
    fn fixture(built: &[u8], reviewed: &[u8], pin_word: bool) -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let hash = zk_bytecode_hash(reviewed).unwrap();
        let artifact = dir.path().join("DefaultAccount.json");
        let environment = dir.path().join("environment.toml");
        let hashes = dir.path().join("AllContractsHashes.json");
        fs::write(
            &artifact,
            format!(r#"{{"bytecode":{{"object":"0x{}"}}}}"#, hex::encode(built)),
        )
        .unwrap();
        let mut toml = format!("[contracts]\ndefault_aa_hash = \"{hash}\"\n");
        if pin_word {
            let word = &reviewed[reviewed.len() - METADATA_WORD_BYTES..];
            toml += &format!("default_aa_metadata_word = \"0x{}\"\n", hex::encode(word));
        }
        fs::write(&environment, toml).unwrap();
        fs::write(
            &hashes,
            format!(r#"[{{"contractName":"{DEFAULT_ACCOUNT_CONTRACT_NAME}","zkBytecodeHash":"{hash}"}}]"#),
        )
        .unwrap();
        Fixture {
            _dir: dir,
            artifact,
            environment,
            hashes,
        }
    }

    fn artifact_bytecode(f: &Fixture) -> Vec<u8> {
        let artifact: serde_json::Value = read_json_file(&f.artifact).unwrap();
        hex::decode(
            artifact
                .pointer("/bytecode/object")
                .unwrap()
                .as_str()
                .unwrap()
                .trim_start_matches("0x"),
        )
        .unwrap()
    }

    #[test]
    fn leaves_an_artifact_unchanged_when_it_already_has_the_pinned_hash() {
        let bytecode = vec![7u8; 96];
        let f = fixture(&bytecode, &bytecode, false);
        let before = fs::read_to_string(&f.artifact).unwrap();
        restore_canonical_default_account(&f.artifact, &f.environment, &f.hashes).unwrap();
        assert_eq!(fs::read_to_string(&f.artifact).unwrap(), before);
    }

    #[test]
    fn restores_the_pinned_metadata_word_when_only_that_differs() {
        let reviewed = [vec![7u8; 64], vec![1u8; 32]].concat();
        let built = [vec![7u8; 64], vec![2u8; 32]].concat();
        let f = fixture(&built, &reviewed, true);
        restore_canonical_default_account(&f.artifact, &f.environment, &f.hashes).unwrap();
        assert_eq!(artifact_bytecode(&f), reviewed);
    }

    #[test]
    fn rejects_a_build_whose_executable_changed() {
        let reviewed = [vec![7u8; 64], vec![1u8; 32]].concat();
        let built = [vec![8u8; 64], vec![2u8; 32]].concat();
        let f = fixture(&built, &reviewed, true);
        let error =
            restore_canonical_default_account(&f.artifact, &f.environment, &f.hashes).unwrap_err();
        assert!(
            error.to_string().contains("beyond the metadata word"),
            "{error}"
        );
        assert_eq!(
            artifact_bytecode(&f),
            built,
            "the artifact must be left untouched"
        );
    }

    #[test]
    fn rejects_a_mismatch_when_no_metadata_word_is_pinned() {
        let reviewed = [vec![7u8; 64], vec![1u8; 32]].concat();
        let built = [vec![7u8; 64], vec![2u8; 32]].concat();
        let f = fixture(&built, &reviewed, false);
        let error =
            restore_canonical_default_account(&f.artifact, &f.environment, &f.hashes).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("no [contracts] default_aa_metadata_word"),
            "{error}"
        );
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
