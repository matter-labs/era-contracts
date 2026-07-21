// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ICTMRelease} from "contracts/upgrades/registry/ICTMRelease.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

/// @notice From v32 the CTM no longer stores chain-creation params directly; it stores a pointer
///         to a genesis release and derives all genesis data from it. This exercises
///         `setCurrentRelease`: repointing the CTM at a new release updates the values it
///         serves (`l1GenesisUpgrade`, `storedBatchZero`, `currentRelease`).
contract SetGenesisRegistryTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    /// @dev Mocks a fresh release returning the given genesis params, so the CTM can be repointed
    ///      at it: `genesisParams` (read by the `l1GenesisUpgrade`/`storedBatchZero` getters), the
    ///      VM-identity surface, and the manifest-hash + factory attestation `setCurrentRelease`
    ///      requires for release provenance.
    function _mockRegistry(
        address _registry,
        address _genesisUpgrade,
        bytes32 _genesisBatchHash,
        bytes32 _genesisBatchCommitment,
        uint64 _genesisIndexRepeatedStorageChanges
    ) internal {
        vm.mockCall(
            _registry,
            abi.encodeWithSelector(ICTMRelease.genesisParams.selector),
            abi.encode(_genesisUpgrade, _genesisBatchHash, _genesisBatchCommitment, _genesisIndexRepeatedStorageChanges)
        );
        vm.mockCall(_registry, abi.encodeWithSelector(ICTMRelease.validate.selector), bytes(""));
        // VM identity is single-sourced from the release's DiamondInit; the mocked registry's
        // diamondInit placeholder is the registry itself, so mock the flag there.
        vm.mockCall(_registry, abi.encodeWithSelector(ICTMRelease.diamondInit.selector), abi.encode(_registry));
        vm.mockCall(_registry, abi.encodeWithSelector(IDiamondInit.IS_ZKSYNC_OS.selector), abi.encode(false));
        // From v32 the CTM enforces release provenance via its canonical (mocked) factory: give the
        // release a manifest hash and attest it on `TEST_RELEASE_FACTORY` so a repoint is accepted
        // (the shared fixture's generic mock attests only the genesis release).
        bytes32 manifestHash = keccak256(abi.encode(_registry));
        vm.mockCall(_registry, abi.encodeWithSelector(ICTMRelease.manifestHash.selector), abi.encode(manifestHash));
        vm.mockCall(
            Utils.TEST_RELEASE_FACTORY,
            abi.encodeWithSelector(bytes4(keccak256("deployedFor(bytes32)")), manifestHash),
            abi.encode(_registry)
        );
    }

    function test_SettingGenesisRegistry() public {
        address newRegistry = makeAddr("newGenesisRegistry");
        address newGenesisUpgrade = makeAddr("newGenesisUpgrade");
        bytes32 genesisBatchHash = bytes32(uint256(0x02));
        uint64 genesisIndexRepeatedStorageChanges = 2;
        bytes32 genesisBatchCommitment = bytes32(uint256(0x02));

        _mockRegistry(
            newRegistry,
            newGenesisUpgrade,
            genesisBatchHash,
            genesisBatchCommitment,
            genesisIndexRepeatedStorageChanges
        );

        vm.expectEmit(true, true, false, false);
        emit IChainTypeManager.NewCurrentRelease(0, newRegistry);

        vm.prank(governor);
        chainContractAddress.setCurrentRelease(newRegistry);

        assertEq(chainContractAddress.currentRelease(), newRegistry, "Current release was not set correctly");
        assertEq(chainContractAddress.l1GenesisUpgrade(), newGenesisUpgrade, "Genesis upgrade was not set correctly");

        // storedBatchZero() is derived from the new registry's genesis params.
        IExecutor.StoredBatchInfo memory newBatchZero = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: genesisBatchHash,
            indexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: 0,
            commitment: genesisBatchCommitment
        });
        bytes32 expectedStoredBatchZero = keccak256(abi.encode(newBatchZero));

        assertEq(
            chainContractAddress.storedBatchZero(),
            expectedStoredBatchZero,
            "Stored batch zero was not set correctly"
        );
    }

    function test_RevertWhen_SettingZeroRegistry() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(governor);
        chainContractAddress.setCurrentRelease(address(0));
    }

    function test_RevertWhen_NotOwner() public {
        address newRegistry = makeAddr("newGenesisRegistry");
        _mockRegistry(newRegistry, makeAddr("gu"), bytes32(uint256(1)), bytes32(uint256(1)), 1);

        vm.expectRevert();
        vm.prank(makeAddr("notOwner"));
        chainContractAddress.setCurrentRelease(newRegistry);
    }

    // `setReleaseFactory` is the migration path for CTMs whose storage predates the field
    // (upgraded proxies never re-run `initialize`); v32 stage calldata invokes it right before
    // the first `setCurrentRelease`.

    function test_SettingReleaseFactory() public {
        address newFactory = makeAddr("newReleaseFactory");

        vm.expectEmit(true, false, false, false);
        emit IChainTypeManager.NewReleaseFactory(newFactory);

        vm.prank(governor);
        chainContractAddress.setReleaseFactory(newFactory);

        assertEq(chainContractAddress.releaseFactory(), newFactory, "Release factory was not set correctly");
    }

    function test_RevertWhen_SettingZeroReleaseFactory() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(governor);
        chainContractAddress.setReleaseFactory(address(0));
    }

    function test_RevertWhen_SettingReleaseFactoryNotOwner() public {
        vm.expectRevert();
        vm.prank(makeAddr("notOwner"));
        chainContractAddress.setReleaseFactory(makeAddr("newReleaseFactory"));
    }
}
