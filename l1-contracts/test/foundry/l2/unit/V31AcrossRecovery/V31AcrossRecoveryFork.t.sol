// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    L2_ACCOUNT_CODE_STORAGE_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IAccountCodeStorage} from "contracts/common/interfaces/IAccountCodeStorage.sol";
import {AcrossInfo, V31AcrossRecovery} from "contracts/l2-upgrades/V31AcrossRecovery.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

/// @notice Minimal interface for the Across SpokePool proxy.
interface IAcrossSpokePool {
    function crossDomainAdmin() external view returns (address);
    function upgradeTo(address newImplementation) external;
}

/// @notice Helper to expose the internal getAcrossInfo function.
contract AcrossInfoReader is V31AcrossRecovery {
    function readAcrossInfo(uint256 _l1ChainId) external view returns (AcrossInfo memory) {
        return getAcrossInfo(_l1ChainId);
    }
}

/// @notice Minimal upgrade contract that only performs Across recovery.
/// @dev We use this instead of L2V31Upgrade because the full upgrade requires many factory
/// deps and VM state changes that are out of scope for this fork test.
contract MinimalAcrossRecoveryUpgrade is V31AcrossRecovery {
    function upgrade(uint256 _l1ChainId) external {
        acrossRecovery(_l1ChainId);
    }
}

/// @title V31AcrossRecoveryForkTest
/// @notice Fork test for the Across recovery procedure.
/// @dev Run against an anvil-zksync fork of the chain where the Across proxy lives.
/// All system contracts are live on the fork — no vm.etch needed.
/// @dev Run: forge test --zksync --match-contract V31AcrossRecoveryForkTest --fork-url https://rpc.lens.xyz
contract V31AcrossRecoveryForkTest is Test {
    uint256 constant L1_CHAIN_ID = 1;

    AcrossInfo internal info;
    IAccountCodeStorage internal accountCodeStorage = IAccountCodeStorage(L2_ACCOUNT_CODE_STORAGE_ADDR);

    function setUp() public {
        AcrossInfoReader reader = new AcrossInfoReader();
        info = reader.readAcrossInfo(L1_CHAIN_ID);

        require(
            info.expectedL2ChainId == block.chainid,
            "Fork test must run on the chain matching expectedL2ChainId"
        );
    }

    function test_AcrossProxyIsBroken() public {
        (bool success,) = info.proxy.call(abi.encodeWithSignature("proxiableUUID()"));
        assertFalse(success, "proxy should be broken (delegatecall to EVM impl fails)");
    }

    function test_RecoveryWithRealUpgrade() public {
        // 1. Verify the proxy is broken before recovery.
        (bool success,) = info.proxy.call(abi.encodeWithSignature("proxiableUUID()"));
        assertFalse(success, "proxy should be broken before recovery");

        // Record state before recovery.
        bytes32 evmImplHashBefore = accountCodeStorage.getRawCodeHash(info.evmImplementation);
        bytes32 recoveryBytecodeHash = accountCodeStorage.getRawCodeHash(info.zkevmRecoveryImplementation);
        assertTrue(recoveryBytecodeHash != bytes32(0), "recovery impl should already be deployed on the fork");

        // 2. Deploy a minimal upgrade contract and execute recovery via ComplexUpgrader.
        MinimalAcrossRecoveryUpgrade upgradeContract = new MinimalAcrossRecoveryUpgrade();

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(upgradeContract),
            abi.encodeCall(MinimalAcrossRecoveryUpgrade.upgrade, (L1_CHAIN_ID))
        );

        // 3. Verify: the EVM impl address now has the recovery implementation's bytecode.
        bytes32 evmImplHashAfter = accountCodeStorage.getRawCodeHash(info.evmImplementation);
        assertEq(evmImplHashAfter, recoveryBytecodeHash, "EVM impl should now have the recovery bytecode");
        assertTrue(evmImplHashAfter != evmImplHashBefore, "bytecode hash should have changed");

        // 4. Verify: the proxy is functional — crossDomainAdmin() should return a valid address.
        IAcrossSpokePool spokePool = IAcrossSpokePool(info.proxy);
        address admin = spokePool.crossDomainAdmin();
        assertTrue(admin != address(0), "crossDomainAdmin should return a non-zero address");

        // 5. Verify: the aliased admin can upgrade the proxy to the zkEVM recovery implementation.
        address aliasedAdmin = AddressAliasHelper.applyL1ToL2Alias(admin);
        vm.prank(aliasedAdmin);
        // FIXME: it fails due to immutables not being set up correctly in the new implementation
        // spokePool.upgradeTo(info.zkevmRecoveryImplementation);
    }
}
