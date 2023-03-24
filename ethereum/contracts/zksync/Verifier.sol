// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./Plonk4VerifierWithAccessToDNext.sol";
import "../common/libraries/UncheckedMath.sol";

contract Verifier is Plonk4VerifierWithAccessToDNext {
    using UncheckedMath for uint256;

    function get_verification_key() public pure returns (VerificationKey memory vk) {
        vk.num_inputs = 1;
        vk.domain_size = 67108864;
        vk.omega = PairingsBn254.new_fr(0x1dba8b5bdd64ef6ce29a9039aca3c0e524395c43b9227b96c75090cc6cc7ec97);
        // coefficients
        vk.gate_setup_commitments[0] = PairingsBn254.new_g1(
            0x08fa9d6f0dd6ac1cbeb94ae20fe7a23df05cb1095df66fb561190e615a4037ef,
            0x196dcc8692fe322d21375920559944c12ba7b1ba8b732344cf4ba2e3aa0fc8b4
        );
        vk.gate_setup_commitments[1] = PairingsBn254.new_g1(
            0x0074aaf5d97bd57551311a8b3e4aa7840bc55896502020b2f43ad6a98d81a443,
            0x2d275a3ad153dc9d89ebb9c9b6a0afd2dde82470554e9738d905c328fbb4c8bc
        );
        vk.gate_setup_commitments[2] = PairingsBn254.new_g1(
            0x287f1975a9aeaef5d2bb0767b5ef538f76e82f7da01c0cb6db8c6f920818ec4f,
            0x2fff6f53594129f794a7731d963d27e72f385c5c6d8e08829e6f66a9d29a12ea
        );
        vk.gate_setup_commitments[3] = PairingsBn254.new_g1(
            0x038809fa3d4b7320d43e023454194f0a7878baa7e73a295d2d105260f1c34cbc,
            0x25418b1105cf45b2a3da6c349bab1d9caaf145eaf24d1e8fb92c11654c000781
        );
        vk.gate_setup_commitments[4] = PairingsBn254.new_g1(
            0x0561cafd527ac3f0bc550db77d87cd1c63938f7ec051e62ebf84a5bbe07f9840,
            0x28f87201b4cbe19f1517a1c29ca6d6cb074502ccfed4c31c8931c6992c3eea43
        );
        vk.gate_setup_commitments[5] = PairingsBn254.new_g1(
            0x27e0af572bac6e36d31c33808cb44c0ef8ceee5e2850e916fb01f3747db72491,
            0x1da20087ba61c59366b21e31e4ac6889d357cf11bf16b94d875f94f41525c427
        );
        vk.gate_setup_commitments[6] = PairingsBn254.new_g1(
            0x2c2bcafea8f93d07f96874f470985a8d272c09c8ed49373f36497ee80bd8da17,
            0x299276cf6dca1a7e3780f6276c5d067403f6e024e83e0cc1ab4c5f7252b7f653
        );
        vk.gate_setup_commitments[7] = PairingsBn254.new_g1(
            0x0ba9d4a53e050da25b8410045b634f1ca065ff74acd35bab1a72bf1f20047ef3,
            0x1f1eefc8b0507a08f852f554bd7abcbd506e52de390ca127477a678d212abfe5
        );
        // gate selectors
        vk.gate_selectors_commitments[0] = PairingsBn254.new_g1(
            0x1c6b68d9920620012d85a4850dad9bd6d03ae8bbc7a08b827199e85dba1ef2b1,
            0x0f6380560d1b585628ed259289cec19d3a7c70c60e66bbfebfcb70c8c312d91e
        );
        vk.gate_selectors_commitments[1] = PairingsBn254.new_g1(
            0x0dfead780e5067181aae631ff734a33fca302773472997daca58ba49dbd20dcc,
            0x00f13fa6e356f525d2fd1c533acf2858c0d2b9f0a9b3180f94e1543929c75073
        );
        // permutation
        vk.permutation_commitments[0] = PairingsBn254.new_g1(
            0x1df0747c787934650d99c5696f9273088ad07ec3e0825c9d39685a9b9978ebed,
            0x2ace2a277becbc69af4e89518eb50960a733d9d71354845ea43d2e65c8e0e4cb
        );
        vk.permutation_commitments[1] = PairingsBn254.new_g1(
            0x06598c8236a5f5045cd7444dc87f3e1f66f99bf01251e13be4dc0ab1f7f1af4b,
            0x14ca234fe9b3bb1e5517fc60d6b90f8ad44b0899a2d4f71a64c9640b3142ce8b
        );
        vk.permutation_commitments[2] = PairingsBn254.new_g1(
            0x01889e2c684caefde60471748f4259196ecf4209a735ccdf7b1816f05bafa50a,
            0x092d287a080bfe2fd40ad392ff290e462cd0e347b8fd9d05b90af234ce77a11b
        );
        vk.permutation_commitments[3] = PairingsBn254.new_g1(
            0x0dd98eeb5bc12c221da969398b67750a8774dbdd37a78da52367f9fc0e566d5c,
            0x06750ceb40c9fb87fc424df9599340938b7552b759914a90cb0e41d3915c945b
        );
        // lookup table commitments
        vk.lookup_selector_commitment = PairingsBn254.new_g1(
            0x2f491c662ae53ceb358f57a868dc00b89befa853bd9a449127ea2d46820995bd,
            0x231fe6538634ff8b6fa21ca248fb15e7f43d82eb0bfa705490d24ddb3e3cad77
        );
        vk.lookup_tables_commitments[0] = PairingsBn254.new_g1(
            0x0ebe0de4a2f39df3b903da484c1641ffdffb77ff87ce4f9508c548659eb22d3c,
            0x12a3209440242d5662729558f1017ed9dcc08fe49a99554dd45f5f15da5e4e0b
        );
        vk.lookup_tables_commitments[1] = PairingsBn254.new_g1(
            0x1b7d54f8065ca63bed0bfbb9280a1011b886d07e0c0a26a66ecc96af68c53bf9,
            0x2c51121fff5b8f58c302f03c74e0cb176ae5a1d1730dec4696eb9cce3fe284ca
        );
        vk.lookup_tables_commitments[2] = PairingsBn254.new_g1(
            0x0138733c5faa9db6d4b8df9748081e38405999e511fb22d40f77cf3aef293c44,
            0x269bee1c1ac28053238f7fe789f1ea2e481742d6d16ae78ed81e87c254af0765
        );
        vk.lookup_tables_commitments[3] = PairingsBn254.new_g1(
            0x1b1be7279d59445065a95f01f16686adfa798ec4f1e6845ffcec9b837e88372e,
            0x057c90cb96d8259238ed86b05f629efd55f472a721efeeb56926e979433e6c0e
        );
        vk.lookup_table_type_commitment = PairingsBn254.new_g1(
            0x12cd873a6f18a4a590a846d9ebf61565197edf457efd26bc408eb61b72f37b59,
            0x19890cbdac892682e7a5910ca6c238c082130e1c71f33d0c9c901153377770d1
        );
        // non residues
        vk.non_residues[0] = PairingsBn254.new_fr(0x0000000000000000000000000000000000000000000000000000000000000005);
        vk.non_residues[1] = PairingsBn254.new_fr(0x0000000000000000000000000000000000000000000000000000000000000007);
        vk.non_residues[2] = PairingsBn254.new_fr(0x000000000000000000000000000000000000000000000000000000000000000a);

        // g2 elements
        vk.g2_elements[0] = PairingsBn254.new_g2(
            [
                0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2,
                0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed
            ],
            [
                0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b,
                0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa
            ]
        );
        vk.g2_elements[1] = PairingsBn254.new_g2(
            [
                0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1,
                0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0
            ],
            [
                0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4,
                0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55
            ]
        );
    }

    function deserialize_proof(uint256[] calldata public_inputs, uint256[] calldata serialized_proof)
        internal
        pure
        returns (Proof memory proof)
    {
        require(serialized_proof.length == 44);
        proof.input_values = new uint256[](public_inputs.length);
        for (uint256 i = 0; i < public_inputs.length; i = i.uncheckedInc()) {
            proof.input_values[i] = public_inputs[i];
        }

        uint256 j;
        for (uint256 i = 0; i < STATE_WIDTH; i = i.uncheckedInc()) {
            proof.state_polys_commitments[i] = PairingsBn254.new_g1_checked(
                serialized_proof[j],
                serialized_proof[j.uncheckedInc()]
            );

            j = j.uncheckedAdd(2);
        }
        proof.copy_permutation_grand_product_commitment = PairingsBn254.new_g1_checked(
            serialized_proof[j],
            serialized_proof[j.uncheckedInc()]
        );
        j = j.uncheckedAdd(2);

        proof.lookup_s_poly_commitment = PairingsBn254.new_g1_checked(
            serialized_proof[j],
            serialized_proof[j.uncheckedInc()]
        );
        j = j.uncheckedAdd(2);

        proof.lookup_grand_product_commitment = PairingsBn254.new_g1_checked(
            serialized_proof[j],
            serialized_proof[j.uncheckedInc()]
        );
        j = j.uncheckedAdd(2);
        for (uint256 i = 0; i < proof.quotient_poly_parts_commitments.length; i = i.uncheckedInc()) {
            proof.quotient_poly_parts_commitments[i] = PairingsBn254.new_g1_checked(
                serialized_proof[j],
                serialized_proof[j.uncheckedInc()]
            );
            j = j.uncheckedAdd(2);
        }

        for (uint256 i = 0; i < proof.state_polys_openings_at_z.length; i = i.uncheckedInc()) {
            proof.state_polys_openings_at_z[i] = PairingsBn254.new_fr(serialized_proof[j]);

            j = j.uncheckedInc();
        }

        for (uint256 i = 0; i < proof.state_polys_openings_at_z_omega.length; i = i.uncheckedInc()) {
            proof.state_polys_openings_at_z_omega[i] = PairingsBn254.new_fr(serialized_proof[j]);

            j = j.uncheckedInc();
        }
        for (uint256 i = 0; i < proof.gate_selectors_openings_at_z.length; i = i.uncheckedInc()) {
            proof.gate_selectors_openings_at_z[i] = PairingsBn254.new_fr(serialized_proof[j]);

            j = j.uncheckedInc();
        }
        for (uint256 i = 0; i < proof.copy_permutation_polys_openings_at_z.length; i = i.uncheckedInc()) {
            proof.copy_permutation_polys_openings_at_z[i] = PairingsBn254.new_fr(serialized_proof[j]);

            j = j.uncheckedInc();
        }
        proof.copy_permutation_grand_product_opening_at_z_omega = PairingsBn254.new_fr(serialized_proof[j]);

        j = j.uncheckedInc();
        proof.lookup_s_poly_opening_at_z_omega = PairingsBn254.new_fr(serialized_proof[j]);
        j = j.uncheckedInc();
        proof.lookup_grand_product_opening_at_z_omega = PairingsBn254.new_fr(serialized_proof[j]);

        j = j.uncheckedInc();
        proof.lookup_t_poly_opening_at_z = PairingsBn254.new_fr(serialized_proof[j]);

        j = j.uncheckedInc();
        proof.lookup_t_poly_opening_at_z_omega = PairingsBn254.new_fr(serialized_proof[j]);
        j = j.uncheckedInc();
        proof.lookup_selector_poly_opening_at_z = PairingsBn254.new_fr(serialized_proof[j]);
        j = j.uncheckedInc();
        proof.lookup_table_type_poly_opening_at_z = PairingsBn254.new_fr(serialized_proof[j]);
        j = j.uncheckedInc();
        proof.quotient_poly_opening_at_z = PairingsBn254.new_fr(serialized_proof[j]);
        j = j.uncheckedInc();
        proof.linearization_poly_opening_at_z = PairingsBn254.new_fr(serialized_proof[j]);
        j = j.uncheckedInc();
        proof.opening_proof_at_z = PairingsBn254.new_g1_checked(
            serialized_proof[j],
            serialized_proof[j.uncheckedInc()]
        );
        j = j.uncheckedAdd(2);
        proof.opening_proof_at_z_omega = PairingsBn254.new_g1_checked(
            serialized_proof[j],
            serialized_proof[j.uncheckedInc()]
        );
    }

    function verify_serialized_proof(uint256[] calldata public_inputs, uint256[] calldata serialized_proof)
        public
        view
        returns (bool)
    {
        VerificationKey memory vk = get_verification_key();
        require(vk.num_inputs == public_inputs.length);

        Proof memory proof = deserialize_proof(public_inputs, serialized_proof);

        return verify(proof, vk);
    }
}
