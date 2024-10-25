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

import {L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {L2Utils} from "./L2Utils.sol";
import {SharedL2ContractL1DeployerUtils, SystemContractsArgs} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";

contract SharedL2ContractL2DeployerUtils is DeployUtils, SharedL2ContractL1DeployerUtils {
    using stdToml for string;

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual override {
        L2Utils.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual override returns (address) {
        console.log("Deploying via create2 L2");
        return L2Utils.deployViaCreat2L2(creationCode, constructorArgs, config.contracts.create2FactorySalt);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override(DeployUtils, SharedL2ContractL1DeployerUtils) {}
}
