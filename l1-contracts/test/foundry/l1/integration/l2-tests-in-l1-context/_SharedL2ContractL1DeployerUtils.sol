// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {DeployedAddresses, Config} from "deploy-scripts/DeployUtils.s.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";

import {L2_MESSAGE_ROOT_ADDR, L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2NativeTokenVaultDev} from "contracts/dev-contracts/test/L2NativeTokenVaultDev.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";

struct SystemContractsArgs {
    uint256 l1ChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    address legacySharedBridge;
    address l2TokenBeacon;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedOwner;
    bool contractsDeployedAlready;
    address l1CtmDeployer;
}

contract SharedL2ContractL1DeployerUtils is DeployUtils {
    using stdToml for string;
    using stdStorage for StdStorage;

    /// @dev We provide a fast form of debugging the L2 contracts using L1 foundry. We also test using zk foundry.
    function initSystemContracts(SystemContractsArgs memory _args) internal virtual {
        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(_args.l1ChainId, ETH_TOKEN_ADDRESS);
        address wethToken = address(0x1);
        // we deploy the code to get the contract code with immutables which we then vm.etch
        address messageRoot = address(new MessageRoot(IBridgehub(L2_BRIDGEHUB_ADDR)));
        address bridgehub = address(new Bridgehub(_args.l1ChainId, _args.aliasedOwner, 100));
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
        uint256 prevChainId = block.chainid;
        vm.chainId(_args.l1ChainId);
        Bridgehub(L2_BRIDGEHUB_ADDR).initialize(_args.aliasedOwner);
        vm.chainId(prevChainId);
        vm.prank(_args.aliasedOwner);
        Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses(
            L2_ASSET_ROUTER_ADDR,
            ICTMDeploymentTracker(_args.l1CtmDeployer),
            IMessageRoot(L2_MESSAGE_ROOT_ADDR)
        );

        vm.etch(L2_ASSET_ROUTER_ADDR, assetRouter.code);

        stdstore
            .target(L2_ASSET_ROUTER_ADDR)
            .sig("assetHandlerAddress(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(bytes32(uint256(uint160(L2_NATIVE_TOKEN_VAULT_ADDR))));

        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, ntv.code);

        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, bytes32(uint256(251)), bytes32(uint256(_args.l2TokenProxyBytecodeHash)));
        L2NativeTokenVaultDev(L2_NATIVE_TOKEN_VAULT_ADDR).deployBridgedStandardERC20(_args.aliasedOwner);
    }

    function deployL2Contracts(uint256 _l1ChainId) public virtual {
        string memory root = vm.projectRoot();
        string memory inputPath = string.concat(
            root,
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml"
        );
        initializeConfig(inputPath);
        addresses.transparentProxyAdmin = address(0x1);
        addresses.bridgehub.bridgehubProxy = L2_BRIDGEHUB_ADDR;
        addresses.bridges.sharedBridgeProxy = L2_ASSET_ROUTER_ADDR;
        addresses.vaults.l1NativeTokenVaultProxy = L2_NATIVE_TOKEN_VAULT_ADDR;
        addresses.blobVersionedHashRetriever = address(0x1);
        config.l1ChainId = _l1ChainId;
        console.log("Deploying L2 contracts");
        instantiateCreate2Factory();
        deployGenesisUpgrade();
        deployVerifier();
        deployValidatorTimelock();
        deployChainTypeManagerContract(address(0));
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
