// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ILegacyChainTypeManager} from "contracts/state-transition/ILegacyChainTypeManager.sol";

/// @notice Freezes the legacy CTM ABI: the ONLY reason `ILegacyChainTypeManager` exists is to
///         encode governance calls against LIVE pre-v32 CTM deployments, so its selectors must
///         match what is deployed — regressions here produce calldata that calls a nonexistent
///         function on mainnet/testnet (caught in review at ec2a81c5b, where an added `registry`
///         field silently moved the selector to 0xb748bd0c).
contract FrozenLegacyAbiTest is Test {
    function test_legacySetChainCreationParamsSelectorIsFrozen() public pure {
        assertEq(
            ILegacyChainTypeManager.setChainCreationParams.selector,
            bytes4(0x9b016b8b),
            "legacy setChainCreationParams selector drifted from the live deployment"
        );
    }
}
