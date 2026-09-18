// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "foundry-test/l1/unit/concrete/state-transition/chain-deps/facets/Admin/_Admin_Shared.t.sol";

import {AIRBENDER_PROOF_SYSTEM_MASK} from "contracts/common/Config.sol";

/// @notice `disabledProofSystems` shares slot 68 with `baseTokenHasTotalSupply` and `zksyncOSMaxTxGasLimit`;
/// a member inserted before it would silently shift the mask.
contract ZKChainStorageLayoutTest is AdminTest {
    uint256 internal constant PACKED_TAIL_SLOT = 68;
    uint64 internal constant GAS_LIMIT = 0x1122334455667788;

    function test_packedTailKeepsItsByteOffsets() public {
        utilsFacet.util_setBaseTokenHasTotalSupply(true);
        utilsFacet.util_setZKsyncOSMaxTxGasLimit(GAS_LIMIT);
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);

        uint256 slot = uint256(vm.load(address(utilsFacet), bytes32(PACKED_TAIL_SLOT)));
        uint256 expected = 1 | (uint256(GAS_LIMIT) << 8) | (uint256(AIRBENDER_PROOF_SYSTEM_MASK) << 72);
        assertEq(slot, expected, "slot 68 is not packed as documented");
    }
}
