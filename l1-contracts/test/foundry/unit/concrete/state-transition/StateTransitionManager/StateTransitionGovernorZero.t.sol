// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {StateTransitionManager} from "solpp/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData} from "solpp/state-transition/IStateTransitionManager.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";

contract initializingSTMGovernorZeroTest is StateTransitionManagerTest {
    function test_InitializingSTMWithGovernorZeroShouldRevert() public {
        StateTransitionManagerInitializeData memory stmInitializeDataNoGovernor = StateTransitionManagerInitializeData({
            governor: address(0),
            validatorTimelock: validator,
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(""),
            genesisIndexRepeatedStorageChanges: 0,
            genesisBatchCommitment: bytes32(""),
            diamondCut: getDiamondCutData(address(diamondInit)),
            protocolVersion: 0
        });

        vm.expectRevert(bytes("StateTransition: governor zero"));
        TransparentUpgradeableProxy transparentUpgradeableProxyReverting = new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeDataNoGovernor)
        );
    }
}
