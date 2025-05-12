// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract initializingCTMOwnerZeroTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_InitializingCTMWithGovernorZeroShouldRevert() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 1,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: bytes("")
        });

        ChainTypeManagerInitializeData memory ctmInitializeDataNoOwner = ChainTypeManagerInitializeData({
            owner: address(0),
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(ChainTypeManager.initialize, ctmInitializeDataNoOwner)
        );
    }
}
