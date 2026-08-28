//! ZiSK verifier contract generation.
//!
//! Generates `ZiskVerifier.sol` from a JSON file that holds the two guest
//! programVKs and rootCVadcopFinal, using a text template.
//!
//! The ZiSK SNARK uses a different proof system (snarkJS Plonk) than Airbender
//! (boojum). snarkJS generates the inner Plonk verifier during
//! `ziskup setup_snark` and regenerates it whenever the circuit changes. Where
//! that lands depends on the install, so the render step reads the committed
//! verification key instead. The adapt step below writes the result to a
//! gitignored location for local builds and standalone deployment, and
//! `ZiskVerifier` reaches the deployed instance by address through
//! `IZiskSnarkPlonkVerifier`. See
//! `l1-contracts/contracts/state-transition/verifiers/README.md`.
//!
//! This module generates the outer wrapper (`ZiskVerifier.sol`) that:
//! - Hardcodes `innerProgramVK` (ROM Merkle root of the state-transition guest
//!   ELF — it enters the binding digest only)
//! - Hardcodes `aggregatorProgramVK` (ROM Merkle root of the aggregator guest
//!   ELF — it enters public-values bytes [0..32] only)
//! - Hardcodes `rootCVadcopFinal` (vadcop final root — changes on SNARK circuit
//!   regen; one value serves the digest and public-values bytes [544..576])
//! - Reconstructs the 576-byte public values from those pins and the batch
//!   public inputs, then computes `sha256(publicValues) % RFIELD`
//! - Calls the inner snarkJS PlonkVerifier for the actual SNARK check
//!
//! A programVK the ZiSK release has not published yet is carried as a
//! placeholder. The generator recognizes each placeholder and marks the
//! generated pin, and the VK hash derived from it, `STALE`.

use serde::Deserialize;
use sha3::{Digest, Keccak256};
use std::error::Error;
use std::fs;

#[derive(Deserialize)]
struct ZiskVk {
    inner_program_vk: [u64; 4],
    aggregator_program_vk: [u64; 4],
    root_cv_adcop_final: [u64; 4],
}

/// Placeholder inner programVK: `keccak256("zisk-inner-programvk-stale")`, read
/// as four big-endian u64 limbs.
const INNER_PROGRAM_VK_PLACEHOLDER: [u64; 4] = [
    13700430501868844200,
    15096809239806032041,
    12859342089998199634,
    9860071608042129445,
];

/// Placeholder aggregator programVK:
/// `keccak256("zisk-aggregator-programvk-stale")`, read as four big-endian u64
/// limbs. It differs from the inner placeholder, so a swapped pin still fails.
const AGGREGATOR_PROGRAM_VK_PLACEHOLDER: [u64; 4] = [
    12432157590653728692,
    12050317199529546573,
    4997395890756632183,
    12023935818373595804,
];

/// The NatSpec the generator adds above a placeholder programVK pin.
const PLACEHOLDER_PIN_NOTE: &str = concat!(
    "    /// @dev STALE: a placeholder, not a guest ELF root. The real limbs come\n",
    "    /// from the `rotate-program-vks` dispatch in the ZiSK repository. Put them\n",
    "    /// into the ZiSK VK JSON and regenerate this contract.\n",
);

/// The NatSpec the generator adds above the VK hash while any pin is a
/// placeholder.
const PLACEHOLDER_VK_HASH_NOTE: &str = concat!(
    "    /// @dev STALE: derived from a placeholder programVK pin, so it names no\n",
    "    /// deployed guest. It rotates with the pin.\n",
);

/// Format four u64 limbs as private Solidity constants named `_{prefix}_{index}`.
fn limb_constants(prefix: &str, limbs: &[u64; 4]) -> String {
    limbs
        .iter()
        .enumerate()
        .map(|(index, limb)| format!("    uint64 private constant _{prefix}_{index} = {limb};"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Append the four limbs of a pin, big-endian, to the VK hash preimage.
fn extend_with_limbs(preimage: &mut Vec<u8>, limbs: &[u64; 4]) {
    for limb in limbs {
        preimage.extend_from_slice(&limb.to_be_bytes());
    }
}

/// Generate ZiskVerifier.sol from VK JSON and template.
///
/// Optionally copies and adapts the snarkJS-generated PlonkVerifier.sol
/// (adjusting pragma and contract name for era-contracts conventions).
pub fn generate_zisk_verifier(
    vk_path: &str,
    output_path: &str,
    plonk_input_path: Option<&str>,
) -> Result<(), Box<dyn Error>> {
    let vk_json = fs::read_to_string(vk_path)?;
    let vk: ZiskVk = serde_json::from_str(&vk_json)?;

    let template = fs::read_to_string("data/zisk_verifier_contract_template.txt")?;

    // While a pin is a placeholder, the generated contract says so.
    let inner_is_placeholder = vk.inner_program_vk == INNER_PROGRAM_VK_PLACEHOLDER;
    let inner_program_vk_constants = format!(
        "{}{}",
        if inner_is_placeholder {
            PLACEHOLDER_PIN_NOTE
        } else {
            ""
        },
        limb_constants("INNER_PROGRAM_VK", &vk.inner_program_vk),
    );

    let aggregator_is_placeholder = vk.aggregator_program_vk == AGGREGATOR_PROGRAM_VK_PLACEHOLDER;
    let aggregator_program_vk_constants = format!(
        "{}{}",
        if aggregator_is_placeholder {
            PLACEHOLDER_PIN_NOTE
        } else {
            ""
        },
        limb_constants("AGGREGATOR_PROGRAM_VK", &vk.aggregator_program_vk),
    );

    let vk_hash_note = if inner_is_placeholder || aggregator_is_placeholder {
        PLACEHOLDER_VK_HASH_NOTE
    } else {
        ""
    };

    let root_cv_constants = limb_constants("ROOT_CV_ADCOP_FINAL", &vk.root_cv_adcop_final);

    // Compute VK hash = keccak256(innerProgramVK || aggregatorProgramVK ||
    // rootCVadcopFinal), u64 limbs serialized big-endian — the same byte order
    // the 576-byte public values use on the wire. Every pin enters the hash, so
    // a rotation of any one of them rotates the hash.
    let mut vk_hash_preimage = Vec::with_capacity(96);
    extend_with_limbs(&mut vk_hash_preimage, &vk.inner_program_vk);
    extend_with_limbs(&mut vk_hash_preimage, &vk.aggregator_program_vk);
    extend_with_limbs(&mut vk_hash_preimage, &vk.root_cv_adcop_final);
    let vk_hash = hex::encode(Keccak256::digest(&vk_hash_preimage));

    // Apply template substitutions
    let contract = template
        .replace("{{inner_program_vk_constants}}", &inner_program_vk_constants)
        .replace(
            "{{aggregator_program_vk_constants}}",
            &aggregator_program_vk_constants,
        )
        .replace("{{root_cv_constants}}", &root_cv_constants)
        .replace("{{vk_hash_note}}", vk_hash_note)
        .replace("{{vk_hash}}", &vk_hash);

    fs::write(output_path, &contract)?;
    println!("Generated ZiskVerifier at: {}", output_path);
    println!("  innerProgramVK: {:?}", vk.inner_program_vk);
    if inner_is_placeholder {
        println!("  WARNING: the inner programVK is the documented placeholder");
    }
    println!("  aggregatorProgramVK: {:?}", vk.aggregator_program_vk);
    if aggregator_is_placeholder {
        println!("  WARNING: the aggregator programVK is the documented placeholder");
    }
    println!("  rootCVadcopFinal: {:?}", vk.root_cv_adcop_final);
    println!("  VK hash: 0x{}", vk_hash);

    // Optionally copy and adapt the snarkJS PlonkVerifier
    if let Some(plonk_path) = plonk_input_path {
        let plonk_sol = fs::read_to_string(plonk_path)?;
        // Adjust the pragma and contract name for era-contracts conventions;
        // the snarkJS header is preserved verbatim.
        let adapted = plonk_sol
            .replace(
                "pragma solidity >=0.7.0 <0.9.0;",
                "pragma solidity 0.8.28;",
            )
            .replace("contract PlonkVerifier", "contract ZiskSnarkPlonkVerifier");

        // Gitignored: compiled when present (local builds, the real-proof
        // test), deployed standalone, and referenced by address on-chain.
        let plonk_output =
            "../../l1-contracts/contracts/dev-contracts/generated/ZiskSnarkPlonkVerifier.sol";
        if let Some(parent) = std::path::Path::new(plonk_output).parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(plonk_output, &adapted)?;
        println!("Generated ZiskSnarkPlonkVerifier at: {plonk_output}");
        println!("  deploy standalone and pass the address to ZiskVerifier's constructor");
    }

    Ok(())
}
