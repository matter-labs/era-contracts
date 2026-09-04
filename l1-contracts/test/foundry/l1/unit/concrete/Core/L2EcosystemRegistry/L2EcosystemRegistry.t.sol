// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2EcosystemRegistry} from "contracts/core/registry/L2EcosystemRegistry.sol";
import {IL2EcosystemRegistry} from "contracts/core/registry/IL2EcosystemRegistry.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {EmptyData, InvalidCaller} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for the ZKsync OS L2 ecosystem registry: the upgrader-only write gate,
///         the verbatim-bytes storage model (dataHash == keccak of the pinned encoding), the
///         typed getters, and re-pinning across upgrades.
contract L2EcosystemRegistryTest is Test {
    L2EcosystemRegistry internal registry;

    function setUp() public {
        registry = new L2EcosystemRegistry();
    }

    /// @dev A fully populated struct, parameterized so repeatability tests can pin two
    ///      distinguishable payloads.
    function _data(uint256 _salt) internal pure returns (FixedForceDeploymentsData memory data) {
        bytes memory bytecodeInfo = abi.encode(bytes32(_salt));
        data = FixedForceDeploymentsData({
            l1ChainId: 100 + _salt,
            eraChainId: 200 + _salt,
            l1AssetRouter: address(uint160(0xAA00 + _salt)),
            l2TokenProxyBytecodeHash: keccak256(abi.encode("proxy", _salt)),
            aliasedL1Governance: address(uint160(0xBB00 + _salt)),
            maxNumberOfZKChains: 100,
            bridgehubBytecodeInfo: bytecodeInfo,
            l2AssetRouterBytecodeInfo: bytecodeInfo,
            l2NtvBytecodeInfo: bytecodeInfo,
            messageRootBytecodeInfo: bytecodeInfo,
            chainAssetHandlerBytecodeInfo: bytecodeInfo,
            interopCenterBytecodeInfo: bytecodeInfo,
            interopHandlerBytecodeInfo: bytecodeInfo,
            assetTrackerBytecodeInfo: bytecodeInfo,
            beaconDeployerInfo: bytecodeInfo,
            baseTokenHolderBytecodeInfo: bytecodeInfo,
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            aliasedChainRegistrationSender: address(uint160(0xCC00 + _salt)),
            dangerousTestOnlyForcedBeacon: address(0),
            zkTokenAssetId: keccak256(abi.encode("zk", _salt))
        });
    }

    function _updateAsUpgrader(bytes memory _encoded) internal {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        registry.updateL2(_encoded);
    }

    // ─────────────────────────── write gate ───────────────────────────

    function test_revertWhen_updateCalledByNonUpgrader() public {
        address stranger = makeAddr("stranger");
        bytes memory encoded = abi.encode(_data(1));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(InvalidCaller.selector, stranger));
        registry.updateL2(encoded);
    }

    function test_revertWhen_updateWithEmptyData() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(EmptyData.selector);
        registry.updateL2(bytes(""));
    }

    function test_revertWhen_updateWithMalformedEncoding() public {
        // Not a FixedForceDeploymentsData encoding: the shape check must fail in the upgrade
        // transaction, not in every later read.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert();
        registry.updateL2(hex"deadbeef");
    }

    // ─────────────────────────── happy path ───────────────────────────

    function test_updatePinsVerbatimBytesAndServesTypedGetters() public {
        FixedForceDeploymentsData memory data = _data(1);
        bytes memory encoded = abi.encode(data);

        vm.expectEmit(true, false, false, false, address(registry));
        emit IL2EcosystemRegistry.EcosystemDataUpdated(keccak256(encoded));
        _updateAsUpgrader(encoded);

        // The hash IS the hash of the pinned bytes, and the stored encoding round-trips.
        assertEq(registry.dataHash(), keccak256(encoded), "dataHash must be keccak of the verbatim bytes");
        assertEq(
            abi.encode(registry.getFixedForceDeploymentsData()),
            encoded,
            "stored encoding must round-trip verbatim"
        );

        // Typed getters serve the decoded fields.
        assertEq(registry.l1ChainId(), data.l1ChainId);
        assertEq(registry.eraChainId(), data.eraChainId);
        assertEq(registry.l1AssetRouter(), data.l1AssetRouter);
        assertEq(registry.aliasedL1Governance(), data.aliasedL1Governance);
        assertEq(registry.aliasedChainRegistrationSender(), data.aliasedChainRegistrationSender);
        assertEq(registry.zkTokenAssetId(), data.zkTokenAssetId);
    }

    /// @dev NOT write-once: every protocol upgrade re-pins the release-scoped data.
    function test_updateIsRepeatable() public {
        _updateAsUpgrader(abi.encode(_data(1)));

        FixedForceDeploymentsData memory second = _data(2);
        bytes memory secondEncoded = abi.encode(second);
        vm.expectEmit(true, false, false, false, address(registry));
        emit IL2EcosystemRegistry.EcosystemDataUpdated(keccak256(secondEncoded));
        _updateAsUpgrader(secondEncoded);

        assertEq(registry.dataHash(), keccak256(secondEncoded), "the second update must replace the pinned bytes");
        assertEq(registry.l1ChainId(), second.l1ChainId, "getters must serve the replacing data");
        assertEq(registry.zkTokenAssetId(), second.zkTokenAssetId);
    }
}
