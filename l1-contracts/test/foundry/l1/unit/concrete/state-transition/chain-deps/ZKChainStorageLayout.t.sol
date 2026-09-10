// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "foundry-test/l1/unit/concrete/state-transition/chain-deps/facets/Admin/_Admin_Shared.t.sol";

import {AIRBENDER_PROOF_SYSTEM_DISABLED} from "contracts/common/Config.sol";

/// @notice Pins the byte offsets of the packed tail of `ZKChainStorage`.
/// @dev A diamond upgrade keeps its storage, so appending a member is safe and inserting one into a
/// packed slot is not: it re-points every member after it at a neighbour's bytes and the read still
/// succeeds. `disabledProofSystems` shares slot 68 with small integers, so a chain reading its
/// proof-system mask off the wrong byte settles under a policy nobody chose.
contract ZKChainStorageLayoutTest is AdminTest {
    /// @dev `s` is the first state variable of `ZKChainBase`, so a `ZKChainStorage` member documented
    /// as slot N is at absolute slot N.
    uint256 internal constant PACKED_TAIL_SLOT = 68;

    /// @dev Distinctive so a shift shows up as a wrong value rather than a coincidentally equal one.
    uint64 internal constant GAS_LIMIT = 0x1122334455667788;

    function test_packedTailKeepsItsByteOffsets() public {
        utilsFacet.util_setBaseTokenHasTotalSupply(true);
        utilsFacet.util_setZKsyncOSMaxTxGasLimit(GAS_LIMIT);
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);

        uint256 slot = uint256(vm.load(address(utilsFacet), bytes32(PACKED_TAIL_SLOT)));

        assertEq(slot & 0xff, 1, "baseTokenHasTotalSupply moved off offset 0");
        assertEq(uint64(slot >> 8), GAS_LIMIT, "zksyncOSMaxTxGasLimit moved off offset 1");
        assertEq(
            (slot >> 72) & 0xff,
            AIRBENDER_PROOF_SYSTEM_DISABLED,
            "disabledProofSystems moved off offset 9 -- a chain would read its proof-system mask off another field"
        );
        // The whole word, so that a member inserted anywhere below offset 10 fails here even if the
        // per-offset checks above were updated to follow it, and so that nothing above offset 9 is
        // set — the rest of the slot is still free to append into.
        uint256 expected = 1 | (uint256(GAS_LIMIT) << 8) | (uint256(AIRBENDER_PROOF_SYSTEM_DISABLED) << 72);
        assertEq(slot, expected, "slot 68 is not packed as documented");
    }
}
