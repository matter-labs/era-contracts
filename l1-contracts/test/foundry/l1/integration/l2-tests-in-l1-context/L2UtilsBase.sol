// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {StdStorage, stdStorage, stdToml} from "forge-std/Test.sol";

import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/core/ctm-deployment/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {GW_ASSET_TRACKER_ADDR, L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_INTEROP_ROOT_STORAGE, L2_MESSAGE_ROOT_ADDR, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_INTEROP_ACCOUNT_ADDR, L2_STANDARD_TRIGGER_ACCOUNT_ADDR} from "../l2-tests-abstract/Utils.sol";

import {L2MessageRoot} from "contracts/core/message-root/L2MessageRoot.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {L2NativeTokenVaultDev} from "contracts/dev-contracts/test/L2NativeTokenVaultDev.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {L2MessageVerification} from "../../../../../contracts/interop/L2MessageVerification.sol";
import {DummyL2InteropRootStorage} from "../../../../../contracts/dev-contracts/test/DummyL2InteropRootStorage.sol";

import {InteropCenter} from "../../../../../contracts/interop/InteropCenter.sol";
import {InteropHandler} from "../../../../../contracts/interop/InteropHandler.sol";
import {DummyL2L1Messenger} from "../../../../../contracts/dev-contracts/test/DummyL2L1Messenger.sol";

import {DummyL2StandardTriggerAccount} from "../../../../../contracts/dev-contracts/test/DummyL2StandardTriggerAccount.sol";
import {DummyL2BaseTokenSystemContract} from "../../../../../contracts/dev-contracts/test/DummyBaseTokenSystemContract.sol";
import {DummyL2InteropAccount} from "../../../../../contracts/dev-contracts/test/DummyL2InteropAccount.sol";

import {SystemContractsArgs} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {TokenMetadata, TokenBridgingData} from "contracts/common/Messaging.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

library L2UtilsBase {
    using stdToml for string;
    using stdStorage for StdStorage;

    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @dev We provide a fast form of debugging the L2 contracts using L1 foundry. We also test using zk foundry.
    function initSystemContracts(SystemContractsArgs memory _args) internal {
        // Variables that will be used across multiple scopes
        bytes32 baseTokenAssetId;
        address wethToken;

        // Initialize variables in a scoped block to avoid stack too deep
        {
            baseTokenAssetId = DataEncoding.encodeNTVAssetId(_args.l1ChainId, ETH_TOKEN_ADDRESS);
            wethToken = address(0x1);
        }

        {
            address bridgehub = address(new L2Bridgehub());
            vm.etch(L2_BRIDGEHUB_ADDR, bridgehub.code);
            address interopCenter = address(new InteropCenter());
            vm.etch(L2_INTEROP_CENTER_ADDR, interopCenter.code);
            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            InteropCenter(L2_INTEROP_CENTER_ADDR).initL2(
                _args.l1ChainId,
                _args.aliasedOwner,
                DataEncoding.encodeNTVAssetId(324, address(0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E))
            );
        }

        {
            address messageRoot = address(new L2MessageRoot());
            vm.etch(L2_MESSAGE_ROOT_ADDR, messageRoot.code);
            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            L2MessageRoot(L2_MESSAGE_ROOT_ADDR).initL2(_args.l1ChainId, _args.gatewayChainId);
        }

        {
            uint256 prevChainId = block.chainid;
            vm.chainId(_args.l1ChainId);

            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            L2Bridgehub(L2_BRIDGEHUB_ADDR).initL2(_args.l1ChainId, _args.aliasedOwner, _args.maxNumberOfZKChains);
            vm.chainId(prevChainId);

            vm.prank(_args.aliasedOwner);
            address aliasedL1ChainRegistrationSender = address(0x000000000000000000000000000000000002000a);
            L2Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses(
                L2_ASSET_ROUTER_ADDR,
                ICTMDeploymentTracker(_args.l1CtmDeployer),
                IMessageRoot(L2_MESSAGE_ROOT_ADDR),
                L2_CHAIN_ASSET_HANDLER_ADDR,
                aliasedL1ChainRegistrationSender
            );
        }

        {
            address l2messageVerification = address(new L2MessageVerification());
            vm.etch(address(L2_MESSAGE_VERIFICATION), l2messageVerification.code);
            address l2MessageRootStorage = address(new DummyL2InteropRootStorage());
            vm.etch(address(L2_INTEROP_ROOT_STORAGE), l2MessageRootStorage.code);
            address l2ChainAssetHandler = address(new L2ChainAssetHandler());
            vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, l2ChainAssetHandler.code);

            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).initL2(
                _args.l1ChainId,
                _args.aliasedOwner,
                L2_BRIDGEHUB_ADDR,
                L2_ASSET_ROUTER_ADDR,
                L2_MESSAGE_ROOT_ADDR
            );
        }
        {
            address interopHandler = address(new InteropHandler());
            vm.etch(L2_INTEROP_HANDLER_ADDR, interopHandler.code);
            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            InteropHandler(L2_INTEROP_HANDLER_ADDR).initL2(_args.l1ChainId);

            address l2AssetTrackerAddress = address(new L2AssetTracker());
            vm.etch(L2_ASSET_TRACKER_ADDR, l2AssetTrackerAddress.code);
            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).setAddresses(_args.l1ChainId, bytes32(0));

            address gwAssetTrackerAddress = address(new GWAssetTracker());
            vm.etch(GW_ASSET_TRACKER_ADDR, gwAssetTrackerAddress.code);
            // Note: GWAssetTracker.setAddresses is called later, after NTV is deployed,
            // because it fetches wrappedZKToken from NTV.WETH_TOKEN()
        }
        {
            address l2StandardTriggerAccount = address(new DummyL2StandardTriggerAccount());
            vm.etch(L2_STANDARD_TRIGGER_ACCOUNT_ADDR, l2StandardTriggerAccount.code);
            address l2InteropAccount = address(new DummyL2InteropAccount());
            vm.etch(L2_INTEROP_ACCOUNT_ADDR, l2InteropAccount.code);
        }

        {
            address l2DummyBaseTokenSystemContract = address(new DummyL2BaseTokenSystemContract());
            vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, l2DummyBaseTokenSystemContract.code);
        }

        // DummyL2L1Messenger dummyL2L1Messenger = new DummyL2L1Messenger();
        // vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(dummyL2L1Messenger).code);
        {
            address assetRouter = address(new L2AssetRouter());
            vm.etch(L2_ASSET_ROUTER_ADDR, assetRouter.code);
            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            L2AssetRouter(L2_ASSET_ROUTER_ADDR).initL2(
                _args.l1ChainId,
                _args.eraChainId,
                IL1AssetRouter(_args.l1AssetRouter),
                IL2SharedBridgeLegacy(_args.legacySharedBridge),
                baseTokenAssetId,
                _args.aliasedOwner
            );
        }

        {
            // Initializing reentrancy guard
            // stdstore.target(address(L2_ASSET_ROUTER_ADDR)).sig("l1AssetRouter()").checked_write(_args.l1AssetRouter);
            vm.store(
                L2_ASSET_ROUTER_ADDR,
                bytes32(0x8e94fed44239eb2314ab7a406345e6c5a8f0ccedf3b600de3d004e672c33abf4),
                bytes32(uint256(1))
            );
        }

        {
            address ntv = address(new L2NativeTokenVaultDev());
            vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, ntv.code);

            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).initL2(
                _args.l1ChainId,
                _args.aliasedOwner,
                _args.l2TokenProxyBytecodeHash,
                _args.legacySharedBridge,
                _args.l2TokenBeacon,
                wethToken,
                TokenBridgingData({
                    assetId: baseTokenAssetId,
                    originChainId: _args.l1ChainId,
                    originToken: ETH_TOKEN_ADDRESS
                }),
                TokenMetadata({name: "Ether", symbol: "ETH", decimals: 18})
            );

            vm.store(
                L2_NATIVE_TOKEN_VAULT_ADDR,
                bytes32(uint256(251)),
                bytes32(uint256(_args.l2TokenProxyBytecodeHash))
            );
            L2NativeTokenVaultDev(L2_NATIVE_TOKEN_VAULT_ADDR).deployBridgedStandardERC20(_args.aliasedOwner);
        }

        // Initialize GWAssetTracker after NTV is deployed (needs WETH_TOKEN)
        {
            // Deploy a real ERC20 token for the wrapped ZK token BEFORE setting up GWAssetTracker
            TestnetERC20Token wrappedZKToken = new TestnetERC20Token("Wrapped ZK", "WZK", 18);
            address wrappedZKTokenAddr = address(wrappedZKToken);

            // Mock L2_NATIVE_TOKEN_VAULT.WETH_TOKEN() to return our token BEFORE setAddresses
            vm.mockCall(
                L2_NATIVE_TOKEN_VAULT_ADDR,
                abi.encodeWithSelector(IL2NativeTokenVault.WETH_TOKEN.selector),
                abi.encode(wrappedZKTokenAddr)
            );

            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            GWAssetTracker(GW_ASSET_TRACKER_ADDR).setAddresses(_args.l1ChainId);

            // Set a small settlement fee for testing fee collection logic
            uint256 settlementFee = 0.001 ether; // Small fee for testing
            vm.prank(GWAssetTracker(GW_ASSET_TRACKER_ADDR).owner());
            GWAssetTracker(GW_ASSET_TRACKER_ADDR).setGatewaySettlementFee(settlementFee);
        }
    }

    /// @notice Sets up token balances and approvals for chain operators to pay settlement fees
    /// @param chainIds Array of chain IDs whose operators need token balances
    function setupTokenBalancesForChainOperators(uint256[] memory chainIds) internal {
        // Get the wrapped ZK token address directly from the GWAssetTracker
        address wrappedZKTokenAddr = address(GWAssetTracker(GW_ASSET_TRACKER_ADDR).wrappedZKToken());

        if (wrappedZKTokenAddr == address(0)) {
            return; // No token set up, skip
        }

        TestnetERC20Token wrappedZKToken = TestnetERC20Token(wrappedZKTokenAddr);
        uint256 tokenAmount = 1000 ether; // Plenty of tokens for testing

        for (uint256 i = 0; i < chainIds.length; i++) {
            address chainOperator = L2Bridgehub(L2_BRIDGEHUB_ADDR).getZKChain(chainIds[i]);
            if (chainOperator != address(0)) {
                // Mint tokens to the chain operator
                wrappedZKToken.mint(chainOperator, tokenAmount);

                // Approve GWAssetTracker to spend tokens on behalf of the chain operator
                vm.prank(chainOperator);
                wrappedZKToken.approve(GW_ASSET_TRACKER_ADDR, type(uint256).max);

                // Agree to pay settlement fees for this chain
                vm.prank(chainOperator);
                GWAssetTracker(GW_ASSET_TRACKER_ADDR).agreeToPaySettlementFees(chainIds[i]);
            }
        }
    }
}
