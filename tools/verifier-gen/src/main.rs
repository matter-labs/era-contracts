use circuit_definitions::circuit_definitions::aux_layer::{ZkSyncSnarkWrapperCircuit, ZkSyncSnarkWrapperCircuitNoLookupCustomGate};
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::pairing::bn256::Bn256;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::plonk::better_better_cs::setup::VerificationKey;
use zksync_crypto::flonk::FflonkVerificationKey;
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::fs::File;
use std::io::{BufReader, Write};
use zksync_crypto::{calculate_fflonk_verification_key_hash, calculate_verification_key_hash};

pub mod fflonk;
pub mod plonk;
pub mod types;
pub mod utils;

use fflonk::insert_residue_elements_and_commitments as fflonk_insert_residue_elements_and_commitments;
use plonk::insert_residue_elements_and_commitments as plonk_insert_residue_elements_and_commitments;
use serde_json::{from_reader, Value};
use structopt::StructOpt;
use std::str::FromStr;

#[derive(Debug, Clone)]
enum Variant {
    Era,
    ZKsyncOS,
    /// Airbender (RISC-V) FRI proof wrapped into a PLONK SNARK. Only a PLONK
    /// verification key exists for it today, so this variant generates just the
    /// PLONK verifier. Its input `snark_vk.json` is downloaded from the pinned
    /// `eravm-airbender-verifier` release by `regenerate-airbender-verifier.sh`.
    Airbender,
    Custom,
}

impl FromStr for Variant {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "era" => Ok(Variant::Era),
            "zksync-os" | "zksyncos" => Ok(Variant::ZKsyncOS),
            "airbender" => Ok(Variant::Airbender),
            "custom" => Ok(Variant::Custom),
            _ => Err(format!(
                "Invalid variant '{}'. Valid options: era, zksync-os, airbender, custom",
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
    /// Variant to use: era, zksync-os, airbender, or custom
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

}

/// A single verifier contract to generate from a verification key.
struct Job {
    input_path: String,
    output_path: String,
}

/// Resolve which contracts to generate for a variant. The PLONK job is always
/// present; the FFLONK job is `None` for variants that have no FFLONK wrapper
/// (currently Airbender).
fn resolve_jobs(opt: &Opt) -> (Job, Option<Job>) {
    match opt.variant {
        Variant::Era => (
            Job {
                input_path: "data/Era_plonk_scheduler_key.json".to_string(),
                output_path: "data/EraVerifierPlonk.sol".to_string(),
            },
            Some(Job {
                input_path: "data/Era_fflonk_scheduler_key.json".to_string(),
                output_path: "data/EraVerifierFflonk.sol".to_string(),
            }),
        ),
        Variant::ZKsyncOS => (
            Job {
                input_path: "data/ZKsyncOS_plonk_scheduler_key.json".to_string(),
                output_path: "data/ZKsyncOSVerifierPlonk.sol".to_string(),
            },
            Some(Job {
                input_path: "data/ZKsyncOS_fflonk_scheduler_key.json".to_string(),
                output_path: "data/ZKsyncOSVerifierFflonk.sol".to_string(),
            }),
        ),
        Variant::Airbender => (
            Job {
                input_path: "data/airbender_snark_vk.json".to_string(),
                output_path: "data/AirbenderVerifierPlonk.sol".to_string(),
            },
            None,
        ),
        Variant::Custom => (
            Job {
                input_path: opt.plonk_input_path.clone(),
                output_path: opt.plonk_output_path.clone(),
            },
            Some(Job {
                input_path: opt.fflonk_input_path.clone(),
                output_path: opt.fflonk_output_path.clone(),
            }),
        ),
    }
}

fn resolve_contract_name(variant: &Variant) -> String {
    match variant {
        Variant::Era => "Era".to_string(),
        Variant::ZKsyncOS => "ZKsyncOS".to_string(),
        Variant::Airbender => "Airbender".to_string(),
        Variant::Custom => "".to_string(),
    }
}

/// Generate a PLONK verifier contract from a scheduler/snark verification key.
fn generate_plonk(job: &Job, contract_name: &str) -> Result<(), Box<dyn Error>> {
    let reader = BufReader::new(File::open(&job.input_path)?);
    let vk: HashMap<String, Value> = from_reader(reader)?;

    let template = fs::read_to_string("data/plonk_verifier_contract_template.txt")?;

    let vk_text = fs::read_to_string(&job.input_path)
        .unwrap_or_else(|_| panic!("Unable to read from {}", &job.input_path));
    let vk_typed: VerificationKey<Bn256, ZkSyncSnarkWrapperCircuit> =
        serde_json::from_str(&vk_text).unwrap();
    let vk_hash = hex::encode(calculate_verification_key_hash(vk_typed).to_fixed_bytes());

    let contract =
        plonk_insert_residue_elements_and_commitments(&template, &vk, &vk_hash, contract_name)?;

    File::create(&job.output_path)?.write_all(contract.as_bytes())?;
    println!("Wrote PLONK verifier to {} (vk hash 0x{})", job.output_path, vk_hash);
    Ok(())
}

/// Generate an FFLONK verifier contract from a scheduler verification key.
fn generate_fflonk(job: &Job, contract_name: &str) -> Result<(), Box<dyn Error>> {
    let reader = BufReader::new(File::open(&job.input_path)?);
    let vk: HashMap<String, Value> = from_reader(reader)?;

    let template = fs::read_to_string("data/fflonk_verifier_contract_template.txt")?;

    let vk_text = fs::read_to_string(&job.input_path)
        .unwrap_or_else(|_| panic!("Unable to read from {}", &job.input_path));
    let vk_typed: FflonkVerificationKey<Bn256, ZkSyncSnarkWrapperCircuitNoLookupCustomGate> =
        serde_json::from_str(&vk_text).unwrap();
    let vk_hash = hex::encode(calculate_fflonk_verification_key_hash(vk_typed).to_fixed_bytes());

    let contract =
        fflonk_insert_residue_elements_and_commitments(&template, &vk, &vk_hash, contract_name)?;

    File::create(&job.output_path)?.write_all(contract.as_bytes())?;
    println!("Wrote FFLONK verifier to {} (vk hash 0x{})", job.output_path, vk_hash);
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let opt = Opt::from_args();

    let contract_name = resolve_contract_name(&opt.variant);
    let (plonk_job, fflonk_job) = resolve_jobs(&opt);

    generate_plonk(&plonk_job, &contract_name)?;
    if let Some(fflonk_job) = fflonk_job {
        generate_fflonk(&fflonk_job, &contract_name)?;
    }

    Ok(())
}
