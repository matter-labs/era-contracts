// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ZeroAddress, ZeroChainId} from "contracts/common/L1ContractErrors.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {EraMaintenanceTransactionFilterer} from "contracts/transactionFilterer/EraMaintenanceTransactionFilterer.sol";
import {
    CallMode,
    IEraMaintenanceTransactionFilterer
} from "contracts/transactionFilterer/interfaces/IEraMaintenanceTransactionFilterer.sol";
import {
    IEraL2AssetRouter,
    IEraL2BaseToken,
    IEraL2LegacyBridge
} from "contracts/transactionFilterer/interfaces/IEraL2Legacy.sol";

import {EraMaintenanceTransactionFiltererTest} from "./_EraMaintenanceTransactionFilterer_Shared.t.sol";

contract InitializeTest is EraMaintenanceTransactionFiltererTest {
    function test_constructorReadsAssetRouterFromBridgehub() public view {
        assertEq(address(filterer.BRIDGE_HUB()), bridgehub);
        assertEq(filterer.L1_ASSET_ROUTER(), l1AssetRouter);
    }

    function test_initializeSetsPermissiveConfiguration() public view {
        assertEq(filterer.owner(), owner);
        assertEq(filterer.chainId(), CHAIN_ID);
        assertEq(uint256(filterer.callMode()), uint256(CallMode.ALLOW_ALL));
        assertEq(filterer.depositCap(baseTokenAssetId), type(uint256).max);
        // No token other than the base token is accepted until the owner sets its cap.
        assertEq(filterer.depositCap(tokenAssetId), 0);

        assertTrue(filterer.withdrawalFunctions(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, IEraL2BaseToken.withdraw.selector));
        assertTrue(
            filterer.withdrawalFunctions(
                L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
                IEraL2BaseToken.withdrawWithMessage.selector
            )
        );
        assertTrue(filterer.withdrawalFunctions(L2_ASSET_ROUTER_ADDR, IEraL2AssetRouter.withdraw.selector));
        assertTrue(filterer.withdrawalFunctions(L2_ASSET_ROUTER_ADDR, IEraL2LegacyBridge.withdraw.selector));
    }

    function test_initializeEmitsConfigurationEvents() public {
        vm.expectEmit(true, false, false, true);
        emit IEraMaintenanceTransactionFilterer.DepositCapSet(baseTokenAssetId, type(uint256).max);
        vm.expectEmit(true, true, false, true);
        emit IEraMaintenanceTransactionFilterer.WithdrawalFunctionSet(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            IEraL2BaseToken.withdraw.selector,
            true
        );
        _deployProxy(owner, CHAIN_ID);
    }

    function test_revertWhen_ownerIsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        _deployProxy(address(0), CHAIN_ID);
    }

    function test_revertWhen_chainIdIsZero() public {
        vm.expectRevert(ZeroChainId.selector);
        _deployProxy(owner, 0);
    }

    function test_revertWhen_initializedTwice() public {
        vm.expectRevert("Initializable: contract is already initialized");
        filterer.initialize(owner, CHAIN_ID);
    }

    function test_revertWhen_initializingImplementation() public {
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.initialize(owner, CHAIN_ID);
    }

    function _deployProxy(address _owner, uint256 _chainId) internal returns (address) {
        return
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    proxyAdmin,
                    abi.encodeCall(EraMaintenanceTransactionFilterer.initialize, (_owner, _chainId))
                )
            );
    }
}
