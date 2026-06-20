// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2Utils, SystemContractsArgs} from "./L2Utils.sol";
import {SharedL2ContractL2Deployer} from "./_SharedL2ContractL2Deployer.sol";
import {L2Erc20TestAbstract} from "../../l1/integration/l2-tests-abstract/L2Erc20TestAbstract.t.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {DeployIntegrationUtils} from "../../l1/integration/deploy-scripts/DeployIntegrationUtils.s.sol";
import {Create2FactoryUtils} from "deploy-scripts/Create2FactoryUtils.s.sol";

contract L2Erc20Test is Test, L2Erc20TestAbstract, SharedL2ContractL2Deployer {
    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(Create2FactoryUtils, SharedL2ContractL2Deployer) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public override(SharedL2ContractL2Deployer, SharedL2ContractDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }
}
