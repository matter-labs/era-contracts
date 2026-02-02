// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {IChainTypeManager, ChainCreationParams, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {GenesisBatchCommitmentZero, GenesisBatchHashZero, GenesisUpgradeZero} from "contracts/common/L1ContractErrors.sol";
import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";

contract ChainTypeManagerInitializeTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    modifier asBridgeHub() {
        vm.stopPrank();
        vm.startPrank(address(bridgehub));

        _;
    }

    function _deployCtmWithParams(ChainCreationParams memory params, bytes4 err) internal {
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: params,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        EraChainTypeManager ctm = new EraChainTypeManager(address(bridgehub), interopCenterAddress, address(0), address(0));

        vm.expectRevert(err);
        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(ctm),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
    }

    function test_RevertWhen_genesisUpgradeIsZero() public asBridgeHub {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(0),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: bytes("")
        });

        _deployCtmWithParams(chainCreationParams, GenesisUpgradeZero.selector);
    }

    function test_RevertWhen_genesBatchHashIsZero() public asBridgeHub {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: bytes("")
        });

        _deployCtmWithParams(chainCreationParams, GenesisBatchHashZero.selector);
    }

    function test_RevertWhen_genesisBatchCommitmentIsZero() public asBridgeHub {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: bytes("")
        });

        _deployCtmWithParams(chainCreationParams, GenesisBatchCommitmentZero.selector);
    }
}
