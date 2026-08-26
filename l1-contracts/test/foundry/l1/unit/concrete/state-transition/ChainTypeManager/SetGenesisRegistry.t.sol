// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ICTMRelease} from "contracts/upgrades/registry/ICTMRelease.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";
import {
    RegistryMissingBaseSystemHash,
    RegistryReleaseCodehashAlreadySet,
    ZeroAddress,
    EmptyBytes32
} from "contracts/common/L1ContractErrors.sol";
import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";

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
        // Era releases must carry all three base-system hashes; the CTM rejects a zero one.
        vm.mockCall(
            _registry,
            abi.encodeWithSelector(ICTMRelease.baseSystemContractHashes.selector),
            abi.encode(bytes32(uint256(0xB0)), bytes32(uint256(0xDA)), bytes32(uint256(0xE)))
        );
        // VM identity is single-sourced from the release's DiamondInit; the mocked registry's
        // diamondInit placeholder is the registry itself, so mock the flag there.
        vm.mockCall(_registry, abi.encodeWithSelector(ICTMRelease.diamondInit.selector), abi.encode(_registry));
        vm.mockCall(_registry, abi.encodeWithSelector(IDiamondInit.IS_ZKSYNC_OS.selector), abi.encode(false));
        // From v32 the CTM enforces release provenance by CODEHASH, so a mocked release has to
        // carry the audited `CTMRelease` runtime code to be accepted as `currentRelease`.
        vm.etch(_registry, type(CTMRelease).runtimeCode);
        vm.mockCall(
            _registry,
            abi.encodeWithSelector(ICTMRelease.manifestHash.selector),
            abi.encode(keccak256(abi.encode(_registry)))
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

    // `setReleaseCodehash` is the migration path for CTMs whose storage predates the field
    // (upgraded proxies never re-run `initialize`); v32 stage calldata invokes it right before
    // the first `setCurrentRelease`.

    /// @dev Regression: an Era release that leaves a base-system hash at zero must be rejected when
    ///      it is pinned. Accepting it would split the two paths the model promises cannot diverge —
    ///      `DiamondInit` refuses zero hashes, so NEW chains could not be created, while EXISTING
    ///      chains would silently keep the old hash (an upgrade reads a zero change as "unchanged").
    function test_RevertWhen_EraReleaseHasZeroBaseSystemHash() public {
        address zeroHashRelease = makeAddr("zeroHashRelease");
        _mockRegistry(zeroHashRelease, makeAddr("gu"), bytes32(uint256(2)), bytes32(uint256(2)), 2);
        // Blank the EVM emulator hash; the other two stay set.
        vm.mockCall(
            zeroHashRelease,
            abi.encodeWithSelector(ICTMRelease.baseSystemContractHashes.selector),
            abi.encode(bytes32(uint256(0xB0)), bytes32(uint256(0xDA)), bytes32(0))
        );

        vm.expectRevert(RegistryMissingBaseSystemHash.selector);
        vm.prank(governor);
        chainContractAddress.setCurrentRelease(zeroHashRelease);
    }

    /// @dev Re-setting the anchor to the value it ALREADY holds is a no-op, so one upgrade bundle
    ///      works against both a migrated CTM (anchor zero) and an already-anchored one without the
    ///      calldata predicting which it is.
    function test_SettingReleaseCodehashToSameValueIsNoop() public {
        bytes32 configured = chainContractAddress.releaseCodehash();
        assertTrue(configured != bytes32(0), "fixture CTM should already be anchored");

        vm.prank(governor);
        chainContractAddress.setReleaseCodehash(configured);

        assertEq(chainContractAddress.releaseCodehash(), configured, "anchor must be unchanged");
    }

    /// @dev But the anchor can never be RE-POINTED: every pinned release is checked against it, so
    ///      changing it would retroactively change which code counts as a genuine release. The
    ///      migration path itself (anchor still zero) is exercised by the v32 integration test.
    function test_RevertWhen_ReplacingConfiguredReleaseCodehash() public {
        bytes32 configured = chainContractAddress.releaseCodehash();
        assertTrue(configured != bytes32(0), "fixture CTM should already be anchored");

        vm.expectRevert(abi.encodeWithSelector(RegistryReleaseCodehashAlreadySet.selector, configured));
        vm.prank(governor);
        chainContractAddress.setReleaseCodehash(keccak256("otherRelease"));

        assertEq(chainContractAddress.releaseCodehash(), configured, "anchor must be unchanged");
    }

    function test_RevertWhen_SettingZeroReleaseCodehash() public {
        vm.expectRevert(EmptyBytes32.selector);
        vm.prank(governor);
        chainContractAddress.setReleaseCodehash(bytes32(0));
    }

    function test_RevertWhen_SettingReleaseCodehashNotOwner() public {
        vm.expectRevert();
        vm.prank(makeAddr("notOwner"));
        chainContractAddress.setReleaseCodehash(keccak256("otherRelease"));
    }
}
