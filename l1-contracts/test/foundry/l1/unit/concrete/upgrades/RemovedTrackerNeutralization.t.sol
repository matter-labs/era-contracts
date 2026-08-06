// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SystemContractsProcessing} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";

import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ISystemContractProxy} from "contracts/l2-upgrades/ISystemContractProxy.sol";
import {SystemContractProxyAdmin} from "contracts/l2-upgrades/SystemContractProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_REMOVED_ASSET_TRACKER_ADDR,
    L2_REMOVED_GW_ASSET_TRACKER_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @dev Stands in for the retired v31 tracker implementation: any selector it exposes must stop
/// being reachable through the proxy once the neutralization lands.
contract MockV31TrackerImpl {
    function trackerSelectorProbe() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Exercises the actual proxy transition of the removed-tracker neutralizations: starting
/// from a v31-like state (real `SystemContractProxy` at both reserved addresses, pointing at a
/// live tracker implementation), the production force-deployment entries are executed through the
/// real `conductContractUpgrade` path and must leave each proxy on the derived `EmptyContract`
/// implementation with the retired selectors unreachable.
contract RemovedTrackerNeutralizationTest is Test {
    /// @dev EIP-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal trackerImplV31;

    function setUp() public {
        // Real proxy admin, owned by this test contract (the library executes in our context, so
        // `SystemContractProxyAdmin.upgrade` sees us as the caller — production runs the same code
        // as the ComplexUpgrader delegate).
        vm.etch(
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
            BytecodeUtils.readDeployedBytecodeL1(true, "SystemContractProxyAdmin.sol", "SystemContractProxyAdmin")
        );
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(address(this));

        trackerImplV31 = address(new MockV31TrackerImpl());

        // v31 state at both reserved addresses: a real system proxy with a live tracker
        // implementation behind it.
        _installV31Tracker(L2_REMOVED_ASSET_TRACKER_ADDR);
        _installV31Tracker(L2_REMOVED_GW_ASSET_TRACKER_ADDR);
    }

    function _installV31Tracker(address _proxyAddr) internal {
        vm.etch(
            _proxyAddr,
            BytecodeUtils.readDeployedBytecodeL1(true, "SystemContractProxy.sol", "SystemContractProxy")
        );
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        ISystemContractProxy(_proxyAddr).forceInitAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR);
        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(_proxyAddr),
            trackerImplV31
        );

        assertEq(
            MockV31TrackerImpl(_proxyAddr).trackerSelectorProbe(),
            1,
            "the v31 tracker implementation must be live before the upgrade"
        );
    }

    function test_neutralizationSwitchesLiveTrackerProxiesToEmptyContract() public {
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory neutralizations = SystemContractsProcessing
            .getRemovedTrackerNeutralizations();
        assertEq(neutralizations.length, 2, "both removed trackers must be neutralized");

        // The upgrade ships the EmptyContract preimage as a factory dep; the sequencer materializes
        // it at the derived implementation address. Model exactly that so `conductContractUpgrade`
        // takes its verify-codehash branch (the etched code hash must match the entry's info).
        bytes memory emptyContractBytecode = BytecodeUtils.readDeployedBytecodeL1(
            true,
            "EmptyContract.sol",
            "EmptyContract"
        );

        for (uint256 i = 0; i < neutralizations.length; ++i) {
            (bytes memory implInfo, ) = abi.decode(neutralizations[i].deployedBytecodeInfo, (bytes, bytes));
            address derivedImpl = L2GenesisForceDeploymentsHelper.generateRandomAddress(implInfo);
            vm.etch(derivedImpl, emptyContractBytecode);

            // The real per-entry upgrade path the ComplexUpgrader loop runs.
            L2GenesisForceDeploymentsHelper.conductContractUpgrade(
                neutralizations[i].upgradeType,
                neutralizations[i].deployedBytecodeInfo,
                neutralizations[i].newAddress
            );

            address proxyAddr = neutralizations[i].newAddress;
            assertEq(
                address(uint160(uint256(vm.load(proxyAddr, IMPLEMENTATION_SLOT)))),
                derivedImpl,
                "the proxy must point at the derived EmptyContract implementation"
            );

            // The retired tracker selector must no longer be reachable through the proxy.
            vm.expectRevert();
            MockV31TrackerImpl(proxyAddr).trackerSelectorProbe();
        }
    }
}
