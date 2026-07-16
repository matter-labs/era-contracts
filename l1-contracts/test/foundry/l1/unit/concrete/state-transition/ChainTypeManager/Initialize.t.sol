// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "contracts/upgrades/registry/ICTMRelease.sol";
import {
    GenesisBatchCommitmentZero,
    GenesisBatchHashZero,
    GenesisUpgradeZero
} from "contracts/common/L1ContractErrors.sol";
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

    /// @dev The CTM validates genesis params in `_setGenesisRegistry` by reading them from the
    ///      genesis registry it is initialized with. We mock the (already-mocked) test registry to
    ///      return the given — deliberately invalid — `genesisParams`, then assert the CTM proxy
    ///      initialization reverts with `err`.
    function _deployCtmExpectingRevert(
        address _genesisUpgrade,
        bytes32 _genesisBatchHash,
        bytes32 _genesisBatchCommitment,
        uint64 _genesisIndexRepeatedStorageChanges,
        bytes4 _err
    ) internal {
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.genesisParams.selector),
            abi.encode(_genesisUpgrade, _genesisBatchHash, _genesisBatchCommitment, _genesisIndexRepeatedStorageChanges)
        );

        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
            protocolVersion: 0,
            verifier: testnetVerifier,
            serverNotifier: serverNotifier
        });

        EraChainTypeManager ctm = new EraChainTypeManager(
            address(bridgehub),
            interopCenterAddress,
            address(0),
            address(0)
        );

        vm.expectRevert(_err);
        new TransparentUpgradeableProxy(
            address(ctm),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
    }

    function test_RevertWhen_genesisUpgradeIsZero() public asBridgeHub {
        _deployCtmExpectingRevert(
            address(0),
            bytes32(uint256(0x01)),
            bytes32(uint256(0x01)),
            0x01,
            GenesisUpgradeZero.selector
        );
    }

    function test_RevertWhen_genesBatchHashIsZero() public asBridgeHub {
        _deployCtmExpectingRevert(
            address(genesisUpgradeContract),
            bytes32(uint256(0)),
            bytes32(uint256(0x01)),
            0x01,
            GenesisBatchHashZero.selector
        );
    }

    function test_RevertWhen_genesisBatchCommitmentIsZero() public asBridgeHub {
        _deployCtmExpectingRevert(
            address(genesisUpgradeContract),
            bytes32(uint256(0x01)),
            bytes32(uint256(0)),
            0x01,
            GenesisBatchCommitmentZero.selector
        );
    }
}
