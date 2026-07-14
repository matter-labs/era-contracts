//! Emit the `AirbenderPlonkProofFixture.sol` Solidity library (the `publicInputs()`
//! and `serializedProof()` arrays) used by the foundry tests against
//! `AirbenderVerifierPlonk` / `EraDualVerifier`.
//!
//! Two input modes:
//!
//!   * `--input <snark_proof.json>` — a `zkos-wrapper` PLONK SNARK proof JSON, as
//!     produced by `eravm-prover-host prove-snark`. Both arrays are derived from it
//!     via `serialize_proof`.
//!
//!   * `--snark-proof-blob <blob.bin>` `--prev-commitment <hex>` `--curr-commitment <hex>`
//!     — refresh the fixture from the proof a real e2e run left on disk. The blob is the
//!     Airbender SNARK proof object the `airbender_proof_data_handler` persists (uploaded
//!     by the `ci-airbender-prover-e2e` workflow); it carries the 44 serialized proof words
//!     but not the public input. The public input is recomputed exactly as the on-chain
//!     `Executor._getBatchProofPublicInput` does — `keccak256(prev ‖ curr) >> 32` over the
//!     batch commitments — so pass the two commitments the workflow dumps alongside the blob.
//!
//! Usage:
//!   cargo run --release --bin serialize_test_proof -- \
//!     --input <snark_proof.json> --output <AirbenderPlonkProofFixture.sol>
//!   cargo run --release --bin serialize_test_proof -- \
//!     --snark-proof-blob <blob.bin> --prev-commitment 0x.. --curr-commitment 0x.. \
//!     --output <AirbenderPlonkProofFixture.sol>

use std::fs::File;
use std::io::{BufReader, Write};
use std::path::PathBuf;

use circuit_definitions::circuit_definitions::aux_layer::ZkSyncSnarkWrapperCircuit;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::pairing::bn256::Bn256;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::plonk::better_better_cs::proof::Proof;
use serde::Deserialize;
use sha3::{Digest, Keccak256};
use structopt::StructOpt;

/// Matches `PUBLIC_INPUT_SHIFT` in `l1-contracts` `common/Config.sol`: BN254's scalar field is
/// ~254 bits, so the low 32 bits of the commitment digest are dropped to make the public input a
/// valid field element.
const PUBLIC_INPUT_SHIFT_BYTES: usize = 4;

#[derive(StructOpt)]
#[structopt(name = "serialize_test_proof")]
struct Opt {
    /// PLONK SNARK proof JSON (`Proof<Bn256, ZkSyncSnarkWrapperCircuit>`). Mutually exclusive with
    /// `--snark-proof-blob`.
    #[structopt(long)]
    input: Option<PathBuf>,

    /// Persisted Airbender SNARK proof blob from an e2e run. Requires `--prev-commitment` and
    /// `--curr-commitment`.
    #[structopt(long)]
    snark_proof_blob: Option<PathBuf>,

    /// Commitment of the previous batch (hex, `0x`-prefixed or not); with `--snark-proof-blob`.
    #[structopt(long)]
    prev_commitment: Option<String>,

    /// Commitment of the proven batch (hex, `0x`-prefixed or not); with `--snark-proof-blob`.
    #[structopt(long)]
    curr_commitment: Option<String>,

    #[structopt(long)]
    output: PathBuf,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let opt = Opt::from_args();

    // Both modes reduce to two lists of `0x`-prefixed 32-byte hex words: the public inputs and the
    // serialized proof. `render_fixture` is the single source of the `.sol` layout.
    let (inputs, serialized_proof) = match (&opt.input, &opt.snark_proof_blob) {
        (Some(input), None) => from_json(input)?,
        (None, Some(blob)) => {
            let prev = opt
                .prev_commitment
                .as_deref()
                .ok_or("--snark-proof-blob requires --prev-commitment")?;
            let curr = opt
                .curr_commitment
                .as_deref()
                .ok_or("--snark-proof-blob requires --curr-commitment")?;
            from_blob(blob, prev, curr)?
        }
        (Some(_), Some(_)) => {
            return Err("pass either --input or --snark-proof-blob, not both".into())
        }
        (None, None) => return Err("pass --input or --snark-proof-blob".into()),
    };

    let out = render_fixture(&inputs, &serialized_proof);
    File::create(&opt.output)?.write_all(out.as_bytes())?;

    println!(
        "Wrote {} public input(s) and {} proof words to {}",
        inputs.len(),
        serialized_proof.len(),
        opt.output.display()
    );
    Ok(())
}

/// Reads the canonical PLONK proof JSON and flattens it with `serialize_proof`, returning the
/// public inputs and proof words as lowercase 64-char hex strings.
fn from_json(input: &PathBuf) -> Result<(Vec<String>, Vec<String>), Box<dyn std::error::Error>> {
    let reader = BufReader::new(File::open(input)?);
    let proof: Proof<Bn256, ZkSyncSnarkWrapperCircuit> = serde_json::from_reader(reader)?;
    let (inputs, serialized_proof) = zksync_solidity_vk_codegen::serialize_proof(&proof);
    Ok((
        inputs.iter().map(|i| format!("{i:064x}")).collect(),
        serialized_proof
            .iter()
            .map(|w| format!("{w:064x}"))
            .collect(),
    ))
}

/// Recovers the fixture arrays from the persisted SNARK proof blob plus the two batch commitments.
fn from_blob(
    blob: &PathBuf,
    prev_commitment: &str,
    curr_commitment: &str,
) -> Result<(Vec<String>, Vec<String>), Box<dyn std::error::Error>> {
    let proof_words = read_proof_words(blob)?;
    let public_input = derive_public_input(prev_commitment, curr_commitment)?;
    Ok((vec![public_input], proof_words))
}

/// The stored SNARK proof object, mirrored just enough to reach the serialized proof words.
///
/// On disk the blob is `bincode(L1BatchAirbenderSnarkProofForL1)` — a single `#[serde_as(as = "Hex")]`
/// field, i.e. a bincode string: an 8-byte little-endian length followed by the ASCII hex of the
/// inner bytes. Those inner bytes are `ciborium(L1BatchProofForL1)`, an externally-tagged enum whose
/// `Airbender` variant holds `proof` as a CBOR array of bytes. We only need `proof`; unknown fields
/// (e.g. `protocol_version`) and the other variants are ignored.
#[derive(Deserialize)]
struct StoredL1BatchProof {
    inner: StoredTyped,
}

#[derive(Deserialize)]
enum StoredTyped {
    Fflonk(serde::de::IgnoredAny),
    Plonk(serde::de::IgnoredAny),
    Airbender(StoredAirbender),
}

#[derive(Deserialize)]
struct StoredAirbender {
    proof: Vec<u8>,
}

fn read_proof_words(blob: &PathBuf) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let raw = std::fs::read(blob)?;
    if raw.len() < 8 {
        return Err("SNARK proof blob is too short to hold a bincode length prefix".into());
    }
    let len = u64::from_le_bytes(raw[0..8].try_into().unwrap()) as usize;
    let hex_ascii = raw
        .get(8..8 + len)
        .ok_or("SNARK proof blob length prefix exceeds file size")?;
    let cbor = hex::decode(std::str::from_utf8(hex_ascii)?)?;

    let stored: StoredL1BatchProof = ciborium::from_reader(&cbor[..])?;
    let proof_bytes = match stored.inner {
        StoredTyped::Airbender(a) => a.proof,
        _ => return Err("blob does not contain an Airbender proof".into()),
    };

    if proof_bytes.len() % 32 != 0 {
        return Err(format!(
            "proof byte length {} is not a multiple of 32",
            proof_bytes.len()
        )
        .into());
    }
    Ok(proof_bytes.chunks(32).map(hex::encode).collect())
}

/// `keccak256(prev ‖ curr) >> PUBLIC_INPUT_SHIFT`, returned as a 64-char hex string. Mirrors the
/// on-chain Era `_getBatchProofPublicInput` (and the value the guest folds into its program output).
fn derive_public_input(
    prev_commitment: &str,
    curr_commitment: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    let prev = parse_h256(prev_commitment, "prev-commitment")?;
    let curr = parse_h256(curr_commitment, "curr-commitment")?;

    let mut hasher = Keccak256::new();
    hasher.update(prev);
    hasher.update(curr);
    let digest = hasher.finalize();

    // Right-shift the 256-bit big-endian digest by 32 bits: zero the top 4 bytes and slide the
    // remaining 28 down.
    let mut shifted = [0u8; 32];
    shifted[PUBLIC_INPUT_SHIFT_BYTES..].copy_from_slice(&digest[..32 - PUBLIC_INPUT_SHIFT_BYTES]);
    Ok(hex::encode(shifted))
}

fn parse_h256(value: &str, what: &str) -> Result<[u8; 32], Box<dyn std::error::Error>> {
    let bytes = hex::decode(value.strip_prefix("0x").unwrap_or(value))?;
    bytes
        .try_into()
        .map_err(|_| format!("{what} must be 32 bytes").into())
}

/// Renders the fixture. Inputs/words are lowercase 64-char hex strings (no `0x`).
fn render_fixture(public_inputs: &[String], serialized_proof: &[String]) -> String {
    let mut out = String::new();
    out.push_str("// SPDX-License-Identifier: MIT\n");
    out.push_str("// Generated by tools/src/bin/serialize_test_proof.rs — do not edit by hand.\n");
    out.push_str("pragma solidity 0.8.28;\n\n");
    out.push_str("/// @notice Fixture proof + public input for an airbender PLONK SNARK,\n");
    out.push_str("/// produced by `eravm-prover-host prove-snark` over the `eravm-airbender-verifier` guest.\n");
    out.push_str("library AirbenderPlonkProofFixture {\n");

    out.push_str(&format!(
        "    function publicInputs() internal pure returns (uint256[] memory inputs) {{\n        inputs = new uint256[]({});\n",
        public_inputs.len()
    ));
    for (i, input) in public_inputs.iter().enumerate() {
        out.push_str(&format!("        inputs[{i}] = 0x{input};\n"));
    }
    out.push_str("    }\n\n");

    out.push_str(&format!(
        "    function serializedProof() internal pure returns (uint256[] memory proof) {{\n        proof = new uint256[]({});\n",
        serialized_proof.len()
    ));
    for (i, word) in serialized_proof.iter().enumerate() {
        out.push_str(&format!("        proof[{i}] = 0x{word};\n"));
    }
    out.push_str("    }\n");

    out.push_str("}\n");
    out
}
