
use ethers::{
    abi::{decode, ParamType},
    types::{Address, U256},
    utils::hex,
};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct AdminCall {
    pub description: String,
    pub target: Address,
    #[serde(serialize_with = "serialize_hex")]
    pub data: Vec<u8>,
    pub value: U256,
}

pub(crate) fn decode_admin_calls(encoded_calls: &[u8]) -> anyhow::Result<Vec<AdminCall>> {
    let calls = decode(
        &[ParamType::Array(Box::new(ParamType::Tuple(vec![
            ParamType::Address,
            ParamType::Uint(256),
            ParamType::Bytes,
        ])))],
        encoded_calls,
    )?
    .pop()
    .unwrap()
    .into_array()
    .unwrap();

    let calls = calls
        .into_iter()
        .map(|call| {
            // The type was checked during decoding, so "unwrap" is safe
            let subfields = call.into_tuple().unwrap();

            AdminCall {
                // TODO(EVM-999): For now, only empty descriptions are available
                description: "".into(),
                // The type was checked during decoding, so "unwrap" is safe
                target: subfields[0].clone().into_address().unwrap(),
                // The type was checked during decoding, so "unwrap" is safe
                value: subfields[1].clone().into_uint().unwrap(),
                // The type was checked during decoding, so "unwrap" is safe
                data: subfields[2].clone().into_bytes().unwrap(),
            }
        })
        .collect();

    Ok(calls)
}

fn serialize_hex<S>(bytes: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    let hex_string = format!("0x{}", hex::encode(bytes));
    serializer.serialize_str(&hex_string)
}
