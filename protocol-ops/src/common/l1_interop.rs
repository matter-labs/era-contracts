//! Validate L1 ERC-7786 requests and identify recipients for simulation descriptions.

use alloy::{primitives::Address, sol, sol_types::SolCall};
use std::collections::HashSet;

sol! {
    function sendMessage(bytes recipient, bytes payload, bytes[] attributes);
    function l1ToL2TransactionParams(uint256 mintValue, uint256 l2GasLimit, uint256 l2GasPerPubdataByteLimit, address refundRecipient);
    function interopCallValue(uint256 value);
    function indirectCall(uint256 value);
    function factoryDeps(bytes[] dependencies);
}

#[derive(Debug)]
pub struct L1Message {
    pub recipient: Address,
    pub is_indirect: bool,
}

pub fn is_send_message(data: &[u8]) -> bool {
    data.get(..4) == Some(sendMessageCall::SELECTOR.as_slice())
}

pub fn decode(data: &[u8]) -> Result<L1Message, String> {
    let call = sendMessageCall::abi_decode(data).map_err(|err| err.to_string())?;
    let recipient = call.recipient.as_ref();
    if recipient.len() < 6 || recipient[..4] != [0, 1, 0, 0] {
        return Err("invalid ERC-7930 EVM-v1 recipient".into());
    }
    let chain_len = usize::from(recipient[4]);
    if chain_len > 32 || recipient.len() < 6 + chain_len {
        return Err("invalid ERC-7930 chain reference".into());
    }
    let address_len = usize::from(recipient[5 + chain_len]);
    if ![0, 20].contains(&address_len) || recipient.len() != 6 + chain_len + address_len {
        return Err("invalid ERC-7930 address length".into());
    }
    let recipient = if address_len == 0 {
        Address::ZERO
    } else {
        Address::from_slice(&recipient[6 + chain_len..])
    };
    let mut seen = HashSet::new();
    for attribute in call.attributes {
        let selector: [u8; 4] = attribute
            .get(..4)
            .ok_or("truncated attribute")?
            .try_into()
            .map_err(|_| "truncated selector")?;
        if !seen.insert(selector) {
            return Err("duplicate L1 attribute".into());
        }
        match selector {
            l1ToL2TransactionParamsCall::SELECTOR => {
                l1ToL2TransactionParamsCall::abi_decode(&attribute)
                    .map_err(|err| err.to_string())?;
            }
            interopCallValueCall::SELECTOR => {
                interopCallValueCall::abi_decode(&attribute).map_err(|err| err.to_string())?;
            }
            indirectCallCall::SELECTOR => {
                indirectCallCall::abi_decode(&attribute).map_err(|err| err.to_string())?;
            }
            factoryDepsCall::SELECTOR => {
                factoryDepsCall::abi_decode(&attribute).map_err(|err| err.to_string())?;
            }
            _ => return Err("unsupported L1 attribute".into()),
        }
    }
    if !seen.contains(&l1ToL2TransactionParamsCall::SELECTOR) {
        return Err("missing L1 transaction parameters".into());
    }
    let is_indirect = seen.contains(&indirectCallCall::SELECTOR);
    if is_indirect && seen.contains(&factoryDepsCall::SELECTOR) {
        return Err("factory dependencies are only valid for direct messages".into());
    }
    Ok(L1Message {
        recipient,
        is_indirect,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{Bytes, U256};

    fn message(indirect: bool) -> sendMessageCall {
        let recipient =
            alloy::hex::decode("000100000201fa140000000000000000000000000000000000012345").unwrap();
        let mut attributes = vec![l1ToL2TransactionParamsCall::new((
            U256::from(100),
            U256::from(1_000_000),
            U256::from(800),
            Address::ZERO,
        ))
        .abi_encode()
        .into()];
        if indirect {
            attributes.push(indirectCallCall::new((U256::ZERO,)).abi_encode().into());
        }
        sendMessageCall::new((recipient.into(), Bytes::from_static(b"payload"), attributes))
    }

    #[test]
    fn identifies_direct_and_zero_value_indirect_recipients() {
        for indirect in [false, true] {
            let parsed = decode(&message(indirect).abi_encode()).unwrap();
            assert_eq!(
                parsed.recipient,
                Address::from_word(U256::from(0x12345).into())
            );
            assert_eq!(parsed.is_indirect, indirect);
        }
    }

    #[test]
    fn rejects_missing_duplicate_unsupported_and_truncated_attributes() {
        let mut call = message(false);
        call.attributes.clear();
        assert!(decode(&call.abi_encode()).is_err());
        let mut call = message(false);
        call.attributes.push(call.attributes[0].clone());
        assert!(decode(&call.abi_encode()).is_err());
        for invalid in [Bytes::from_static(b"abcd"), Bytes::from_static(b"a")] {
            let mut call = message(false);
            call.attributes.push(invalid);
            assert!(decode(&call.abi_encode()).is_err());
        }
    }

    #[test]
    fn rejects_factory_dependencies_on_indirect_messages() {
        let mut call = message(true);
        call.attributes
            .push(factoryDepsCall::new((vec![],)).abi_encode().into());
        assert!(decode(&call.abi_encode()).is_err());
    }

    #[test]
    fn rejects_malformed_recipient_and_legacy_selector() {
        let mut call = message(false);
        call.recipient = Bytes::from_static(&[0, 1, 0, 0, 32]);
        assert!(decode(&call.abi_encode()).is_err());
        assert!(!is_send_message(&[0x24, 0xfd, 0x57, 0xfb]));
        assert!(!is_send_message(&[0xd5, 0x24, 0x71, 0xc1]));
    }
}
