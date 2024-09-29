// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

// import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
// import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {L2Utils} from "../unit/utils/L2Utils.sol";
import {SystemContractsArgs} from "../unit/utils/L2Utils.sol";

import {L2ContractDeployer} from "./_SharedL2ContractDeployer.t.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2GatewayTestsAbstract} from "../../l1/integration/L2GatewayTestsAbstract.t.sol";
import {L2ContractDummyDeployer} from "../../l1/integration/_SharedL2ContractDummyDeployer.sol";

contract L2GatewayTests is Test, L2GatewayTestsAbstract, L2ContractDeployer {
    // We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
    // It is a bit easier to use EOA and it is sufficient for the tests.
    function test() internal virtual override(DeployUtils, L2ContractDeployer) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal override(L2GatewayTestsAbstract, L2ContractDeployer) {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(DeployUtils, L2ContractDeployer) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(uint256 _l1ChainId) public override(L2GatewayTestsAbstract, L2ContractDummyDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }
}
