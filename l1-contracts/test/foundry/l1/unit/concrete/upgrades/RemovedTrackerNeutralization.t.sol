// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {SystemContractsProcessing} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ISystemContractProxy} from "contracts/l2-upgrades/ISystemContractProxy.sol";
import {SystemContractProxyAdmin} from "contracts/l2-upgrades/SystemContractProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
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

/// @dev Inert delegate target for the dispatcher call: the upgrade payload itself is covered by
/// the L2V34Upgrade tests, this suite only exercises the force-deployment loop before it.
contract NoopUpgradeDelegate {
    function noop() external {}
}

/// @dev Faithful stand-in for the ZKsync OS contract deployer: materializes the bytecode a force
/// deployment actually requests (keyed by the entry's observable code hash), so the fresh
/// implementation-deployment branch of `updateZKsyncOSContract` is exercised for real instead of
/// being bypassed with pre-etched code.
contract FaithfulZKOSDeployer {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));

    mapping(bytes32 observableHash => bytes bytecode) internal registered;
    mapping(bytes32 observableHash => bytes32 blakeHash) internal registeredBlakeHash;
    bytes internal defaultBytecode;

    /// @dev Records addresses that got the placeholder rather than a registered artifact — the
    /// test asserts the entries under scrutiny never fell back, so a regression in how the
    /// production code forwards the bytecode triple cannot be masked by the fallback.
    mapping(address addr => bool usedFallback) public materializedFromFallback;

    function register(bytes calldata _bytecode, bytes32 _blakeHash) external {
        registered[keccak256(_bytecode)] = _bytecode;
        registeredBlakeHash[keccak256(_bytecode)] = _blakeHash;
    }

    function setDefaultBytecode(bytes calldata _bytecode) external {
        defaultBytecode = _bytecode;
    }

    function setBytecodeDetailsEVM(
        address _addr,
        bytes32 _blakeHash,
        uint32 _length,
        bytes32 _observableHash
    ) external {
        bytes memory bytecode = registered[_observableHash];
        if (bytecode.length == 0) {
            materializedFromFallback[_addr] = true;
            bytecode = defaultBytecode;
        } else {
            // A registered request must carry the artifact's full, self-consistent triple.
            require(_blakeHash == registeredBlakeHash[_observableHash], "blake hash mismatch");
            require(_length == bytecode.length, "bytecode length mismatch");
        }
        Vm(VM_ADDRESS).etch(_addr, bytecode);
    }
}

/// @notice Exercises the actual proxy transition of the removed-tracker neutralization: starting
/// from a v31-like state (a real `SystemContractProxy` at the reserved address, pointing at a live
/// tracker implementation), the production force-deployment entries are executed through the real
/// `conductContractUpgrade` path and must leave the proxy on the derived `EmptyContract`
/// implementation with the retired selectors unreachable.
contract RemovedTrackerNeutralizationTest is Test {
    /// @dev EIP-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal trackerImplV31;

    function setUp() public {
        // Real ComplexUpgrader and proxy admin, wired exactly like production: the upgrader owns
        // the admin, so the dispatcher's proxy swaps run with the production caller. The deployer
        // materializes exactly the bytecode each entry requests.
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, address(new L2ComplexUpgrader()).code);
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, address(new FaithfulZKOSDeployer()).code);
        vm.etch(
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
            BytecodeUtils.readDeployedBytecodeL1("SystemContractProxyAdmin.sol", "SystemContractProxyAdmin")
        );
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(L2_COMPLEX_UPGRADER_ADDR);

        trackerImplV31 = address(new MockV31TrackerImpl());

        // v31 state at the reserved address: a real system proxy with a live tracker
        // implementation behind it.
        _installV31Tracker(L2_REMOVED_GW_ASSET_TRACKER_ADDR);
    }

    function _installV31Tracker(address _proxyAddr) internal {
        vm.etch(_proxyAddr, BytecodeUtils.readDeployedBytecodeL1("SystemContractProxy.sol", "SystemContractProxy"));
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        ISystemContractProxy(_proxyAddr).forceInitAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
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

    function test_neutralizationSwitchesTheLiveTrackerProxyToEmptyContract() public {
        // The COMPLETE production list, dispatched in production order. The list is table-DERIVED
        // in enum order, so the neutralization is one row of it: assert it is present with exactly
        // the neutralizing content — a list builder that dropped or mangled the row fails here,
        // and the per-proxy assertions below then prove the row actually executes.
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = SystemContractsProcessing
            .getBaseZKsyncOSForceDeployments();
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory neutralizations = SystemContractsProcessing
            .getRemovedTrackerNeutralizations();
        assertEq(neutralizations.length, 1, "the removed GWAssetTracker must be neutralized");
        for (uint256 i = 0; i < neutralizations.length; ++i) {
            bool found = false;
            for (uint256 j = 0; j < deployments.length; ++j) {
                if (deployments[j].newAddress != neutralizations[i].newAddress) {
                    continue;
                }
                assertEq(
                    abi.encode(deployments[j]),
                    abi.encode(neutralizations[i]),
                    "the production list's neutralization row must match the neutralization exactly"
                );
                found = true;
                break;
            }
            assertTrue(found, "the neutralization must be part of the production list");
        }

        bytes memory emptyContractBytecode = BytecodeUtils.readDeployedBytecodeL1("EmptyContract.sol", "EmptyContract");

        // The deployer materializes each entry's requested bytecode: the real proxy for fresh
        // proxies, EmptyContract wherever an entry's implementation info asks for it, and an inert
        // placeholder implementation for the other (never-called-here) core contracts.
        FaithfulZKOSDeployer deployer = FaithfulZKOSDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);
        {
            // The expected Blake hashes are derived independently from the raw artifacts (not from
            // the entries under test), so a list builder emitting a wrong Blake hash fails here.
            bytes memory proxyBytecode = BytecodeUtils.readDeployedBytecodeL1(
                "SystemContractProxy.sol",
                "SystemContractProxy"
            );
            deployer.register(emptyContractBytecode, Utils.blakeHashBytecode(emptyContractBytecode));
            deployer.register(proxyBytecode, Utils.blakeHashBytecode(proxyBytecode));
        }
        deployer.setDefaultBytecode(emptyContractBytecode);

        // The derived EmptyContract implementation addresses start EMPTY: the dispatcher itself
        // must ask the deployer to materialize them (the fresh-deployment branch).
        address[] memory derivedImpls = new address[](neutralizations.length);
        for (uint256 i = 0; i < neutralizations.length; ++i) {
            (bytes memory implInfo, ) = abi.decode(neutralizations[i].deployedBytecodeInfo, (bytes, bytes));
            derivedImpls[i] = L2GenesisForceDeploymentsHelper.generateRandomAddress(implInfo);
            assertEq(derivedImpls[i].code.length, 0, "the implementation must not pre-exist");
        }

        NoopUpgradeDelegate delegate = new NoopUpgradeDelegate();
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).forceDeployAndUpgradeUniversal(
            deployments,
            address(delegate),
            abi.encodeCall(NoopUpgradeDelegate.noop, ())
        );

        for (uint256 i = 0; i < neutralizations.length; ++i) {
            address proxyAddr = neutralizations[i].newAddress;
            assertFalse(
                deployer.materializedFromFallback(derivedImpls[i]),
                "the implementation must come from the registered artifact, not the fallback"
            );
            assertEq(
                keccak256(derivedImpls[i].code),
                keccak256(emptyContractBytecode),
                "the dispatcher must have materialized the EmptyContract implementation"
            );
            assertEq(
                address(uint160(uint256(vm.load(proxyAddr, IMPLEMENTATION_SLOT)))),
                derivedImpls[i],
                "the proxy must point at the derived EmptyContract implementation"
            );

            // The retired tracker selector must no longer be reachable through the proxy.
            vm.expectRevert();
            MockV31TrackerImpl(proxyAddr).trackerSelectorProbe();
        }
    }
}
