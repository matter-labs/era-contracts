// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";

contract initializingSTMOwnerZeroTest is StateTransitionManagerTest {
    function test_InitializingSTMWithGovernorZeroShouldRevert() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 1,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit))
        });

        StateTransitionManagerInitializeData memory stmInitializeDataNoOwner = StateTransitionManagerInitializeData({
            owner: address(0),
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0
        });

        vm.expectRevert(bytes("STM: owner zero"));
        new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeDataNoOwner)
        );
    }
}
