// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {GenesisUpgradeZero, GenesisBatchHashZero, GenesisIndexStorageZero, GenesisBatchCommitmentZero} from "contracts/common/L1ContractErrors.sol";
import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";

contract StateTransitionManagerInitializeTest is StateTransitionManagerTest {
    function setUp() public {
        deploy();
    }

    modifier asBridgeHub() {
        vm.stopPrank();
        vm.startPrank(address(bridgehub));

        _;
    }

    function _deployStmWithParams(ChainCreationParams memory params, bytes4 err) internal {
        StateTransitionManagerInitializeData memory stmInitializeData = StateTransitionManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: params,
            protocolVersion: 0
        });

        StateTransitionManager stm = new StateTransitionManager(address(bridgehub), MAX_NUMBER_OF_HYPERCHAINS);

        vm.expectRevert(err);
        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(stm),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeData)
        );

        StateTransitionManager(address(transparentUpgradeableProxy));
    }

    function test_RevertWhen_genesisUpgradeIsZero() public asBridgeHub {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(0),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit))
        });

        _deployStmWithParams(chainCreationParams, GenesisUpgradeZero.selector);
    }

    function test_RevertWhen_genesBatchHashIsZero() public asBridgeHub {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit))
        });

        _deployStmWithParams(chainCreationParams, GenesisBatchHashZero.selector);
    }

    function test_RevertWhen_genesisIndexRepeatedStorageChangesIsZero() public asBridgeHub {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit))
        });

        _deployStmWithParams(chainCreationParams, GenesisIndexStorageZero.selector);
    }

    function test_RevertWhen_genesisBatchCommitmentIsZero() public asBridgeHub {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0)),
            diamondCut: getDiamondCutData(address(diamondInit))
        });

        _deployStmWithParams(chainCreationParams, GenesisBatchCommitmentZero.selector);
    }
}
