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
            0x14c289d746e37aa82ec428491881c4732766492a8bc2e8e3cca2000a40c0ea27,
            0x2f617a7eb9808ad9843d1e080b7cfbf99d61bb1b02076c905f31adb12731bc41
        );
        vk.gate_setup_commitments[1] = PairingsBn254.new_g1(
            0x210b5cc8e6a85d63b65b701b8fb5ad24ff9c41f923432de17fe4ebae04526a8c,
            0x05c10ab17ea731b2b87fb890fa5b10bd3d6832917a616b807a9b640888ebc731
        );
        vk.gate_setup_commitments[2] = PairingsBn254.new_g1(
            0x29d4d14adcfe67a2ac690d6369db6b75e82d8ab3124bc4fa1dd145f41ca6949c,
            0x004f6cd229373f1c1f735ccf49aef6a5c32025bc36c3328596dd0db7d87bef67
        );
        vk.gate_setup_commitments[3] = PairingsBn254.new_g1(
            0x06d15382e8cabae9f98374a9fbdadd424f48e24da7e4c65bf710fd7d7d59a05a,
            0x22e438ad5c51673879ce17073a3d2d29327a97dc3ce61c4f88540e00087695f6
        );
        vk.gate_setup_commitments[4] = PairingsBn254.new_g1(
            0x274a668dfc485cf192d0086f214146d9e02b3040a5a586df344c53c16a87882b,
            0x15f5bb7ad01f162b70fc77c8ea456d67d15a6ce98acbbfd521222810f8ec0a66
        );
        vk.gate_setup_commitments[5] = PairingsBn254.new_g1(
            0x0ba53bf4fb0446927857e33978d02abf45948fc68f4091394ae0827a22cf1e47,
            0x0720d818751ce5b3f11c716e925f60df4679ea90bed516499bdec066f5ff108f
        );
        vk.gate_setup_commitments[6] = PairingsBn254.new_g1(
            0x2e986ba2ea495e5ec6af532980b1dc567f1430bfa82f8de07c12fc097c0e0483,
            0x1555d189f6164e82d78de1b8313c2e923e616b3c8ed0e350c3b61c94516d0b58
        );
        vk.gate_setup_commitments[7] = PairingsBn254.new_g1(
            0x0925959592604ca73c917f9b2e029aa2563c318ddcc5ca29c11badb7b880127b,
            0x2b4a430fcb2fa7d6d67d6c358e01cf0524c7df7e1e56442f65b39bc1a1052367
        );
        // gate selectors
        vk.gate_selectors_commitments[0] = PairingsBn254.new_g1(
            0x28f2a0a95af79ba67e9dd1986bd3190199f661b710a693fc82fb395c126edcbd,
            0x0db75db5de5192d1ba1c24710fc00da16fa8029ac7fe82d855674dcd6d090e05
        );
        vk.gate_selectors_commitments[1] = PairingsBn254.new_g1(
            0x143471a174dfcb2d9cb5ae621e519387bcc93c9dcfc011160b2f5c5f88e32cbe,
            0x2a0194c0224c3d964223a96c4c99e015719bc879125aa0df3f0715d154e71a31
        );
        // permutation
        vk.permutation_commitments[0] = PairingsBn254.new_g1(
            0x1423fa82e00ba22c280181afb12c56eea541933eeb5ec39119b0365b6beab4b9,
            0x0efdcd3423a38f5e2ecf8c7e4fd46f13189f8fed392ad9d8d393e8ba568b06e4
        );
        vk.permutation_commitments[1] = PairingsBn254.new_g1(
            0x0e9b5b12c1090d62224e64aa1696c009aa59a9c3eec458e781fae773e1f4eca5,
            0x1fe3df508c7e9750eb37d9cae5e7437ad11a21fa36530ff821b407b165a79a55
        );
        vk.permutation_commitments[2] = PairingsBn254.new_g1(
            0x25d1a714bd1e258f196e38d6b2826153382c2d04b870d0b7ec250296005129ae,
            0x0883a121b41ca7beaa9de97ecf4417e62aa2eeb9434f24ddacbfed57cbf016a8
        );
        vk.permutation_commitments[3] = PairingsBn254.new_g1(
            0x2f3ede68e854a6b3b14589851cf077a606e2aeb3205c43cc579b7abae39d8f58,
            0x178ccd4b1f78fd79ee248e376b6fc8297d5450900d1e15e8c03e3ed2c171ac8c
        );
        // lookup table commitments
        vk.lookup_selector_commitment = PairingsBn254.new_g1(
            0x1f814e2d87c332e964eeef94ec695eef9d2caaac58b682a43da5107693b06f30,
            0x196d56fb01907e66af9303886fd95328d398e5b2b72906882a9d12c1718e2ee2
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
            0x2f85df2d6249ccbcc11b91727333cc800459de6ee274f29c657c8d56f6f01563,
            0x088e1df178c47116a69c3c8f6d0c5feb530e2a72493694a623b1cceb7d44a76c
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
