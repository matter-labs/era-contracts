// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";


import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {Call} from "contracts/governance/Common.sol";

import {L2_COMPLEX_UPGRADER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

import {DefaultEcosystemUpgrade} from "../upgrade/DefaultEcosystemUpgrade.s.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";

/// @notice Script used for v30 upgrade flow
contract EcosystemUpgrade_v30 is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(vm.envString("UPGRADE_ECOSYSTEM_INPUT"), vm.envString("UPGRADE_ECOSYSTEM_OUTPUT"));
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
    }

    // function saveAllBridgedTokens(address _bridgehub) public {
    //     //// We need to save all bridged tokens
    //// i.e. add them to the bridged tokens list in the L1 NTV
    // }

    function registerBridgedTokensInNTV(address _bridgehub) public {
        INativeTokenVault ntv = INativeTokenVault(IBridgehub(_bridgehub).assetRouter().nativeTokenVault());
        address[] memory savedBridgedTokens;
        /// todo get save bridged tokens.
        /// for tokens in the bridged token list
        for (uint256 i = 0; i < savedBridgedTokens.length; ++i) {
            address token = ntv.bridgedTokens(i);
            ntv.addLegacyTokenToBridgedTokensList(token);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          Internal functions
    //////////////////////////////////////////////////////////////*/

    function _getL2UpgradeTargetAndData(
        IL2ContractDeployer.ForceDeployment[] memory _forceDeployments
    ) internal override returns (address, bytes memory) {
        bytes32 ethAssetId = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy).ETH_TOKEN_ASSET_ID();
        bytes memory v29UpgradeCalldata = abi.encodeCall(
            IL2V29Upgrade.upgrade,
            (AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress), ethAssetId)
        );
        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (_forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, v29UpgradeCalldata)
            )
        );
    }

    function getForceDeploymentNames() internal override returns (string[] memory forceDeploymentNames) {
        forceDeploymentNames = new string[](1);
        forceDeploymentNames[0] = "L2V29Upgrade";
    }

    function getExpectedL2Address(string memory contractName) public override returns (address) {
        if (compareStrings(contractName, "L2V29Upgrade")) {
            return address(L2_VERSION_SPECIFIC_UPGRADER_ADDR);
        }

        return super.getExpectedL2Address(contractName);
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (!isZKBytecode && compareStrings(contractName, "L1V29Upgrade")) {
            return type(L1V29Upgrade).creationCode;
        }
        return super.getCreationCode(contractName, isZKBytecode);
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view override returns (bytes memory) {
        if (compareStrings(contractName, "L1V29Upgrade")) {
            return abi.encode();
        }
        return super.getCreationCalldata(contractName, isZKBytecode);
    }

    function deployUsedUpgradeContract() internal override returns (address) {
        return deploySimpleContract("L1V29Upgrade", false);
    }

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "MessageRoot")) {
            return abi.encodeCall(MessageRoot.initializeL1V30Upgrade, ());
        }
        return super.getInitializeCalldata(contractName);
    }
}
