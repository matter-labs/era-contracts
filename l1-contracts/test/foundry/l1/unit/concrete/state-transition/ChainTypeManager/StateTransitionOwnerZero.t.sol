// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";

import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract initializingCTMOwnerZeroTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_InitializingCTMWithGovernorZeroShouldRevert() public {
        ChainTypeManagerInitializeData memory ctmInitializeDataNoOwner = ChainTypeManagerInitializeData({
            owner: address(0),
            validatorTimelock: validator,
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
            protocolVersion: 0,
            verifier: testnetVerifier,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeDataNoOwner)
        );
    }
}
