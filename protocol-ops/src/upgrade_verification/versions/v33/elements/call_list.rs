use alloy::{hex, sol, sol_types::SolValue};

sol! {
    #[derive(Debug)]
    struct UpgradeProposal {
        Call[] calls;
        address executor;
        bytes32 salt;
    }

    #[derive(Debug)]
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    #[derive(Debug)]
    struct CallList {
        Call[] elems;
    }
}

impl CallList {
    pub fn parse(hex_data: &str) -> Self {
        CallList::abi_decode_sequence(&hex::decode(hex_data).expect("Invalid hex"))
            .expect("Decoding calls failed")
    }
}
