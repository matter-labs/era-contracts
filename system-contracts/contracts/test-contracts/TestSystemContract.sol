// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../Constants.sol";

import "../DefaultAccount.sol";

import "../libraries/EfficientCall.sol";
import "../interfaces/ISystemContract.sol";
import {SystemContractHelper} from "../libraries/SystemContractHelper.sol";
import {TestSystemContractHelper} from "./TestSystemContractHelper.sol";

/// @notice An example of a system contract that be used for local testing.
/// @dev It is not used anywhere except for testing
contract TestSystemContract is ISystemContract {
    modifier onlySelf() {
        require(msg.sender == address(this));
        _;
    }

    function testPrecompileCall() external view {
        // Without precompile call
        {
            uint256 gasBefore = gasleft();
            uint256 gasAfter = gasleft();
            require(gasBefore - gasAfter < 10, "Spent too much gas");
        }

        {
            uint256 gasBefore = gasleft();
            SystemContractHelper.unsafePrecompileCall(0, 10000);
            uint256 gasAfter = gasleft();
            require(gasBefore - gasAfter > 10000, "Did not spend enough gas");
            require(gasBefore - gasAfter < 10100, "Spent too much gas");
        }
    }

    function testMimicCallAndValue(address whoToMimic, uint128 value) external {
        // Note that we don't need to actually have the needed balance to set the `msg.value` for the next call
        SystemContractHelper.setValueForNextFarCall(value);
        this.performMimicCall(
            address(this),
            whoToMimic,
            abi.encodeCall(TestSystemContract.saveContext, ()),
            false,
            false
        );

        require(latestMsgSender == whoToMimic, "mimicCall does not work");
        require(latestMsgValue == value, "setValueForNextFarCall does not work");
    }

    address public latestMsgSender;
    uint128 public latestMsgValue;
    uint256 public extraAbiData1;
    uint256 public extraAbiData2;

    function saveContext() external payable {
        latestMsgSender = msg.sender;
        latestMsgValue = uint128(msg.value);
        extraAbiData1 = SystemContractHelper.getExtraAbiData(0);
        extraAbiData2 = SystemContractHelper.getExtraAbiData(1);
    }

    function testOnlySystemModifier() external {
        // Firstly, system contracts should be able to call it
        (bool success, ) = address(this).call(abi.encodeCall(TestSystemContract.requireOnlySystem, ()));
        require(success, "System contracts can call onlySystemCall methods");

        // Non-system contract accounts should not be able to call it.
        success = this.performRawMimicCall(
            address(this),
            address(MAX_SYSTEM_CONTRACT_ADDRESS + 1),
            abi.encodeCall(TestSystemContract.requireOnlySystem, ()),
            false,
            false
        );
        require(!success, "Normal acounts cannot call onlySystemCall methods without proper flags");

        success = this.performRawMimicCall(
            address(this),
            address(MAX_SYSTEM_CONTRACT_ADDRESS + 1),
            abi.encodeCall(TestSystemContract.requireOnlySystem, ()),
            false,
            true
        );
        require(success, "Normal acounts cannot call onlySystemCall methods without proper flags");
    }

    function requireOnlySystem() external onlySystemCall {}

    function testSystemMimicCall() external {
        this.performSystemMimicCall(
            address(this),
            address(MAX_SYSTEM_CONTRACT_ADDRESS + 1),
            abi.encodeCall(TestSystemContract.saveContext, ()),
            false,
            100,
            120
        );

        require(extraAbiData1 == 100, "extraAbiData1 passed incorrectly");
        require(extraAbiData2 == 120, "extraAbiData2 passed incorrectly");
    }

    function performMimicCall(
        address to,
        address whoToMimic,
        bytes calldata data,
        bool isConstructor,
        bool isSystem
    ) external onlySelf returns (bytes memory) {
        return EfficientCall.mimicCall(uint32(gasleft()), to, data, whoToMimic, isConstructor, isSystem);
    }

    function performRawMimicCall(
        address to,
        address whoToMimic,
        bytes calldata data,
        bool isConstructor,
        bool isSystem
    ) external onlySelf returns (bool) {
        return EfficientCall.rawMimicCall(uint32(gasleft()), to, data, whoToMimic, isConstructor, isSystem);
    }

    function performSystemMimicCall(
        address to,
        address whoToMimic,
        bytes calldata data,
        bool isConstructor,
        uint256 extraAbiParam1,
        uint256 extraAbiParam2
    ) external onlySelf {
        TestSystemContractHelper.systemMimicCall(to, whoToMimic, data, isConstructor, extraAbiParam1, extraAbiParam2);
    }
}
