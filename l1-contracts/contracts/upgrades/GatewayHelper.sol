// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1SharedBridgeLegacy} from "../bridge/interfaces/IL1SharedBridgeLegacy.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";

import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {ZKChainStorage} from "../state-transition/chain-deps/ZKChainStorage.sol";

import {L2WrappedBaseTokenStore} from "../bridge/L2WrappedBaseTokenStore.sol";
import {BridgeHelper} from "../bridge/BridgeHelper.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

library GatewayHelper {
    function getZKChainSpecificForceDeploymentsData(
        ZKChainStorage storage s,
        // The address of the store of the base token.
        // If it non-zero only for upgrades, but for genesis it should be zero.
        address _wBaseTokenStore,
        address _baseTokenAddress
    ) internal view returns (bytes memory) {
        address sharedBridge = IBridgehub(s.bridgehub).sharedBridge();
        address legacySharedBridge = IL1SharedBridgeLegacy(sharedBridge).l2BridgeAddress(s.chainId);

        address l2WBaseToken;
        if (_wBaseTokenStore != address(0)) {
            l2WBaseToken = L2WrappedBaseTokenStore(_wBaseTokenStore).l2WBaseTokenAddress(s.chainId);
        }

        // It is required for a base to implement the following methods
        string memory baseTokenName = IERC20Metadata(_baseTokenAddress).name();
        string memory baseTokenSymbol = IERC20Metadata(_baseTokenAddress).symbol();

        ZKChainSpecificForceDeploymentsData
            memory additionalForceDeploymentsData = ZKChainSpecificForceDeploymentsData({
                baseTokenAssetId: s.baseTokenAssetId,
                l2LegacySharedBridge: legacySharedBridge,
                predeployedL2WethAddress: l2WBaseToken,
                baseTokenL1Address: _baseTokenAddress,
                baseTokenName: baseTokenName,
                baseTokenSymbol: baseTokenSymbol
            });
        return abi.encode(additionalForceDeploymentsData);
    }
}
