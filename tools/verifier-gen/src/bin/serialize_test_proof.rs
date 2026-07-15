//! Emit the `AirbenderPlonkProofFixture.sol` Solidity library (the `publicInputs()`,
//! `serializedProof()` and `programOutput()` arrays) used by the foundry tests against
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

    // Both modes reduce to two lists of `0x`-prefixed 32-byte hex words (the public inputs and the
    // serialized proof) plus the guest's program output. `render_fixture` is the single source of
    // the `.sol` layout.
    let (inputs, serialized_proof, program_output) = match (&opt.input, &opt.snark_proof_blob) {
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

    let out = render_fixture(&inputs, &serialized_proof, &program_output);
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
/// public inputs and proof words as lowercase 64-char hex strings, plus the guest program output.
fn from_json(
    input: &PathBuf,
) -> Result<(Vec<String>, Vec<String>, [u32; 8]), Box<dyn std::error::Error>> {
    let reader = BufReader::new(File::open(input)?);
    let proof: Proof<Bn256, ZkSyncSnarkWrapperCircuit> = serde_json::from_reader(reader)?;
    let (inputs, serialized_proof) = zksync_solidity_vk_codegen::serialize_proof(&proof);
    let inputs: Vec<String> = inputs.iter().map(|i| format!("{i:064x}")).collect();
    // A SNARK proof JSON only carries the already-shifted public input, so the program output's low
    // 32 bits (dropped by `PUBLIC_INPUT_SHIFT`) are unrecoverable here — `program_output_from_public_input`
    // zero-fills them. That low word is dropped again by the on-chain derivation, so the fixture stays
    // self-consistent; only the blob mode reproduces the true low word.
    let program_output = program_output_from_public_input(
        inputs.first().ok_or("proof JSON has no public input")?,
    )?;
    Ok((
        inputs,
        serialized_proof
            .iter()
            .map(|w| format!("{w:064x}"))
            .collect(),
        program_output,
    ))
}

/// Recovers the fixture arrays from the persisted SNARK proof blob plus the two batch commitments.
fn from_blob(
    blob: &PathBuf,
    prev_commitment: &str,
    curr_commitment: &str,
) -> Result<(Vec<String>, Vec<String>, [u32; 8]), Box<dyn std::error::Error>> {
    let proof_words = read_proof_words(blob)?;
    let (public_input, program_output) =
        derive_public_input_and_program_output(prev_commitment, curr_commitment)?;
    Ok((vec![public_input], proof_words, program_output))
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

/// From the two batch commitments, derive both:
///   * the SNARK public input — `keccak256(prev ‖ curr) >> PUBLIC_INPUT_SHIFT`, as a 64-char hex
///     string, mirroring the on-chain Era `_getBatchProofPublicInput`; and
///   * the guest program output — the full `keccak256(prev ‖ curr)` digest, which the guest folds
///     into registers 10..=17 before the wrapper shifts it into the public input, as 8 `u32` words.
fn derive_public_input_and_program_output(
    prev_commitment: &str,
    curr_commitment: &str,
) -> Result<(String, [u32; 8]), Box<dyn std::error::Error>> {
    let prev = parse_h256(prev_commitment, "prev-commitment")?;
    let curr = parse_h256(curr_commitment, "curr-commitment")?;

    let mut hasher = Keccak256::new();
    hasher.update(prev);
    hasher.update(curr);
    let digest: [u8; 32] = hasher.finalize().into();

    // Right-shift the 256-bit big-endian digest by 32 bits: zero the top 4 bytes and slide the
    // remaining 28 down.
    let mut shifted = [0u8; 32];
    shifted[PUBLIC_INPUT_SHIFT_BYTES..].copy_from_slice(&digest[..32 - PUBLIC_INPUT_SHIFT_BYTES]);

    Ok((hex::encode(shifted), program_output_words(&digest)))
}

/// Recover the program output (8 `u32` words) from an already-shifted public input, for the JSON
/// mode that has no commitments. The public input is the top 28 bytes of the digest; the low 4
/// bytes were dropped by `PUBLIC_INPUT_SHIFT` and cannot be recovered, so they are zero-filled.
fn program_output_from_public_input(
    public_input_hex: &str,
) -> Result<[u32; 8], Box<dyn std::error::Error>> {
    let pi = parse_h256(public_input_hex, "public-input")?;
    // `pi` holds the shifted value (its own top 4 bytes are zero); undo the shift to recover the
    // digest layout with a zeroed low word: digest_bytes = pi << 32.
    let mut digest = [0u8; 32];
    digest[..32 - PUBLIC_INPUT_SHIFT_BYTES].copy_from_slice(&pi[PUBLIC_INPUT_SHIFT_BYTES..]);
    Ok(program_output_words(&digest))
}

/// Split a big-endian 32-byte buffer into the guest's 8 program-output registers. Each register is
/// a little-endian `u32` occupying 4 consecutive bytes (RISC-V registers are little-endian), so the
/// buffer's most significant byte is the low byte of word 0 — the inverse of the packing done by
/// `_derivePublicInput` in the foundry test.
fn program_output_words(digest: &[u8; 32]) -> [u32; 8] {
    let mut words = [0u32; 8];
    for (i, word) in words.iter_mut().enumerate() {
        let j = i * 4;
        *word = (digest[j] as u32)
            | (digest[j + 1] as u32) << 8
            | (digest[j + 2] as u32) << 16
            | (digest[j + 3] as u32) << 24;
    }
    words
}

fn parse_h256(value: &str, what: &str) -> Result<[u8; 32], Box<dyn std::error::Error>> {
    let bytes = hex::decode(value.strip_prefix("0x").unwrap_or(value))?;
    bytes
        .try_into()
        .map_err(|_| format!("{what} must be 32 bytes").into())
}

/// Renders the fixture. Inputs/words are lowercase 64-char hex strings (no `0x`).
fn render_fixture(
    public_inputs: &[String],
    serialized_proof: &[String],
    program_output: &[u32; 8],
) -> String {
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
    out.push_str("    }\n\n");

    out.push_str("    /// The guest program output: registers 10..=17 (`Receipt::output`) the guest\n");
    out.push_str("    /// emitted for this batch, i.e. the full `keccak256(prev ‖ curr)` digest as 8\n");
    out.push_str("    /// little-endian `u32` words. The wrapper packs these, reads them big-endian and\n");
    out.push_str("    /// drops the low 32 bits (`PUBLIC_INPUT_SHIFT`) to obtain `publicInputs()[0]`.\n");
    out.push_str("    function programOutput() internal pure returns (uint32[8] memory words) {\n");
    out.push_str("        words = [\n");
    for (i, word) in program_output.iter().enumerate() {
        let sep = if i + 1 < program_output.len() { "," } else { "" };
        if i == 0 {
            out.push_str(&format!("            uint32({word}){sep}\n"));
        } else {
            out.push_str(&format!("            {word}{sep}\n"));
        }
    }
    out.push_str("        ];\n");
    out.push_str("    }\n");

    out.push_str("}\n");
    out
}
