// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL1Messenger} from "contracts/common/interfaces/IL1Messenger.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
import {L2SharedBridgeLegacyDev} from "contracts/dev-contracts/L2SharedBridgeLegacyDev.sol";

import {AssetRouter_ActorHandler_Deployer} from "../deployers/AssetRouter_ActorHandler_Deployer.sol";
import {AssetRouter_Token_Deployer} from "../deployers/AssetRouter_Token_Deployer.sol";
import {AssetRouterProperties} from "../properties/AssetRouterProperties.sol";
import {Token, ActorHandlerAddresses} from "../common/Types.sol";

import {SharedL2ContractL1DeployerUtils, SystemContractsArgs} from "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";
import {SharedL2ContractDeployer} from "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";

contract AssetRouterTest is
    Test,
    SharedL2ContractL1DeployerUtils,
    SharedL2ContractDeployer,
    AssetRouterProperties,
    AssetRouter_ActorHandler_Deployer,
    AssetRouter_Token_Deployer
{
    function test() internal virtual override(DeployUtils, SharedL2ContractL1DeployerUtils) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal virtual override(SharedL2ContractDeployer, SharedL2ContractL1DeployerUtils) {
        super.initSystemContracts(_args);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public virtual override(SharedL2ContractDeployer, SharedL2ContractL1DeployerUtils) {
        super.deployL2Contracts(_l1ChainId);

        vm.label(L2_ASSET_ROUTER_ADDR, "L2AssetRouter");
        vm.label(L2_NATIVE_TOKEN_VAULT_ADDR, "L2NativeTokenVault");
        vm.label(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, "L1Messenger");

        Token[] memory deployedTokens = _deployTokens();
        ActorHandlerAddresses memory actorHandlerAddresses = deployActorHandlers(deployedTokens);

        assertEq(deployedTokens.length, 6);

        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(IL1Messenger.sendToL1.selector),
            abi.encode(1337)
        );

        initAssetRouterProperties(deployedTokens, actorHandlerAddresses);
    }

    function deployL2SharedBridgeLegacy(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1SharedBridge,
        bytes32 _l2TokenProxyBytecodeHash
    ) internal virtual override returns (address) {
        L2SharedBridgeLegacyDev bridge = new L2SharedBridgeLegacyDev();
        console.log("bridge", address(bridge));
        address proxyAdmin = address(0x1);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(bridge),
            proxyAdmin,
            abi.encodeCall(L2SharedBridgeLegacy.initialize, (_l1SharedBridge, _l2TokenProxyBytecodeHash, _aliasedOwner))
        );
        console.log("proxy", address(proxy));
        return address(proxy);
    }
}
