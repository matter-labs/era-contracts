// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "deploy-scripts/utils/Utils.sol";
import {SystemContractsCaller} from "contracts/common/l2-helpers/SystemContractsCaller.sol";
import {
    L2_ACCOUNT_CODE_STORAGE_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AllowedBytecodeTypes, IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {
    AcrossInfo,
    LensSpokePoolConstructorParams,
    V31AcrossRecovery
} from "contracts/l2-upgrades/V31AcrossRecovery.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {MockUUPSImplementation} from "contracts/dev-contracts/test/MockUUPSImplementation.sol";
import {Proxy} from "@openzeppelin/contracts-v4/proxy/Proxy.sol";
import {ERC1967Upgrade} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Upgrade.sol";
import {StorageSlot} from "@openzeppelin/contracts-v4/utils/StorageSlot.sol";

/// @notice A minimal ERC1967-style proxy that delegates all calls to the implementation.
/// @dev Uses OZ's Proxy for delegation and ERC1967Upgrade for the implementation slot.
/// Does not use ERC1967Proxy directly to avoid Address.isContract checks that may
/// behave unexpectedly in zkEVM.
contract MockAcrossProxy is Proxy, ERC1967Upgrade {
    constructor(address _implementation) {
        StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = _implementation;
    }

    function _implementation() internal view override returns (address) {
        return _getImplementation();
    }

    fallback() external payable override {
        _fallback();
    }
}

/// @notice Wrapper contract that deploys EVM bytecode via the ContractDeployer system contract.
/// @dev System calls (SystemContractsCaller) do not work at the top level of a zkfoundry test,
/// but they work inside contract execution. This wrapper performs the createEVM system call
/// in its constructor.
contract EVMBytecodeDeployer {
    address public deployedAddress;

    constructor(bytes memory _evmBytecode) {
        (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
            type(uint32).max,
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            0,
            abi.encodeCall(IL2ContractDeployer.createEVM, (_evmBytecode))
        );
        require(success, "createEVM failed: zkfoundry may not support EVM contract deployment");
        (, deployedAddress) = abi.decode(returndata, (uint256, address));
    }
}

/// @notice Test upgrade contract that inherits V31AcrossRecovery and overrides getAcrossInfo
/// with the test-specific addresses. Individual immutables are used instead of a struct
/// because zksolc does not support struct immutables, and storage variables do not work
/// here since ComplexUpgrader delegatecalls this contract.
contract TestAcrossRecoveryUpgrade is V31AcrossRecovery {
    address private immutable _proxy;
    address private immutable _evmImpl;
    address private immutable _zkevmRecoveryImpl;

    constructor(AcrossInfo memory info_) {
        _proxy = info_.proxy;
        _evmImpl = info_.evmImplementation;
        _zkevmRecoveryImpl = info_.zkevmRecoveryImplementation;
    }

    function upgrade() external {
        acrossRecovery();
    }

    function getAcrossInfo() internal view override returns (AcrossInfo memory) {
        return
            AcrossInfo({
                proxy: _proxy,
                evmImplementation: _evmImpl,
                zkevmRecoveryImplementation: _zkevmRecoveryImpl,
                zkevmRecoveryImplConstructorParams: LensSpokePoolConstructorParams({
                    _wrappedNativeTokenAddress: address(0),
                    _circleUSDC: address(0),
                    _zkUSDCBridge: address(0),
                    _cctpTokenMessenger: address(0),
                    _depositQuoteTimeBuffer: 0,
                    _fillDeadlineBuffer: 0
                })
            });
    }
}

contract V31AcrossRecoveryUnitTest is Test {
    address internal proxy;
    address internal correctImplementation;
    address internal brokenImplementation;
    TestAcrossRecoveryUpgrade internal testUpgrade;

    function setUp() public {
        // Deploy the correct zkEVM implementation (using `new` in zkfoundry deploys zkEVM bytecode).
        correctImplementation = address(new MockUUPSImplementation());

        // Deploy the proxy pointing to the correct implementation.
        proxy = address(new MockAcrossProxy(correctImplementation));

        // Verify the proxy delegates correctly before we break it.
        assertEq(MockUUPSImplementation(proxy).value(), 42);

        // Read the EVM bytecode of MockUUPSImplementation (from `out/`, not `zkout/`).
        // This is the same contract, but compiled to standard EVM bytecode.
        bytes memory evmBytecode = Utils.readFoundryBytecodeL1("MockUUPSImplementation.sol", "MockUUPSImplementation");

        // Etch the ContractDeployer system contract (not present by default in zkfoundry unit tests).
        bytes memory contractDeployerBytecode = Utils.readSystemContractsBytecode("ContractDeployer");
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, contractDeployerBytecode);

        // Ensure EVM bytecode deployment is allowed on this chain.
        IL2ContractDeployer contractDeployer = IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);
        AllowedBytecodeTypes currentMode = contractDeployer.allowedBytecodeTypesToDeploy();
        if (currentMode != AllowedBytecodeTypes.EraVmAndEVM) {
            vm.prank(L2_FORCE_DEPLOYER_ADDR);
            contractDeployer.setAllowedBytecodeTypesToDeploy(AllowedBytecodeTypes.EraVmAndEVM);
        }

        // Deploy the EVM bytecode via a wrapper contract. System calls only work
        // inside contract execution, not at the test's top level.
        EVMBytecodeDeployer deployer = new EVMBytecodeDeployer(evmBytecode);
        brokenImplementation = deployer.deployedAddress();

        // Upgrade the proxy to the EVM (broken) implementation.
        // This still works because the current (correct) implementation supports upgradeTo.
        MockUUPSImplementation(proxy).upgradeTo(brokenImplementation);

        // Verify the proxy is broken after upgrading to the EVM implementation.
        (bool success, ) = proxy.call(abi.encodeCall(MockUUPSImplementation.value, ()));
        assertFalse(success, "proxy should be broken after upgrading to EVM implementation");

        // Etch the AccountCodeStorage system contract (needed by V31AcrossRecovery to read bytecode hashes).
        bytes memory accountCodeStorageBytecode = Utils.readSystemContractsBytecode("AccountCodeStorage");
        vm.etch(L2_ACCOUNT_CODE_STORAGE_ADDR, accountCodeStorageBytecode);

        // Etch the L2ComplexUpgrader system contract.
        bytes memory complexUpgraderBytecode = Utils.readZKFoundryBytecodeL1(
            "L2ComplexUpgrader.sol",
            "L2ComplexUpgrader"
        );
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, complexUpgraderBytecode);

        // Deploy the test upgrade contract with the addresses from this test.
        testUpgrade = new TestAcrossRecoveryUpgrade(
            AcrossInfo({
                proxy: proxy,
                evmImplementation: brokenImplementation,
                zkevmRecoveryImplementation: correctImplementation,
                zkevmRecoveryImplConstructorParams: LensSpokePoolConstructorParams({
                    _wrappedNativeTokenAddress: address(0),
                    _circleUSDC: address(0),
                    _zkUSDCBridge: address(0),
                    _cctpTokenMessenger: address(0),
                    _depositQuoteTimeBuffer: 0,
                    _fillDeadlineBuffer: 0
                })
            })
        );
    }

    /// @notice Test the full recovery flow: after the broken upgrade, invoke acrossRecovery
    /// via the ComplexUpgrader to force-deploy the correct zkEVM bytecode at the broken
    /// implementation address, then verify the proxy works again.
    function test_RecoveryViaComplexUpgrader() public {
        // Execute the recovery via ComplexUpgrader.upgrade().
        // ComplexUpgrader requires msg.sender == FORCE_DEPLOYER.
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(TestAcrossRecoveryUpgrade.upgrade, ())
        );

        // After recovery, the broken implementation address now has the correct
        // zkEVM bytecode force-deployed, so the proxy should work again.
        assertEq(MockUUPSImplementation(proxy).value(), 42, "proxy should work after recovery");

        // Verify the proxy can be upgraded again.
        address newImpl = address(new MockUUPSImplementation());
        MockUUPSImplementation(proxy).upgradeTo(newImpl);
    }
}
