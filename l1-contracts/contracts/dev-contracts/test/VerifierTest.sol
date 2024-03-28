// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Verifier} from "../../state-transition/Verifier.sol";

/// @author Matter Labs
contract VerifierTest is Verifier {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function _loadVerificationKey() internal pure override {
        assembly {
            // gate setup commitments
            mstore(VK_GATE_SETUP_0_X_SLOT, 0x046e45fd137982bd0f6cf731b4650d2d520e8d675827744e1edf1308583599bb)
            mstore(VK_GATE_SETUP_0_Y_SLOT, 0x177f14d16b716d4298be5e07b83add3fb61ff1ee08dce19f9a54fa8f04937f7e)
            mstore(VK_GATE_SETUP_1_X_SLOT, 0x169ad5156d25b56f7b67ea6382f88b845ed5bae5b91aacfe51d8f0716afff2fb)
            mstore(VK_GATE_SETUP_1_Y_SLOT, 0x2406e3268e4d5fa672142998ecf834034638a4a6f8b5e90205552c6aa1dde163)
            mstore(VK_GATE_SETUP_2_X_SLOT, 0x05fd0ce0fdc590938d29c738c8dc956b32ca8e69c3babfbb49dc1c13a6d9a8d4)
            mstore(VK_GATE_SETUP_2_Y_SLOT, 0x0a27dac323a04dd319d9805be879875c95063d0a55c96214cd45c913fba84460)
            mstore(VK_GATE_SETUP_3_X_SLOT, 0x0d58a2a86b208a4976beb9bfd918514d448656e0ee66175eb344a4a17bba99f8)
            mstore(VK_GATE_SETUP_3_Y_SLOT, 0x215fa609a1a425b84c9dc218c6cf999596d9eba6d35597ad7aaf2d077a6616ed)
            mstore(VK_GATE_SETUP_4_X_SLOT, 0x1a26e6deccf91174ab13613363eb4939680828f0c6031f5039f9e6f264afa68c)
            mstore(VK_GATE_SETUP_4_Y_SLOT, 0x1f5b2d6bffac1839edfd02cd0e41acc411f0ecbf6c5c4b1da0e12b68b99cb25d)
            mstore(VK_GATE_SETUP_5_X_SLOT, 0x09b71be2e8a45dcbe7654cf369c4f1f2e7eab4b97869a469fb7a149d989f7226)
            mstore(VK_GATE_SETUP_5_Y_SLOT, 0x197e1e2cefbd4f99558b89ca875e01fec0f14f05e5128bd869c87d6bf2f307fa)
            mstore(VK_GATE_SETUP_6_X_SLOT, 0x0d7cef745da686fd44760403d452d72be504bb41b0a7f4fbe973a07558893871)
            mstore(VK_GATE_SETUP_6_Y_SLOT, 0x1e9a863307cdfd3fdcf119f72279ddfda08b6f23c3672e8378dbb9d548734c29)
            mstore(VK_GATE_SETUP_7_X_SLOT, 0x16af3f5d978446fdb37d84f5cf12e59f5c1088bde23f8260c0bb6792c5f78e99)
            mstore(VK_GATE_SETUP_7_Y_SLOT, 0x167d3aeee50c0e53fd1e8a33941a806a34cfae5dc8b66578486e5d7207b5d546)

            // gate selectors commitments
            mstore(VK_GATE_SELECTORS_0_X_SLOT, 0x1addc8e154c74bed403dc19558096ce22f1ceb2c656a2a5e85e56d2be6580ed1)
            mstore(VK_GATE_SELECTORS_0_Y_SLOT, 0x1420d38f0ef206828efc36d0f5ad2b4d85fe768097f358fc671b7b3ec0239234)
            mstore(VK_GATE_SELECTORS_1_X_SLOT, 0x2d5c06d0c8aa6a3520b8351f82341affcbb1a0bf27bceb9bab175e3e1d38cf47)
            mstore(VK_GATE_SELECTORS_1_Y_SLOT, 0x0ff8d923a0374308147f6dd4fc513f6d0640f5df699f4836825ef460df3f8d6a)

            // permutation commitments
            mstore(VK_PERMUTATION_0_X_SLOT, 0x1de8943a8f67d9f6fcbda10a1f37a82de9e9ffd0a0102ea5ce0ce6dd13b4031b)
            mstore(VK_PERMUTATION_0_Y_SLOT, 0x1e04b0824853ab5d7c3412a217a1c5b88a2b4011be7e7e849485be8ed7332e41)
            mstore(VK_PERMUTATION_1_X_SLOT, 0x2aa1817b9cc40b6cc7a7b3f832f3267580f9fb8e539666c00541e1a77e34a3da)
            mstore(VK_PERMUTATION_1_Y_SLOT, 0x0edb3cde226205b01212fc1861303c49ef3ff66f060b5833dc9a3f661ef31dd9)
            mstore(VK_PERMUTATION_2_X_SLOT, 0x13f5ae93c8eccc1455a0095302923442d4b0b3c8233d66ded99ffcf2ad641c27)
            mstore(VK_PERMUTATION_2_Y_SLOT, 0x2dd42d42ccdea8b1901435ace12bc9e52c7dbbeb409d20c517ba942ed0cc7519)
            mstore(VK_PERMUTATION_3_X_SLOT, 0x1a15a70a016be11af71e46e9c8a8d31ece32a7e657ae90356dd9535e6566645f)
            mstore(VK_PERMUTATION_3_Y_SLOT, 0x0381d23e115521c6fc233c5346f79a6777bfa8871b7ee623d990cdcb5d8c3ce1)

            // lookup tables commitments
            mstore(VK_LOOKUP_TABLE_0_X_SLOT, 0x2c513ed74d9d57a5ec901e074032741036353a2c4513422e96e7b53b302d765b)
            mstore(VK_LOOKUP_TABLE_0_Y_SLOT, 0x04dd964427e430f16004076d708c0cb21e225056cc1d57418cfbd3d472981468)
            mstore(VK_LOOKUP_TABLE_1_X_SLOT, 0x1ea83e5e65c6f8068f4677e2911678cf329b28259642a32db1f14b8347828aac)
            mstore(VK_LOOKUP_TABLE_1_Y_SLOT, 0x1d22bc884a2da4962a893ba8de13f57aaeb785ed52c5e686994839cab8f7475d)
            mstore(VK_LOOKUP_TABLE_2_X_SLOT, 0x0b2e7212d0d9cff26d0bdf3d79b2cac029a25dfeb1cafdf49e2349d7db348d89)
            mstore(VK_LOOKUP_TABLE_2_Y_SLOT, 0x1301f9b252419ea240eb67fda720ca0b16d92364027285f95e9b1349490fa283)
            mstore(VK_LOOKUP_TABLE_3_X_SLOT, 0x02f7b99fdfa5b418548c2d777785820e02383cfc87e7085e280a375a358153bf)
            mstore(VK_LOOKUP_TABLE_3_Y_SLOT, 0x09d004fe08dc4d19c382df36fad22ef676185663543703e6a4b40203e50fd8a6)

            // lookup selector commitment
            mstore(VK_LOOKUP_SELECTOR_X_SLOT, 0x1641f5d312e6f62720b1e6cd1d1be5bc0e69d10d20a12dc97ff04e2107e10ccc)
            mstore(VK_LOOKUP_SELECTOR_Y_SLOT, 0x277f435d376acc3261ef9d5748e6705086214daf46d04edc80fbd657f8d9e73d)

            // table type commitment
            mstore(VK_LOOKUP_TABLE_TYPE_X_SLOT, 0x1b5f1cfddd6713cf25d9e6850a1b3fe80d6ef7fe2c67248f25362d5f9b31893c)
            mstore(VK_LOOKUP_TABLE_TYPE_Y_SLOT, 0x0945076de03a0d240067e5f02b8fc11eaa589df3343542576eb59fdb3ecb57e0)

            // flag for using recursive part
            mstore(VK_RECURSIVE_FLAG_SLOT, 0)
        }
    }
}
