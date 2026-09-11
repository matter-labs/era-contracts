// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DiamondInitTest} from "./_DiamondInit_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {EmptyAssetId, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";

contract InitializeTest is DiamondInitTest {
    function test_revertWhen_verifierIsZeroAddress() public {
        // Mock CTM to return zero address for verifier
        vm.mockCall(
            initializeData.chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, initializeData.protocolVersion),
            abi.encode(address(0))
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_governorIsZeroAddress() public {
        initializeData.admin = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_validatorTimelockIsZeroAddress() public {
        initializeData.validatorTimelock = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_bridgehubAddressIsZero() public {
        initializeData.bridgehub = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_chainTypeManagerAddressIsZero() public {
        initializeData.chainTypeManager = address(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(ZeroAddress.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_revertWhen_baseTokenAssetIdIsZero() public {
        initializeData.baseTokenAssetId = bytes32(0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(EmptyAssetId.selector);
        new DiamondProxy(block.chainid, diamondCutData);
    }

    function test_valuesCorrectWhenSuccessfulInit() public {
        // Mock CTM to return testnetVerifier for this protocol version
        vm.mockCall(
            initializeData.chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, initializeData.protocolVersion),
            abi.encode(testnetVerifier)
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        UtilsFacet utilsFacet = UtilsFacet(address(diamondProxy));

        assertEq(utilsFacet.util_getChainId(), initializeData.chainId);
        assertEq(utilsFacet.util_getBridgehub(), initializeData.bridgehub);
        assertEq(utilsFacet.util_getChainTypeManager(), initializeData.chainTypeManager);
        assertEq(utilsFacet.util_getBaseTokenAssetId(), initializeData.baseTokenAssetId);
        assertEq(utilsFacet.util_getProtocolVersion(), initializeData.protocolVersion);

        // Verifier is now fetched from CTM
        assertEq(address(utilsFacet.util_getVerifier()), testnetVerifier);
        assertEq(utilsFacet.util_getAdmin(), initializeData.admin);
        assertEq(utilsFacet.util_getValidator(initializeData.validatorTimelock), true);

        assertEq(utilsFacet.util_getStoredBatchHashes(0), initializeData.storedBatchZero);
        // The EraVM bytecode-hash slots are deprecated tombstones: initialization must leave the
        // physical slots zero. Read the raw slots (indices from ZKChainStorage's layout, see
        // `forge inspect GettersFacet storage-layout`) instead of keeping dormant getters that would
        // silently follow the fields if they were ever moved.
        assertEq(vm.load(address(diamondProxy), bytes32(uint256(23))), bytes32(0)); // __DEPRECATED_l2BootloaderBytecodeHash
        assertEq(vm.load(address(diamondProxy), bytes32(uint256(24))), bytes32(0)); // __DEPRECATED_l2DefaultAccountBytecodeHash
        assertEq(vm.load(address(diamondProxy), bytes32(uint256(58))), bytes32(0)); // __DEPRECATED_l2EvmEmulatorBytecodeHash
        assertEq(vm.load(address(diamondProxy), bytes32(uint256(25))), bytes32(0)); // __DEPRECATED_zkPorterIsAvailable
        assertEq(vm.load(address(diamondProxy), bytes32(uint256(59))), bytes32(0)); // __DEPRECATED_precommitmentForTheLatestBatch
        // Slot 60 packs zksyncOS (byte 0) + l2DACommitmentScheme (byte 1) +
        // __DEPRECATED_assetTracker (bytes 2-21). Fresh OS chains set zksyncOS to true.
        assertEq(vm.load(address(diamondProxy), bytes32(uint256(60))), bytes32(uint256(1)));
    }

    /// @dev Pins the intra-slot packing of slot 60: writing the scheme through the storage struct
    /// must land in byte 1 exactly, preserving the live `zksyncOS` flag at byte 0 and the
    /// `__DEPRECATED_assetTracker` tombstone at bytes 2-21. A packing shift would corrupt or
    /// misread compatibility state on an upgraded chain.
    function test_slot60PackingPinnedAroundDeprecatedNeighbors() public {
        vm.mockCall(
            initializeData.chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, initializeData.protocolVersion),
            abi.encode(testnetVerifier)
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        UtilsFacet utilsFacet = UtilsFacet(address(diamondProxy));

        utilsFacet.util_setL2DACommitmentScheme(L2DACommitmentScheme.PUBDATA_KECCAK256);

        assertEq(
            vm.load(address(diamondProxy), bytes32(uint256(60))),
            bytes32(uint256(1) | (uint256(uint8(L2DACommitmentScheme.PUBDATA_KECCAK256)) << 8))
        );
        assertTrue(utilsFacet.util_getL2DACommimentScheme() == L2DACommitmentScheme.PUBDATA_KECCAK256);
    }
}
