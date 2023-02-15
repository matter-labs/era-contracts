


// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "../Constants.sol";

import "../DefaultAccount.sol";

import {SystemContractHelper, ISystemContract} from "../libraries/SystemContractHelper.sol";
import {TestSystemContractHelper} from "./TestSystemContractHelper.sol";

/// @notice An example of a system contract that be used for local testing.
/// @dev It is not used anywhere except for testing
contract TestSystemContract is ISystemContract {
    function testPrecompileCall() external view {
        // Without precompile call
        {
            uint256 gasBefore = gasleft();
            uint256 gasAfter = gasleft();
            require(gasBefore - gasAfter < 10, "Spent too much gas");
        }

        
        {
            uint256 gasBefore = gasleft();
            SystemContractHelper.precompileCall(0, 10000);
            uint256 gasAfter = gasleft();
            require(gasBefore - gasAfter > 10000, "Did not spend enough gas");
            require(gasBefore - gasAfter < 10100, "Spent too much gas");
        }
    }

    function testMimicCallAndValue(
        address whoToMimic,
        uint128 value
    ) external {
        // Note that we don't need to actually have the needed balance to set the `msg.value` for the next call
        SystemContractHelper.setValueForNextFarCall(value);
        SystemContractHelper.mimicCall(
            address(this),
            whoToMimic,
            abi.encodeCall(
                TestSystemContract.saveContext, ()
            ),
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
        (bool success, ) = address(this).call(
            abi.encodeCall(
                TestSystemContract.requireOnlySystem, ()
            )
        );
        require(success, "System contracts can call onlySystemCall methods");

        // Non-system contract accounts should not be able to call it.
        success = SystemContractHelper.rawMimicCall(
            address(this),
            address(MAX_SYSTEM_CONTRACT_ADDRESS + 1),
            abi.encodeCall(
                TestSystemContract.requireOnlySystem, ()
            ),
            false,
            false
        );
        require(!success, "Normal acounts can not call onlySystemCall methods without proper flags");

        success = SystemContractHelper.rawMimicCall(
            address(this),
            address(MAX_SYSTEM_CONTRACT_ADDRESS + 1),
            abi.encodeCall(
                TestSystemContract.requireOnlySystem, ()
            ),
            false,
            true
        );
        require(success, "Normal acounts can not call onlySystemCall methods without proper flags");
    }

    function requireOnlySystem() external onlySystemCall {}

    function testSystemMimicCall() external {
        TestSystemContractHelper.systemMimicCall(
            address(this),
            address(MAX_SYSTEM_CONTRACT_ADDRESS + 1),
            abi.encodeCall(
                TestSystemContract.saveContext, ()
            ),
            false,
            100,
            120
        );

        require(extraAbiData1 == 100, "extraAbiData1 passed incorrectly");
        require(extraAbiData2 == 120, "extraAbiData2 passed incorrectly");
    }
}
