use circuit_definitions::circuit_definitions::aux_layer::{
    ZkSyncSnarkWrapperCircuit, ZkSyncSnarkWrapperCircuitNoLookupCustomGate,
};
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::pairing::bn256::Bn256;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::plonk::better_better_cs::setup::VerificationKey;
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::fs::File;
use std::io::{BufReader, Write};
use zksync_crypto::flonk::FflonkVerificationKey;
use zksync_crypto::{calculate_fflonk_verification_key_hash, calculate_verification_key_hash};

pub mod fflonk;
pub mod plonk;
pub mod types;
pub mod utils;
pub mod zisk;

use fflonk::insert_residue_elements_and_commitments as fflonk_insert_residue_elements_and_commitments;
use plonk::insert_residue_elements_and_commitments as plonk_insert_residue_elements_and_commitments;
use serde_json::{from_reader, Value};
use std::str::FromStr;
use structopt::StructOpt;

#[derive(Debug, Clone)]
enum Variant {
    Era,
    ZKsyncOS,
    Zisk,
    Custom,
}

impl FromStr for Variant {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "era" => Ok(Variant::Era),
            "zksync-os" | "zksyncos" => Ok(Variant::ZKsyncOS),
            "zisk" => Ok(Variant::Zisk),
            "custom" => Ok(Variant::Custom),
            _ => Err(format!(
                "Invalid variant '{}'. Valid options: era, zksync-os, zisk, custom",
                s
            )),
        }
    }
}

#[derive(Debug, StructOpt)]
#[structopt(
    name = "zksync_verifier_contract_generator",
    about = "Tool for generating verifier contract using scheduler json key"
)]
struct Opt {
    /// Variant to use: era, zksync-os, zisk, or custom
    #[structopt(long = "variant", default_value = "custom")]
    variant: Variant,

    /// Input path to scheduler verification key file.
    #[structopt(
        long = "plonk_input_path",
        default_value = "data/plonk_scheduler_key.json"
    )]
    plonk_input_path: String,

    /// Input path to scheduler verification key file for .
    #[structopt(
        long = "fflonk_input_path",
        default_value = "data/fflonk_scheduler_key.json"
    )]
    fflonk_input_path: String,

    /// Output path to verifier contract file.
    #[structopt(long = "fflonk_output_path", default_value = "data/VerifierFflonk.sol")]
    fflonk_output_path: String,

    /// Output path to verifier contract file.
    #[structopt(long = "plonk_output_path", default_value = "data/VerifierPlonk.sol")]
    plonk_output_path: String,

    /// ZiSK VK input JSON (inner programVK, aggregator programVK,
    /// rootCVadcopFinal).
    #[structopt(long = "zisk_vk_path", default_value = "data/ZiSK_vk.json")]
    zisk_vk_path: String,

    /// ZiSK PlonkVerifier.sol input (snarkJS-generated).
    /// Used with --variant zisk to copy and adapt the inner verifier.
    #[structopt(long = "zisk_plonk_input_path")]
    zisk_plonk_input_path: Option<String>,

    /// ZiSK verifier output path.
    #[structopt(long = "zisk_output_path", default_value = "data/ZiskVerifier.sol")]
    zisk_output_path: String,
}

struct ResolvedPaths {
    plonk_input: String,
    plonk_output: String,
    fflonk: Option<(String, String)>,
}

fn resolve_paths(opt: &Opt) -> ResolvedPaths {
    match opt.variant {
        Variant::Era => ResolvedPaths {
            plonk_input: "data/Era_plonk_scheduler_key.json".to_string(),
            plonk_output: "data/EraVerifierPlonk.sol".to_string(),
            fflonk: Some((
                "data/Era_fflonk_scheduler_key.json".to_string(),
                "data/EraVerifierFflonk.sol".to_string(),
            )),
        },
        Variant::ZKsyncOS => ResolvedPaths {
            plonk_input: "data/ZKsyncOS_plonk_scheduler_key.json".to_string(),
            plonk_output: "data/ZKsyncOSVerifierPlonk.sol".to_string(),
            fflonk: None,
        },
        Variant::Custom => ResolvedPaths {
            plonk_input: opt.plonk_input_path.clone(),
            plonk_output: opt.plonk_output_path.clone(),
            fflonk: Some((
                opt.fflonk_input_path.clone(),
                opt.fflonk_output_path.clone(),
            )),
        },
        // The ZiSK variant resolves its own paths and returns before this point.
        Variant::Zisk => unreachable!(),
    }
}

fn resolve_contract_name(variant: &Variant) -> String {
    match variant {
        Variant::Era => "Era".to_string(),
        Variant::ZKsyncOS => "ZKsyncOS".to_string(),
        Variant::Custom => "".to_string(),
        // The ZiSK variant names its own contract and returns before this point.
        Variant::Zisk => unreachable!(),
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    let opt = Opt::from_args();

    // The ZiSK variant uses a completely different pipeline: it renders
    // ZiskVerifier from the ZiSK VK JSON, not from a scheduler key.
    if matches!(opt.variant, Variant::Zisk) {
        return zisk::generate_zisk_verifier(
            &opt.zisk_vk_path,
            &opt.zisk_output_path,
            opt.zisk_plonk_input_path.as_deref(),
        );
    }

    let paths = resolve_paths(&opt);
    let contract_name = resolve_contract_name(&opt.variant);

    let plonk_reader = BufReader::new(File::open(&paths.plonk_input)?);

    let plonk_vk: HashMap<String, Value> = from_reader(plonk_reader)?;

    let plonk_verifier_contract_template =
        fs::read_to_string("data/plonk_verifier_contract_template.txt")?;

    let plonk_verification_key = fs::read_to_string(&paths.plonk_input)
        .unwrap_or_else(|_| panic!("Unable to read from {}", &paths.plonk_input));

    let plonk_verification_key: VerificationKey<Bn256, ZkSyncSnarkWrapperCircuit> =
        serde_json::from_str(&plonk_verification_key).unwrap();

    let plonk_vk_hash =
        hex::encode(calculate_verification_key_hash(plonk_verification_key).to_fixed_bytes());

    let plonk_verifier_contract_template = plonk_insert_residue_elements_and_commitments(
        &plonk_verifier_contract_template,
        &plonk_vk,
        &plonk_vk_hash,
        &contract_name,
    )?;

    let mut plonk_file = File::create(paths.plonk_output)?;
    plonk_file.write_all(plonk_verifier_contract_template.as_bytes())?;

    if let Some((fflonk_input, fflonk_output)) = paths.fflonk {
        let fflonk_reader = BufReader::new(File::open(&fflonk_input)?);
        let fflonk_vk: HashMap<String, Value> = from_reader(fflonk_reader)?;
        let fflonk_verifier_contract_template =
            fs::read_to_string("data/fflonk_verifier_contract_template.txt")?;
        let fflonk_verification_key = fs::read_to_string(&fflonk_input)
            .unwrap_or_else(|_| panic!("Unable to read from {}", &fflonk_input));
        let fflonk_verification_key: FflonkVerificationKey<
            Bn256,
            ZkSyncSnarkWrapperCircuitNoLookupCustomGate,
        > = serde_json::from_str(&fflonk_verification_key).unwrap();
        let fflonk_vk_hash = hex::encode(
            calculate_fflonk_verification_key_hash(fflonk_verification_key).to_fixed_bytes(),
        );
        let fflonk_verifier_contract = fflonk_insert_residue_elements_and_commitments(
            &fflonk_verifier_contract_template,
            &fflonk_vk,
            &fflonk_vk_hash,
            &contract_name,
        )?;

        let mut fflonk_file = File::create(fflonk_output)?;
        fflonk_file.write_all(fflonk_verifier_contract.as_bytes())?;
    }

    Ok(())
}
