// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "deploy-scripts/utils/Utils.sol";
import {SystemContractsCaller} from "contracts/common/l2-helpers/SystemContractsCaller.sol";
import {
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2ContractDeployer, AllowedBytecodeTypes} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {
    AcrossInfo,
    L2_ACCOUNT_CODE_STORAGE_ADDR,
    V31AcrossRecovery
} from "contracts/l2-upgrades/V31AcrossRecovery.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {MockUUPSImplementation} from "contracts/dev-contracts/test/MockUUPSImplementation.sol";

bytes32 constant IMPLEMENTATION_SLOT = 0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC;

/// @notice Minimal interface for IContractDeployer.createEVM (not yet in l1-contracts IL2ContractDeployer).
interface IEVMDeployer {
    function createEVM(bytes calldata _initCode) external payable returns (uint256 evmGasUsed, address newAddress);
}

/// @notice A minimal ERC1967-style proxy that delegates all calls to the implementation.
contract MockAcrossProxy {
    constructor(address _implementation) {
        assembly {
            sstore(IMPLEMENTATION_SLOT, _implementation)
        }
    }

    fallback() external payable {
        assembly {
            let implementation := sload(IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
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
            abi.encodeCall(IEVMDeployer.createEVM, (_evmBytecode))
        );
        require(success, "createEVM failed: zkfoundry may not support EVM contract deployment");
        (, deployedAddress) = abi.decode(returndata, (uint256, address));
    }
}

/// @notice Test upgrade contract that inherits V31AcrossRecovery and overrides getAcrossInfo
/// with the test-specific addresses. Addresses are set via immutables in the constructor,
/// so they are embedded in the deployed bytecode and available even when delegatecalled.
contract TestAcrossRecoveryUpgrade is V31AcrossRecovery {
    address private immutable _proxy;
    address private immutable _evmImpl;
    address private immutable _zkevmRecoveryImpl;
    uint256 private immutable _expectedChainId;

    constructor(
        address proxy_,
        address evmImpl_,
        address zkevmRecoveryImpl_,
        uint256 expectedChainId_
    ) {
        _proxy = proxy_;
        _evmImpl = evmImpl_;
        _zkevmRecoveryImpl = zkevmRecoveryImpl_;
        _expectedChainId = expectedChainId_;
    }

    function upgrade(uint256 _l1ChainId) external {
        accrossRecovery(_l1ChainId);
    }

    function getAcrossInfo(uint256) internal view override returns (AcrossInfo memory info) {
        info = AcrossInfo({
            proxy: _proxy,
            evmImplementation: _evmImpl,
            zkevmRecoveryImplementation: _zkevmRecoveryImpl,
            expectedL2ChainId: _expectedChainId
        });
    }
}

contract V31AcrossRecoveryUnitTest is Test {
    address internal proxy;
    address internal correctImplementation;
    address internal brokenImplementation;
    TestAcrossRecoveryUpgrade internal testUpgrade;

    uint256 internal constant TEST_L1_CHAIN_ID = 999;

    function setUp() public {
        // Deploy the correct zkEVM implementation (using `new` in zkfoundry deploys zkEVM bytecode).
        correctImplementation = address(new MockUUPSImplementation());

        // Deploy the proxy pointing to the correct implementation.
        proxy = address(new MockAcrossProxy(correctImplementation));

        // Verify the proxy delegates correctly before we break it.
        assertEq(MockUUPSImplementation(proxy).value(), 42);

        // Read the EVM bytecode of MockUUPSImplementation (from `out/`, not `zkout/`).
        // This is the same contract, but compiled to standard EVM bytecode.
        bytes memory evmBytecode = Utils.readFoundryBytecodeL1(
            "MockUUPSImplementation.sol",
            "MockUUPSImplementation"
        );

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
            proxy,
            brokenImplementation,
            correctImplementation,
            block.chainid
        );
    }

    /// @notice After the broken upgrade, the proxy cannot delegatecall the EVM implementation,
    /// so attempting another upgrade (or any call through the proxy) should revert.
    function test_RecoverAcrossProxyAfterBrokenUpgrade() public {
        // Deploy a new correct implementation to try upgrading to.
        address newCorrectImpl = address(new MockUUPSImplementation());

        // This should revert because the proxy delegates to the EVM implementation,
        // and delegatecall between zkEVM and EVM bytecode is not allowed.
        vm.expectRevert();
        MockUUPSImplementation(proxy).upgradeTo(newCorrectImpl);
    }

    /// @notice Test the full recovery flow: after the broken upgrade, invoke accrossRecovery
    /// via the ComplexUpgrader to force-deploy the correct zkEVM bytecode at the broken
    /// implementation address, then verify the proxy works again.
    function test_RecoveryViaComplexUpgrader() public {
        // Sanity: proxy is broken before recovery.
        (bool success,) = proxy.call(abi.encodeCall(MockUUPSImplementation.value, ()));
        assertFalse(success, "proxy should be broken before recovery");

        // Execute the recovery via ComplexUpgrader.upgrade().
        // ComplexUpgrader requires msg.sender == FORCE_DEPLOYER.
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(TestAcrossRecoveryUpgrade.upgrade, (TEST_L1_CHAIN_ID))
        );

        // After recovery, the broken implementation address now has the correct
        // zkEVM bytecode force-deployed, so the proxy should work again.
        assertEq(MockUUPSImplementation(proxy).value(), 42, "proxy should work after recovery");

        // Verify the proxy can be upgraded again.
        address newImpl = address(new MockUUPSImplementation());
        MockUUPSImplementation(proxy).upgradeTo(newImpl);
    }
}
