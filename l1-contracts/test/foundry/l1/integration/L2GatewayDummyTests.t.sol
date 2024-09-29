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

import {L2ContractDummyDeployer} from "./_SharedL2ContractDummyDeployer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SystemContractsArgs} from "./_SharedL2ContractDummyDeployer.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2GatewayTestsAbstract} from "./L2GatewayTestsAbstract.t.sol";

contract L2GatewayDummyTests is Test, L2ContractDummyDeployer, L2GatewayTestsAbstract {
    function test() internal virtual override(DeployUtils, L2ContractDummyDeployer) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal virtual override(L2GatewayTestsAbstract, L2ContractDummyDeployer) {
        super.initSystemContracts(_args);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public virtual override(L2GatewayTestsAbstract, L2ContractDummyDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }
}
