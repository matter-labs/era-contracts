use circuit_definitions::circuit_definitions::aux_layer::ZkSyncSnarkWrapperCircuitNoLookupCustomGate;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::pairing::bn256::Bn256;
use zksync_crypto::flonk::FflonkVerificationKey;
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::fs::File;
use std::io::{BufReader, Write};
use zksync_crypto::calculate_fflonk_verification_key_hash;

pub mod fflonk;
pub mod types;
pub mod utils;

use fflonk::insert_residue_elements_and_commitments as fflonk_insert_residue_elements_and_commitments;
use serde_json::{from_reader, Value};
use structopt::StructOpt;

#[derive(Debug, StructOpt)]
#[structopt(
    name = "zksync_verifier_contract_generator",
    about = "Tool for generating FFLONK verifier contract using scheduler json key"
)]
struct Opt {
    /// Input path to scheduler verification key file for FFLONK.
    #[structopt(
        long = "fflonk_input_path",
        default_value = "data/fflonk_scheduler_key.json"
    )]
    fflonk_input_path: String,

    /// Output path to verifier contract file.
    #[structopt(long = "fflonk_output_path", default_value = "data/VerifierFflonk.sol")]
    fflonk_output_path: String,
}

fn main() -> Result<(), Box<dyn Error>> {
    let opt = Opt::from_args();

    let fflonk_reader = BufReader::new(File::open(&opt.fflonk_input_path)?);
    let fflonk_vk: HashMap<String, Value> = from_reader(fflonk_reader)?;

    let fflonk_verifier_contract_template =
        fs::read_to_string("data/fflonk_verifier_contract_template.txt")?;

    let fflonk_verifier_contract_template = fflonk_verifier_contract_template
        .replace("contract VerifierFflonk", "contract L1VerifierFflonk");

    let fflonk_verification_key = fs::read_to_string(&opt.fflonk_input_path)
        .unwrap_or_else(|_| panic!("Unable to read from {}", &opt.fflonk_input_path));

    let fflonk_verification_key: FflonkVerificationKey<Bn256, ZkSyncSnarkWrapperCircuitNoLookupCustomGate> =
        serde_json::from_str(&fflonk_verification_key).unwrap();

    let fflonk_vk_hash =
        hex::encode(calculate_fflonk_verification_key_hash(fflonk_verification_key).to_fixed_bytes());

    let fflonk_verifier_contract_template = fflonk_insert_residue_elements_and_commitments(
        &fflonk_verifier_contract_template,
        &fflonk_vk,
        &fflonk_vk_hash,
        false,
    )?;

    let mut fflonk_file = File::create(opt.fflonk_output_path)?;
    fflonk_file.write_all(fflonk_verifier_contract_template.as_bytes())?;

    Ok(())
}
