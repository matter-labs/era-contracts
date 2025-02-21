use circuit_definitions::snark_wrapper::franklin_crypto::bellman::plonk::better_better_cs::setup::VerificationKey;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::pairing::bn256::Bn256;
use circuit_definitions::circuit_definitions::aux_layer::ZkSyncSnarkWrapperCircuit;
use zksync_crypto::calculate_verification_key_hash;
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::fs::File;
use std::io::{BufReader, Write};

pub mod plonk;
pub mod fflonk;
pub mod types;
pub mod utils;

use serde_json::{from_reader, Value};
use structopt::StructOpt;
use plonk::insert_residue_elements_and_commitments as plonk_insert_residue_elements_and_commitments;
use fflonk::insert_residue_elements_and_commitments as fflonk_insert_residue_elements_and_commitments;

#[derive(Debug, StructOpt)]
#[structopt(
    name = "zksync_verifier_contract_generator",
    about = "Tool for generating verifier contract using scheduler json key"
)]
struct Opt {
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

    /// The Verifier is to be compiled for an L2 network, where modexp precompile is not available.
    #[structopt(short = "l2", long = "l2_mode")]
    l2_mode: bool,
}

fn main() -> Result<(), Box<dyn Error>> {
    let opt = Opt::from_args();

    let plonk_reader = BufReader::new(File::open(&opt.plonk_input_path)?);
    let fflonk_reader = BufReader::new(File::open(&opt.fflonk_input_path)?);

    let plonk_vk: HashMap<String, Value> = from_reader(plonk_reader)?;
    let fflonk_vk: HashMap<String, Value> = from_reader(fflonk_reader)?;

    let plonk_verifier_contract_template = fs::read_to_string("data/plonk_verifier_contract_template.txt")?;
    let fflonk_verifier_contract_template = fs::read_to_string("data/fflonk_verifier_contract_template.txt")?;

    let plonk_verifier_contract_template = if opt.l2_mode {
        plonk_verifier_contract_template.replace("contract VerifierPlonk", "contract L2VerifierPlonk")
    } else {
        plonk_verifier_contract_template
    };

    let fflonk_verifier_contract_template = if opt.l2_mode {
        fflonk_verifier_contract_template.replace("contract VerifierFflonk", "contract L2VerifierFflonk")
    } else {
        fflonk_verifier_contract_template
    };


    let plonk_verification_key = fs::read_to_string(&opt.plonk_input_path)
        .unwrap_or_else(|_| panic!("Unable to read from {}", &opt.plonk_input_path));

    let plonk_verification_key: VerificationKey<Bn256, ZkSyncSnarkWrapperCircuit> =
        serde_json::from_str(&plonk_verification_key).unwrap();

    let plonk_vk_hash = hex::encode(calculate_verification_key_hash(plonk_verification_key).to_fixed_bytes());

    let plonk_verifier_contract_template =
        plonk_insert_residue_elements_and_commitments(&plonk_verifier_contract_template, &plonk_vk, &plonk_vk_hash, opt.l2_mode)?;
    // TODO: use fflonk vk hash
    let fflonk_verifier_contract_template =
        fflonk_insert_residue_elements_and_commitments(&fflonk_verifier_contract_template, &fflonk_vk, &plonk_vk_hash, opt.l2_mode)?;

    let mut plonk_file = File::create(opt.plonk_output_path)?;
    plonk_file.write_all(plonk_verifier_contract_template.as_bytes())?;

    let mut fflonk_file = File::create(opt.fflonk_output_path)?;
    fflonk_file.write_all(fflonk_verifier_contract_template.as_bytes())?;    

    Ok(())
}