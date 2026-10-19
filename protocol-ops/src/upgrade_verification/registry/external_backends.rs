//! Is the code a verifier delegates to, but which this repository does not build, the pinned one?
//!
//! `ZiskVerifier` checks the ZiSK SNARK through a standalone snarkJS Plonk backend
//! (`ZiskVerifier.PLONK_VERIFIER()`), rendered from the committed verification key outside this
//! repository (`l1-contracts/contracts/state-transition/verifiers/README.md`). No reviewed build
//! describes it, so it is pinned instead: [`ZISK_PLONK_BACKEND_PIN_PATH`] records the keccak256 of
//! the runtime that key and the recorded recipe produce, with the provenance to recompute it.
//! The backend has no constructor and no immutables, so its runtime is a pure function of the key
//! and the recipe: one pin serves every L1, and any address running the pinned code is as good as
//! another, so the address is not pinned.
//!
//! An entry may restrict itself to some upgrade envs (`envs`); without one it applies to every
//! env, which is the normal case.

use std::path::PathBuf;

use alloy::primitives::{keccak256, Address, B256};
use alloy::providers::Provider;
use serde::Deserialize;

use crate::upgrade_verification::constants::ZISK_PLONK_BACKEND_PIN_PATH;
use crate::upgrade_verification::paths::repo_relative_path;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::ReviewedBuild;

/// One pinned backend and how it was built.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct ZiskBackendPin {
    pub(crate) runtime_keccak256: B256,
    /// Bytes; informational.
    pub(crate) runtime_length: u64,
    /// The verification key it renders, under `tools/verifier-gen/data/`.
    pub(crate) verification_key: String,
    pub(crate) verification_key_sha256: String,
    pub(crate) template: String,
    pub(crate) compiler: String,
    pub(crate) builder: String,
    /// The upgrade envs it applies to; every env when absent.
    #[serde(default)]
    pub(crate) envs: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PinFile {
    #[serde(default)]
    backend: Vec<ZiskBackendPin>,
}

/// The pins that apply to one review.
#[derive(Debug)]
pub(crate) struct ZiskBackendPins {
    path: PathBuf,
    env: Option<String>,
    pins: Vec<ZiskBackendPin>,
}

impl ZiskBackendPins {
    /// The committed pins that apply to `env` (every env-unrestricted pin, plus those naming
    /// `env`), or why the file cannot be read.
    pub(crate) fn load(env: Option<&str>) -> Result<Self, String> {
        let path = repo_relative_path(ZISK_PLONK_BACKEND_PIN_PATH);
        let raw = std::fs::read_to_string(&path)
            .map_err(|e| format!("cannot read {} ({e})", path.display()))?;
        Self::parse(path, &raw, env)
    }

    fn parse(path: PathBuf, raw: &str, env: Option<&str>) -> Result<Self, String> {
        let file: PinFile =
            toml::from_str(raw).map_err(|e| format!("{} does not parse ({e})", path.display()))?;
        let pins = file
            .backend
            .into_iter()
            .filter(|pin| match (&pin.envs, env) {
                (None, _) => true,
                (Some(envs), Some(env)) => envs.iter().any(|e| e == env),
                (Some(_), None) => false,
            })
            .collect();
        Ok(Self {
            path,
            env: env.map(str::to_string),
            pins,
        })
    }

    /// Pins over the given runtimes, for tests.
    #[cfg(test)]
    pub(crate) fn of(runtimes: &[&[u8]]) -> Self {
        Self {
            path: PathBuf::from(ZISK_PLONK_BACKEND_PIN_PATH),
            env: None,
            pins: runtimes
                .iter()
                .map(|runtime| ZiskBackendPin {
                    runtime_keccak256: keccak256(runtime),
                    runtime_length: runtime.len() as u64,
                    verification_key: "ZiSK_plonk_verification_key.json".to_string(),
                    verification_key_sha256: "test".to_string(),
                    template: "test".to_string(),
                    compiler: "test".to_string(),
                    builder: "test".to_string(),
                    envs: None,
                })
                .collect(),
        }
    }

    fn pinned(&self, runtime_keccak256: B256) -> Option<&ZiskBackendPin> {
        self.pins
            .iter()
            .find(|pin| pin.runtime_keccak256 == runtime_keccak256)
    }
}

/// Reports whether the code at `address` — `label`, the backend a `ZiskVerifier` names — is a
/// pinned ZiSK Plonk backend. No code, unreadable pins, no applicable pin and code no pin
/// describes are each an error.
pub(super) async fn judge_zisk_backend<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    address: Address,
) -> anyhow::Result<()> {
    let code = provider.get_code_at(address).await?;
    if code.is_empty() {
        result.report_error(&format!(
            "{label} at {address} has NO code: ZiskVerifier would revert on every ZiSK proof"
        ));
        return Ok(());
    }
    let pins = match build.zisk_backends() {
        Ok(pins) => pins,
        Err(why) => {
            result.report_error(&format!(
                "{label} at {address}: the ZiSK backend pins cannot be read ({why}), so the \
                 backend is unverified"
            ));
            return Ok(());
        }
    };
    if pins.pins.is_empty() {
        result.report_error(&format!(
            "{label} at {address} is ZiskVerifier's snarkJS Plonk backend, built outside this \
             repository, and {} pins none{}: the proofs this verifier accepts rest on code this \
             review cannot identify",
            pins.path.display(),
            match &pins.env {
                Some(env) => format!(" for env {env}"),
                None => String::new(),
            }
        ));
        return Ok(());
    }
    let hash = keccak256(&code);
    match pins.pinned(hash) {
        Some(pin) => result.report_ok(&format!(
            "{label} at {address} runs the pinned ZiSK Plonk backend (keccak256 {hash}; {} \
             sha256 {}; {})",
            pin.verification_key, pin.verification_key_sha256, pin.builder
        )),
        None => result.report_error(&format!(
            "{label} at {address} runs code with keccak256 {hash} ({} bytes), which is not the \
             pinned ZiSK Plonk backend ({}): a different verification key, compiler setup or \
             contract would check every ZiSK proof",
            code.len(),
            pins.pins
                .iter()
                .map(|pin| pin.runtime_keccak256.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::registry::provenance::CodeIdentity;
    use alloy::primitives::Bytes;
    use alloy::providers::ProviderBuilder;
    use alloy::transports::mock::Asserter;
    use sha2::{Digest, Sha256};

    const DATA_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../tools/verifier-gen/data");

    fn committed() -> ZiskBackendPins {
        let path = PathBuf::from(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../tools/verifier-gen/data/ZiSK_plonk_backend.toml"
        ));
        let raw = std::fs::read_to_string(&path).unwrap();
        ZiskBackendPins::parse(path, &raw, None).unwrap()
    }

    /// The constant names the committed file.
    #[test]
    fn the_pin_path_is_the_committed_file() {
        assert!(PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/.."))
            .join(ZISK_PLONK_BACKEND_PIN_PATH)
            .is_file());
    }

    /// The committed pin describes the backend of the committed verification key: a key rotation
    /// that does not re-pin fails here, in the same change.
    #[test]
    fn the_committed_pin_matches_the_committed_verification_key() {
        let pins = committed();
        assert!(!pins.pins.is_empty(), "no backend is pinned");
        for pin in &pins.pins {
            assert!(pin.envs.is_none(), "the committed pin applies to every env");
            assert_ne!(pin.runtime_keccak256, B256::ZERO);
            let key = std::fs::read(format!("{DATA_DIR}/{}", pin.verification_key)).unwrap();
            assert_eq!(
                pin.verification_key_sha256,
                alloy::hex::encode(Sha256::digest(&key)),
                "{} changed: rebuild the backend and re-pin it",
                pin.verification_key
            );
        }
    }

    /// An env a pin restricts itself to must be one the review can be run for.
    #[test]
    fn every_pin_env_is_a_known_env() {
        let known: Vec<String> = std::fs::read_dir(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../l1-contracts/upgrade-envs/permanent-values"
        ))
        .unwrap()
        .filter_map(|entry| {
            let name = entry.unwrap().file_name().into_string().unwrap();
            name.strip_suffix(".toml").map(str::to_string)
        })
        .collect();
        for pin in committed().pins {
            for env in pin.envs.unwrap_or_default() {
                assert!(known.contains(&env), "unknown env {env}");
            }
        }
    }

    /// An env-restricted pin applies to its envs only; an unrestricted one to every review.
    #[test]
    fn a_pin_for_another_env_does_not_apply() {
        let raw = |envs: &str| {
            format!(
                "[[backend]]\n\
                 runtime_keccak256 = \"{}\"\n\
                 runtime_length = 1\n\
                 verification_key = \"k\"\n\
                 verification_key_sha256 = \"s\"\n\
                 template = \"t\"\n\
                 compiler = \"c\"\n\
                 builder = \"b\"\n\
                 {envs}",
                B256::repeat_byte(0x01)
            )
        };
        let parse = |envs: &str, env: Option<&str>| {
            ZiskBackendPins::parse(PathBuf::from("pins.toml"), &raw(envs), env)
                .unwrap()
                .pins
                .len()
        };
        assert_eq!(parse("envs = [\"stage\"]\n", Some("stage")), 1);
        assert_eq!(parse("envs = [\"stage\"]\n", Some("mainnet")), 0);
        assert_eq!(parse("envs = [\"stage\"]\n", None), 0);
        assert_eq!(parse("", Some("mainnet")), 1);
        // A field the format does not know is refused rather than ignored.
        assert!(ZiskBackendPins::parse(
            PathBuf::from("pins.toml"),
            &raw("address = \"0x01\"\n"),
            None
        )
        .is_err());
    }

    const BACKEND: Address = Address::repeat_byte(0xBE);
    const PINNED: &[u8] = b"the pinned snarkJS Plonk backend runtime";

    async fn judge(code: &[u8], pins: Result<ZiskBackendPins, String>) -> VerificationResult {
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::copy_from_slice(code));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let build = ReviewedBuild::from_artifacts(CodeIdentity::empty(), Vec::new())
            .with_zisk_backends(pins);
        let mut result = VerificationResult::default();
        judge_zisk_backend(&provider, &build, &mut result, "the backend", BACKEND)
            .await
            .unwrap();
        assert!(asserter.read_q().is_empty());
        result
    }

    #[tokio::test]
    async fn the_pinned_backend_passes() {
        let result = judge(PINNED, Ok(ZiskBackendPins::of(&[PINNED]))).await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    #[tokio::test]
    async fn wrong_backend_code_fails() {
        let result = judge(
            b"a Plonk verifier that accepts anything",
            Ok(ZiskBackendPins::of(&[PINNED])),
        )
        .await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("which is not the pinned ZiSK Plonk backend"));
    }

    #[tokio::test]
    async fn an_unpinned_backend_fails() {
        let result = judge(PINNED, Ok(ZiskBackendPins::of(&[]))).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("pins none"));
    }

    #[tokio::test]
    async fn a_backend_without_code_fails() {
        let result = judge(&[], Ok(ZiskBackendPins::of(&[PINNED]))).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("has NO code"));
    }

    #[tokio::test]
    async fn unreadable_pins_fail() {
        let result = judge(PINNED, Err("cannot read the pins".to_string())).await;
        assert_eq!(result.errors, 1);
        assert!(result.has_error("cannot be read"));
    }
}
