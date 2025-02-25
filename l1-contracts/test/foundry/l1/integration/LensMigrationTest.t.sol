// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Test} from "forge-std/Test.sol";
import {TransitionaryOwner} from "../../../../contracts/governance/TransitionaryOwner.sol";
import {Migrator} from "../../../../contracts/upgrades/Migrator.sol";
import {LensScript, Config} from "../../../../deploy-scripts/LensScript.s.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {IGovernance} from "../../../../contracts/governance/IGovernance.sol";
import {Bridgehub} from "../../../../contracts/bridgehub/Bridgehub.sol";
import {IStateTransitionManager} from "../../../../contracts/state-transition/IStateTransitionManager.sol";
import {IGetters} from "../../../../contracts/state-transition/chain-interfaces/IGetters.sol";

contract LensMigrationTest is Test {
    LensScript public lensScript;
    function setUp() public {
        vm.startBroadcast();

        vm.stopBroadcast();

        lensScript = new LensScript();

        lensScript.run();
    }

    function test_lens_migration() public {
        address tempGovernance = 0xF21477B2a64c051AD1AC1d14f8c0f31db1eEF422;
        address tempGovernanceOwner = 0xEADb3890e0c3aef13e0B1D1CCFC5218395BC27a6;

        (
            uint256 lensChainId,
            address lensDiamondProxy,
            address baseToken,
            ,
            address tempBridgehub,
            address tempStateTransitionManager,
            address tempValidatorTimelock,
            address tempL1SharedBridge,
            ,
            address newStateTransitionManager,
            address newBridgehub,
            ,
            address newValidatorTimelock,
            address newVerifier,
            address governance
        ) = lensScript.config();

        vm.startPrank(tempGovernanceOwner);

        console.log("Transferring ownership of tempValidatorTimelock to transitionaryOwner");
        (bool success, ) = tempValidatorTimelock.call(lensScript.vtOwnershipCall());

        console.log("Sending scheduleTransparent call to tempGovernance");
        (success, ) = tempGovernance.call(lensScript.tempEcoScheduleOperation());

        if (!success) {
            revert("Failed to send scheduleTransparent call to tempGovernance");
        }

        console.log("Sending execute operation to tempGovernance");
        (success, ) = tempGovernance.call(lensScript.tempEcoExecuteOperation());

        if (!success) {
            revert("Failed to send execute operation to tempGovernance");
        }

        vm.stopPrank();

        address bhAdmin = Bridgehub(newBridgehub).admin();

        console.log("Registering token");
        vm.startPrank(bhAdmin);
        Bridgehub(newBridgehub).addToken(baseToken);
        vm.stopPrank();

        vm.startPrank(governance);

        IGovernance.Call[] memory calls = lensScript.govCalls();

        for (uint256 i = 0; i < calls.length; ++i) {
            (success, ) = calls[i].target.call(calls[i].data);
            if (!success) {
                revert("Failed to send call to target");
            }
        }

        vm.stopPrank();

        // Validate that the migration is successful
        assertEq(Bridgehub(newBridgehub).tokenIsRegistered(baseToken), true);
        assertEq(IStateTransitionManager(newStateTransitionManager).getHyperchain(lensChainId), lensDiamondProxy);
        assertEq(Ownable2Step(tempValidatorTimelock).owner(), governance);
        assertEq(Ownable2Step(tempBridgehub).owner(), governance);
        assertEq(Ownable2Step(tempStateTransitionManager).owner(), governance);
        assertEq(Ownable2Step(tempL1SharedBridge).owner(), governance);
        assertEq(IGetters(lensDiamondProxy).isValidator(tempValidatorTimelock), false);
        assertEq(IGetters(lensDiamondProxy).isValidator(newValidatorTimelock), true);
        assertEq(IGetters(lensDiamondProxy).getVerifier(), newVerifier);
        assertEq(IGetters(lensDiamondProxy).getBridgehub(), newBridgehub);
        assertEq(IGetters(lensDiamondProxy).getStateTransitionManager(), newStateTransitionManager);
        assertEq(IGetters(lensDiamondProxy).getBaseToken(), baseToken);
        assertEq(IGetters(lensDiamondProxy).getBaseTokenBridge(), address(Bridgehub(newBridgehub).sharedBridge()));
    }
}
