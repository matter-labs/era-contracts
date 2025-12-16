// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {Call} from "contracts/governance/Common.sol";

import {L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

import {DefaultEcosystemUpgrade} from "../default_upgrade/DefaultEcosystemUpgrade.s.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";

/// @notice Script used for v31 upgrade flow
contract CombinedUpgrade_v31 is Script {
    function run() public {
        // Run the CTM upgrade
        CTMUpgrade_v31 ctmUpgrade = new CTMUpgrade_v31();
        ctmUpgrade.run();

        // Run the Ecosystem upgrade
        EcosystemUpgrade_v31 ecosystemUpgrade = new EcosystemUpgrade_v31();
        ecosystemUpgrade.run();
    }
}

contract FullV31Upgrade is Script {
    EcosystemUpgrade_v31 ecosystemUpgrade;
    CTMUpgrade_v31 ctmUpgrade;
    GatewayUpgrade_v31 gatewayUpgrade;

    function run() external {
        ecosystemUpgrade = new EcosystemUpgrade_v31();
        ecosystemUpgrade.run();

        ctmUpgrade = new CTMUpgrade_v31();
        ctmUpgrade.run();

        gatewayUpgrade = new GatewayUpgrade_v31();
        gatewayUpgrade.run();
    }

    // function saveAllBridgedTokens(address _bridgehub) public {
    //     //// We need to save all bridged tokens
    //// i.e. add them to the bridged tokens list in the L1 NTV
    // }
    function registerBridgedTokensInNTV(address _bridgehub) public {
        NativeTokenVaultBase ntv = NativeTokenVaultBase(
            address(IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault())
        );
        address[] memory savedBridgedTokens;
        /// todo get save bridged tokens.
        /// for tokens in the bridged token list
        for (uint256 i = 0; i < savedBridgedTokens.length; ++i) {
            // TODO it's cludge to convert from bytes32 to address, need to have proper solution
            address token = address(uint160(uint256(ntv.bridgedTokens(i))));
            ntv.addLegacyTokenToBridgedTokensList(token);
        }
    }
}
