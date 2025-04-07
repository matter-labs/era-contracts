// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SystemContractsArgs} from "./_SharedL2ContractL1Deployer.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2GatewayTestAbstract} from "./L2GatewayTestAbstract.t.sol";
import {SharedL2ContractL1Deployer} from "./_SharedL2ContractL1Deployer.sol";

import {StateTransitionDeployedAddresses, FacetCut} from "deploy-scripts/Utils.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";

contract L2GatewayL1Test is Test, SharedL2ContractL1Deployer, L2GatewayTestAbstract {
    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL1Deployer) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal virtual override(SharedL2ContractDeployer, SharedL2ContractL1Deployer) {
        super.initSystemContracts(_args);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public virtual override(SharedL2ContractDeployer, SharedL2ContractL1Deployer) {
        super.deployL2Contracts(_l1ChainId);
    }

    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (FacetCut[] memory) {
        return super.getFacetCuts(stateTransition);
    }

    function getCreationCode(
        string memory contractName
    ) internal view virtual override(DeployUtils, SharedL2ContractL1Deployer) returns (bytes memory) {
        return super.getCreationCode(contractName);
    }

    function getInitializeCalldata(
        string memory contractName
    ) internal virtual override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (bytes memory) {
        return super.getInitializeCalldata(contractName);
    }
}
