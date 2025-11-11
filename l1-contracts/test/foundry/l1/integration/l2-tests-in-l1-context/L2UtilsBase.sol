// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {StdStorage, Test, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {L2Bridgehub} from "contracts/bridgehub/L2Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Config, DeployUtils, DeployedAddresses} from "deploy-scripts/DeployUtils.s.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_INTEROP_ROOT_STORAGE, L2_MESSAGE_ROOT_ADDR, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L2MessageRoot} from "contracts/bridgehub/L2MessageRoot.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2ChainAssetHandler} from "contracts/bridgehub/L2ChainAssetHandler.sol";
import {L2NativeTokenVaultDev} from "contracts/dev-contracts/test/L2NativeTokenVaultDev.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {L2MessageVerification} from "../../../../../contracts/bridgehub/L2MessageVerification.sol";
import {DummyL2InteropRootStorage} from "../../../../../contracts/dev-contracts/test/DummyL2InteropRootStorage.sol";

import {DeployCTMIntegrationScript} from "../deploy-scripts/DeployCTMIntegration.s.sol";

import {SharedL2ContractDeployer, SystemContractsArgs} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

library L2UtilsBase {
    using stdToml for string;
    using stdStorage for StdStorage;

    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @dev We provide a fast form of debugging the L2 contracts using L1 foundry. We also test using zk foundry.
    function initSystemContracts(SystemContractsArgs memory _args) internal {
        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(_args.l1ChainId, ETH_TOKEN_ADDRESS);
        address wethToken = address(0x1);
        // we deploy the code to get the contract code with immutables which we then vm.etch
        address messageRoot = address(new L2MessageRoot());
        address bridgehub = address(new L2Bridgehub());
        address assetRouter = address(new L2AssetRouter());
        address ntv = address(new L2NativeTokenVaultDev());

        vm.etch(L2_MESSAGE_ROOT_ADDR, messageRoot.code);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2MessageRoot(L2_MESSAGE_ROOT_ADDR).initL2(_args.l1ChainId);

        vm.etch(L2_BRIDGEHUB_ADDR, bridgehub.code);
        uint256 prevChainId = block.chainid;
        vm.chainId(_args.l1ChainId);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).initL2(_args.l1ChainId, _args.aliasedOwner, _args.maxNumberOfZKChains);
        vm.chainId(prevChainId);
        vm.prank(_args.aliasedOwner);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses(
            L2_ASSET_ROUTER_ADDR,
            ICTMDeploymentTracker(_args.l1CtmDeployer),
            IMessageRoot(L2_MESSAGE_ROOT_ADDR),
            L2_CHAIN_ASSET_HANDLER_ADDR
        );

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

        vm.etch(L2_ASSET_ROUTER_ADDR, assetRouter.code);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2AssetRouter(L2_ASSET_ROUTER_ADDR).initL2(
            _args.l1ChainId,
            _args.eraChainId,
            _args.l1AssetRouter,
            _args.legacySharedBridge,
            baseTokenAssetId,
            _args.aliasedOwner
        );

        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, ntv.code);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).initL2(
            _args.l1ChainId,
            _args.aliasedOwner,
            _args.l2TokenProxyBytecodeHash,
            _args.legacySharedBridge,
            _args.l2TokenBeacon,
            wethToken,
            baseTokenAssetId
        );

        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, bytes32(uint256(251)), bytes32(uint256(_args.l2TokenProxyBytecodeHash)));
        L2NativeTokenVaultDev(L2_NATIVE_TOKEN_VAULT_ADDR).deployBridgedStandardERC20(_args.aliasedOwner);
    }
}
