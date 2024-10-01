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

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {SharedL2ContractL1DeployerUtils} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";
import {L2Utils, SystemContractsArgs} from "./L2Utils.sol";
import {SharedL2ContractL2DeployerUtils} from "./_SharedL2ContractL2DeployerUtils.sol";
import {L2Erc20TestAbstract} from "../../l1/integration/l2-tests-in-l1-context/L2Erc20TestAbstract.t.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";

contract L2Erc20Test is Test, L2Erc20TestAbstract, SharedL2ContractL2DeployerUtils {
    function test() internal virtual override(DeployUtils, SharedL2ContractL2DeployerUtils) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal override(SharedL2ContractDeployer, SharedL2ContractL2DeployerUtils) {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(DeployUtils, SharedL2ContractL2DeployerUtils) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public override(SharedL2ContractL1DeployerUtils, SharedL2ContractDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }
}
