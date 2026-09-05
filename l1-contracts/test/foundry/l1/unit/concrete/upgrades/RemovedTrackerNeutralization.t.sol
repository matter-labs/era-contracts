// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {SystemContractsProcessing} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {ISystemContractProxy} from "contracts/l2-upgrades/ISystemContractProxy.sol";
import {SystemContractProxyAdmin} from "contracts/l2-upgrades/SystemContractProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {AddressHasNoCode, Unauthorized, UnsupportedUpgradeType} from "contracts/common/L1ContractErrors.sol";
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
/// the L2V32Upgrade tests, this suite only exercises the force-deployment loop before it.
contract NoopUpgradeDelegate {
    function noop() external {}
}

/// @dev The pre-v32 ComplexUpgrader behavior needed by this regression. In particular, it still
/// exposes the Era-only entry point while its universal path is the code that starts the self-upgrade.
contract V31L2ComplexUpgrader {
    modifier onlyForceDeployer() {
        if (msg.sender != L2_FORCE_DEPLOYER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    function forceDeployAndUpgrade(
        IL2ContractDeployer.ForceDeployment[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable onlyForceDeployer {
        IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(_forceDeployments);
        upgrade(_delegateTo, _calldata);
    }

    function forceDeployAndUpgradeUniversal(
        IComplexUpgrader.UniversalContractUpgradeInfo[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable onlyForceDeployer {
        for (uint256 i = 0; i < _forceDeployments.length; ++i) {
            L2GenesisForceDeploymentsHelper.conductContractUpgrade(
                _forceDeployments[i].upgradeType,
                _forceDeployments[i].deployedBytecodeInfo,
                _forceDeployments[i].newAddress
            );
        }
        upgrade(_delegateTo, _calldata);
    }

    function upgrade(address _delegateTo, bytes calldata _calldata) public payable onlyForceDeployer {
        if (_delegateTo.code.length == 0) {
            revert AddressHasNoCode(_delegateTo);
        }
        (bool success, bytes memory returnData) = _delegateTo.delegatecall(_calldata);
        assembly {
            if iszero(success) {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}

/// @dev Faithful stand-in for the ZKsync OS contract deployer: materializes the bytecode a force
/// deployment actually requests (keyed by the entry's observable code hash), so the fresh
/// implementation-deployment branch of `upgradeSystemContractProxy` is exercised for real instead of
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

    /// @dev The v31-only ComplexUpgrader selector calls this before the regression swaps the
    /// implementation. An empty list is enough to prove that selector is initially reachable.
    function forceDeployOnAddresses(IL2ContractDeployer.ForceDeployment[] calldata _deployments) external pure {
        require(_deployments.length == 0, "only the empty legacy probe is supported");
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
/// implementation with the retired selectors unreachable. The same production list must also
/// self-upgrade the v31 ComplexUpgrader proxy without interrupting its in-flight delegatecall.
contract RemovedTrackerNeutralizationTest is Test {
    /// @dev EIP-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal trackerImplV31;

    function setUp() public {
        // Real proxy admin, wired exactly like production: the ComplexUpgrader address owns the
        // admin, so the dispatcher's proxy swaps run with the production caller. The deployer
        // materializes exactly the bytecode each entry requests.
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, address(new FaithfulZKOSDeployer()).code);
        vm.etch(
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
            BytecodeUtils.readDeployedBytecodeL1("SystemContractProxyAdmin.sol", "SystemContractProxyAdmin")
        );
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(L2_COMPLEX_UPGRADER_ADDR);

        // Existing-chain state: the canonical address is already a SystemContractProxy, but it
        // still delegates to the v31 implementation that exposes the Era-only entry point.
        vm.etch(
            L2_COMPLEX_UPGRADER_ADDR,
            BytecodeUtils.readDeployedBytecodeL1("SystemContractProxy.sol", "SystemContractProxy")
        );
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        ISystemContractProxy(L2_COMPLEX_UPGRADER_ADDR).forceInitAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR);
        address v31ComplexUpgraderImpl = address(new V31L2ComplexUpgrader());
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(L2_COMPLEX_UPGRADER_ADDR),
            v31ComplexUpgraderImpl
        );

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
        // The COMPLETE production list, dispatched in production order: the neutralizations sit at
        // the tail, so a dispatcher (or list builder) that stopped at the former entry count would
        // fail the per-proxy assertions below.
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = SystemContractsProcessing
            .getBaseForceDeployments();
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory neutralizations = SystemContractsProcessing
            .getRemovedTrackerNeutralizations();
        assertEq(neutralizations.length, 1, "the removed GWAssetTracker must be neutralized");
        for (uint256 i = 0; i < neutralizations.length; ++i) {
            assertEq(
                deployments[deployments.length - neutralizations.length + i].newAddress,
                neutralizations[i].newAddress,
                "the neutralizations must sit at the tail of the production list"
            );
        }

        bytes memory emptyContractBytecode = BytecodeUtils.readDeployedBytecodeL1("EmptyContract.sol", "EmptyContract");
        bytes memory complexUpgraderBytecode = BytecodeUtils.readDeployedBytecodeL1(
            "L2ComplexUpgrader.sol",
            "L2ComplexUpgrader"
        );

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
            deployer.register(complexUpgraderBytecode, Utils.blakeHashBytecode(complexUpgraderBytecode));
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

        // The legacy selector is live before the upgrade. It executes against an empty deployment
        // list here, so the probe changes no state beyond proving which implementation is active.
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        V31L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).forceDeployAndUpgrade(
            new IL2ContractDeployer.ForceDeployment[](0),
            address(delegate),
            abi.encodeCall(NoopUpgradeDelegate.noop, ())
        );

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

        bytes memory expectedComplexUpgraderInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(
            "L2ComplexUpgrader.sol",
            "L2ComplexUpgrader"
        );
        (bytes memory complexUpgraderImplInfo, ) = abi.decode(expectedComplexUpgraderInfo, (bytes, bytes));
        address expectedComplexUpgraderImpl = L2GenesisForceDeploymentsHelper.generateRandomAddress(
            complexUpgraderImplInfo
        );
        assertFalse(
            deployer.materializedFromFallback(expectedComplexUpgraderImpl),
            "the ComplexUpgrader must come from its registered artifact"
        );
        assertEq(
            address(uint160(uint256(vm.load(L2_COMPLEX_UPGRADER_ADDR, IMPLEMENTATION_SLOT)))),
            expectedComplexUpgraderImpl,
            "the ComplexUpgrader proxy must switch to the v32 implementation"
        );
        assertEq(
            keccak256(expectedComplexUpgraderImpl.code),
            keccak256(complexUpgraderBytecode),
            "the derived ComplexUpgrader implementation has the wrong code"
        );

        // The call frame that performed the self-upgrade completed, but later calls resolve to the
        // new implementation: the Era selector is gone and ordinal zero stays reserved/reverting.
        vm.expectRevert();
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        V31L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).forceDeployAndUpgrade(
            new IL2ContractDeployer.ForceDeployment[](0),
            address(delegate),
            abi.encodeCall(NoopUpgradeDelegate.noop, ())
        );

        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory retiredDeployment = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        retiredDeployment[0].upgradeType = IComplexUpgrader.ContractUpgradeType.__DEPRECATED_EraForceDeployment;
        vm.expectRevert(UnsupportedUpgradeType.selector);
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).forceDeployAndUpgradeUniversal(
            retiredDeployment,
            address(delegate),
            abi.encodeCall(NoopUpgradeDelegate.noop, ())
        );
    }
}
