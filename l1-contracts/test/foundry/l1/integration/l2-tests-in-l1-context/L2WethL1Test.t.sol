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

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {SharedL2ContractDeployer} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {SharedL2ContractL1Deployer, SystemContractsArgs} from "./_SharedL2ContractL1Deployer.sol";

import {L2WethTestAbstract} from "../l2-tests-abstract/L2WethTestAbstract.t.sol";

import {StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {DeployCTMUtils} from "deploy-scripts/ctm/DeployCTMUtils.s.sol";

contract L2WethL1Test is Test, SharedL2ContractL1Deployer, L2WethTestAbstract {
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

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (Diamond.FacetCut[] memory) {
        return super.getChainCreationFacetCuts(stateTransition);
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (Diamond.FacetCut[] memory) {
        return super.getUpgradeAddedFacetCuts(stateTransition);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override(DeployIntegrationUtils, SharedL2ContractL1Deployer) returns (bytes memory) {
        return super.getInitializeCalldata(contractName, isZKBytecode);
    }
}
