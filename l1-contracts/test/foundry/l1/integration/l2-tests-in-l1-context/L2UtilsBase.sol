// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";
import {StdStorage, stdStorage, stdToml, Test} from "forge-std/Test.sol";

import {L2_MESSAGE_ROOT_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_STANDARD_TRIGGER_ACCOUNT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_ASSET_TRACKER_ADDR, L2_MESSAGE_VERIFICATION, L2_MESSAGE_ROOT_STORAGE} from "../../../../../contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../../../../contracts/common/libraries/DataEncoding.sol";

import {Bridgehub, IBridgehub} from "../../../../../contracts/bridgehub/Bridgehub.sol";
import {InteropCenter, IInteropCenter} from "../../../../../contracts/bridgehub/InteropCenter.sol";
import {InteropHandler, IInteropHandler} from "../../../../../contracts/bridgehub/InteropHandler.sol";
import {MessageRoot} from "../../../../../contracts/bridgehub/MessageRoot.sol";
import {L2AssetRouter} from "../../../../../contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "../../../../../contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2NativeTokenVaultDev} from "../../../../../contracts/dev-contracts/test/L2NativeTokenVaultDev.sol";
import {DummyL2L1Messenger} from "../../../../../contracts/dev-contracts/test/DummyL2L1Messenger.sol";
import {ETH_TOKEN_ADDRESS} from "../../../../../contracts/common/Config.sol";
import {IMessageRoot} from "../../../../../contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "../../../../../contracts/bridgehub/ICTMDeploymentTracker.sol";
import {L2MessageVerification} from "../../../../../contracts/bridgehub/L2MessageVerification.sol";
import {DummyL2MessageRootStorage} from "../../../../../contracts/dev-contracts/test/DummyL2MessageRootStorage.sol";
import {DummyL2StandardTriggerAccount} from "../../../../../contracts/dev-contracts/test/DummyL2StandardTriggerAccount.sol";

import {Utils} from "../../../../../deploy-scripts/Utils.sol";
import {SystemContractsArgs} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";

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
        address messageRoot = address(new MessageRoot(IBridgehub(L2_BRIDGEHUB_ADDR)));
        address bridgehub = address(new Bridgehub(_args.l1ChainId, _args.aliasedOwner, 100));
        address interopCenter = address(
            new InteropCenter(IBridgehub(L2_BRIDGEHUB_ADDR), _args.l1ChainId, _args.aliasedOwner)
        );
        address assetRouter = address(
            new L2AssetRouter(
                _args.l1ChainId,
                _args.eraChainId,
                _args.l1AssetRouter,
                _args.legacySharedBridge,
                baseTokenAssetId,
                _args.aliasedOwner
            )
        );
        address ntv = address(
            new L2NativeTokenVaultDev(
                _args.l1ChainId,
                _args.aliasedOwner,
                _args.l2TokenProxyBytecodeHash,
                _args.legacySharedBridge,
                _args.l2TokenBeacon,
                _args.contractsDeployedAlready,
                wethToken,
                baseTokenAssetId
            )
        );
        vm.etch(L2_MESSAGE_ROOT_ADDR, messageRoot.code);
        MessageRoot(L2_MESSAGE_ROOT_ADDR).initialize();

        vm.etch(L2_BRIDGEHUB_ADDR, bridgehub.code);
        vm.etch(L2_INTEROP_CENTER_ADDR, interopCenter.code);
        {
            address interopHandler = address(new InteropHandler());
            vm.etch(L2_INTEROP_HANDLER_ADDR, interopHandler.code);
            address l2messageVerification = address(new L2MessageVerification());
            vm.etch(address(L2_MESSAGE_VERIFICATION), l2messageVerification.code);
            address l2MessageRootStorage = address(new DummyL2MessageRootStorage());
            vm.etch(address(L2_MESSAGE_ROOT_STORAGE), l2MessageRootStorage.code);
            address l2StandardTriggerAccount = address(new DummyL2StandardTriggerAccount());
            vm.etch(L2_STANDARD_TRIGGER_ACCOUNT_ADDR, l2StandardTriggerAccount.code);
        }
        uint256 prevChainId = block.chainid;
        vm.chainId(_args.l1ChainId);
        Bridgehub(L2_BRIDGEHUB_ADDR).initialize(_args.aliasedOwner);
        vm.chainId(prevChainId);
        vm.prank(_args.aliasedOwner);
        Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses(
            L2_ASSET_ROUTER_ADDR,
            ICTMDeploymentTracker(_args.l1CtmDeployer),
            IMessageRoot(L2_MESSAGE_ROOT_ADDR),
            L2_INTEROP_CENTER_ADDR,
            L2_ASSET_TRACKER_ADDR
        );
        vm.prank(_args.aliasedOwner);
        vm.chainId(_args.l1ChainId);
        Bridgehub(L2_INTEROP_CENTER_ADDR).initialize(_args.aliasedOwner);
        vm.chainId(prevChainId);
        vm.prank(_args.aliasedOwner);
        IInteropCenter(L2_INTEROP_CENTER_ADDR).setAddresses(L2_ASSET_ROUTER_ADDR);

        // DummyL2L1Messenger dummyL2L1Messenger = new DummyL2L1Messenger();
        // vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(dummyL2L1Messenger).code);

        vm.etch(L2_ASSET_ROUTER_ADDR, assetRouter.code);

        // Initializing reentrancy guard
        // stdstore.target(address(L2_ASSET_ROUTER_ADDR)).sig("l1AssetRouter()").checked_write(_args.l1AssetRouter);
        vm.store(
            L2_ASSET_ROUTER_ADDR,
            bytes32(0x8e94fed44239eb2314ab7a406345e6c5a8f0ccedf3b600de3d004e672c33abf4),
            bytes32(uint256(1))
        );

        // stdstore.target(address(L2_ASSET_ROUTER_ADDR)).sig("l1AssetRouter()").checked_write(_args.l1AssetRouter);

        // stdstore
        //     .target(L2_ASSET_ROUTER_ADDR)
        //     .sig("assetHandlerAddress(bytes32)")
        //     .with_key(baseTokenAssetId)
        //     .checked_write(bytes32(uint256(uint160(L2_NATIVE_TOKEN_VAULT_ADDR))));

        // bytes memory ntvBytecode = Utils.readL1ContractsBytecode("bridge/ntv/", "L2NativeTokenVault");
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, ntv.code);

        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, bytes32(uint256(251)), bytes32(uint256(_args.l2TokenProxyBytecodeHash)));
        L2NativeTokenVaultDev(L2_NATIVE_TOKEN_VAULT_ADDR).deployBridgedStandardERC20(_args.aliasedOwner);
    }
}
