// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

bytes32 constant IMPLEMENTATION_SLOT = 0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC;

/// @notice A mock UUPS-style implementation with `upgradeTo` and a simple `value()` getter.
/// @dev Used for both the correct (zkEVM) and broken (EVM) deployment in tests.
/// When deployed via `new` in zkfoundry, it is zkEVM bytecode (correct).
/// When its EVM bytecode is read from `out/` and deployed via `createEVM`, it becomes
/// an EVM contract that cannot be delegatecalled from a zkEVM proxy (broken).
contract MockUUPSImplementation {
    function upgradeTo(address _implementation) external {
        assembly {
            sstore(IMPLEMENTATION_SLOT, _implementation)
        }
    }

    function value() external pure returns (uint256) {
        return 42;
    }
}
