use circuit_definitions::ethereum_types::{H256, U256};
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::{
    compact_bn256::Fq,
    plonk::better_better_cs::{cs::Circuit, setup::VerificationKey},
    CurveAffine, Engine, PrimeField, PrimeFieldRepr,
};
use serde::{Deserialize, Serialize};
use sha3::{Digest, Keccak256};
use std::marker::PhantomData;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FflonkVerificationKey<E: Engine, C: Circuit<E>> {
    pub n: usize,
    pub c0: E::G1Affine,
    pub num_inputs: usize,
    pub num_state_polys: usize,
    pub num_witness_polys: usize,
    pub total_lookup_entries_length: usize,
    pub non_residues: Vec<E::Fr>,
    pub g2_elements: [E::G2Affine; 2],

    #[serde(skip_serializing, skip_deserializing, default)]
    #[serde(bound(serialize = ""))]
    #[serde(bound(deserialize = ""))]
    marker: PhantomData<C>,
}

pub fn calculate_verification_key_hash<E: Engine, C: Circuit<E>>(
    verification_key: VerificationKey<E, C>,
) -> H256 {
    let mut encoded = vec![];

    assert_eq!(8, verification_key.gate_setup_commitments.len());
    for commitment in verification_key.gate_setup_commitments {
        write_g1_point::<E>(&mut encoded, commitment);
    }

    assert_eq!(2, verification_key.gate_selectors_commitments.len());
    for commitment in verification_key.gate_selectors_commitments {
        write_g1_point::<E>(&mut encoded, commitment);
    }

    assert_eq!(4, verification_key.permutation_commitments.len());
    for commitment in verification_key.permutation_commitments {
        write_g1_point::<E>(&mut encoded, commitment);
    }

    write_g1_point::<E>(
        &mut encoded,
        verification_key.lookup_selector_commitment.unwrap(),
    );

    assert_eq!(4, verification_key.lookup_tables_commitments.len());
    for commitment in verification_key.lookup_tables_commitments {
        write_g1_point::<E>(&mut encoded, commitment);
    }

    write_g1_point::<E>(
        &mut encoded,
        verification_key.lookup_table_type_commitment.unwrap(),
    );

    Fq::default().into_repr().write_be(&mut encoded).unwrap();
    H256::from_slice(&Keccak256::digest(encoded))
}

pub fn calculate_fflonk_verification_key_hash<E: Engine, C: Circuit<E>>(
    verification_key: FflonkVerificationKey<E, C>,
) -> H256 {
    let mut encoded = vec![0_u8; 32];
    U256::from(verification_key.num_inputs).to_big_endian(&mut encoded);

    write_g1_point::<E>(&mut encoded, verification_key.c0);
    for non_residue in verification_key.non_residues {
        non_residue.into_repr().write_be(&mut encoded).unwrap();
    }
    for element in verification_key.g2_elements {
        encoded.extend(element.into_uncompressed().as_ref());
    }

    H256::from_slice(&Keccak256::digest(encoded))
}

fn write_g1_point<E: Engine>(encoded: &mut Vec<u8>, point: E::G1Affine) {
    let (x, y) = point.as_xy();
    x.into_repr().write_be(&mut *encoded).unwrap();
    y.into_repr().write_be(encoded).unwrap();
}
