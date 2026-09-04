// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title MockCTMForDiamondInit
/// @notice Test-only stand-in for the ChainTypeManager during `DiamondInit.initialize()`, which
///         reads these values from `msg.sender` (the CTM) while a chain diamond is constructed.
contract MockCTMForDiamondInit {
    // solhint-disable var-name-mixedcase
    address public PERMISSIONLESS_VALIDATOR;
    address public BRIDGE_HUB;
    // solhint-enable var-name-mixedcase
    uint256 public protocolVersion;
    address public validatorTimelockPostV29;
    bytes32 public storedBatchZero;

    constructor(
        address _permissionlessValidator,
        address _bridgehub,
        uint256 _protocolVersion,
        address _validatorTimelock,
        bytes32 _storedBatchZero
    ) {
        PERMISSIONLESS_VALIDATOR = _permissionlessValidator;
        BRIDGE_HUB = _bridgehub;
        protocolVersion = _protocolVersion;
        validatorTimelockPostV29 = _validatorTimelock;
        storedBatchZero = _storedBatchZero;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
