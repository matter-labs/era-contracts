// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKIPLiteRegistry} from "../src/ZKIPLiteRegistry.sol";
import {ZKIPBase} from "./helpers/ZKIPBase.sol";
import {InvalidProof, OnlyOwner} from "../src/ZKIPLiteErrors.sol";
import {ChainRegistryHash} from "../src/ChainRegistryHash.sol";
import {REGISTRY_FIELD, registryRoundConstants} from "../src/ChainRegistryConfig.sol";

import {
    KNOWN_ADMISSION_ROOT_TWO,
    KNOWN_ADMISSION_ROOT_FIVE,
    KNOWN_POSEIDON_PAIR_ZERO,
    FOURTH_ZKIP_CHAIN_ID,
    FIFTH_ZKIP_CHAIN_ID,
    RECURSIVE_TEST_CHAINS
} from "./helpers/ZKIPTestConfig.sol";

contract ZKIPRegistryMembershipTest is ZKIPBase {
    /// @dev Known answers from prover/chain_registry.py, also exercised through Noir by the fifth-chain claim.
    function test_admissionRootMatchesPythonAndRejectsDuplicates() public {
        assertEq(reg.chainRegistryRoot(), KNOWN_ADMISSION_ROOT_TWO);
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.ChainEnabled(C, bytes32(0));
        reg.enableChain(C, address(simC), bytes32(0));
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.ChainEnabled(FOURTH_ZKIP_CHAIN_ID, bytes32(0));
        reg.enableChain(FOURTH_ZKIP_CHAIN_ID, alice, bytes32(0));
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.ChainEnabled(FIFTH_ZKIP_CHAIN_ID, bytes32(0));
        reg.enableChain(FIFTH_ZKIP_CHAIN_ID, bob, bytes32(0));
        assertEq(reg.zkipChainCount(), RECURSIVE_TEST_CHAINS);
        assertEq(reg.chainRegistryRoot(), KNOWN_ADMISSION_ROOT_FIVE);
        assertEq(reg.zkipChains(4), FIFTH_ZKIP_CHAIN_ID);
        (address fifthContract, bytes32 fifthState, , uint256 fifthCount, ) = reg.chains(FIFTH_ZKIP_CHAIN_ID);
        assertEq(fifthContract, bob);
        assertEq(fifthState, bytes32(0));
        assertEq(fifthCount, 1);
        uint256 previousRoot = reg.chainRegistryRoot();
        vm.expectRevert(InvalidProof.selector);
        reg.enableChain(A, address(simA), bytes32(0));
        assertEq(reg.chainRegistryRoot(), previousRoot);
        vm.expectRevert(InvalidProof.selector);
        reg.enableChain(0, alice, bytes32(0));
        vm.expectRevert(InvalidProof.selector);
        reg.enableChain(REGISTRY_FIELD, alice, bytes32(0));
        vm.expectRevert(InvalidProof.selector);
        reg.enableChain(C + 3, address(0), bytes32(0));
        vm.prank(alice);
        vm.expectRevert(OnlyOwner.selector);
        reg.enableChain(C + 3, alice, bytes32(0));
        assertEq(reg.chainRegistryRoot(), previousRoot);
        assertEq(reg.zkipChainCount(), RECURSIVE_TEST_CHAINS);
    }

    function test_poseidon2PairKnownAnswer() public pure {
        assertEq(ChainRegistryHash.pair(0, 0, registryRoundConstants()), KNOWN_POSEIDON_PAIR_ZERO);
    }
}
