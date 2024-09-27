// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1SharedBridgeLegacy} from "../bridge/interfaces/IL1SharedBridgeLegacy.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";

import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {ZKChainStorage} from "../state-transition/chain-deps/ZKChainStorage.sol";

library GatewayHelper {
    function getZKChainSpecificForceDeploymentsData(ZKChainStorage storage s) internal view returns (bytes memory) {
        address sharedBridge = IBridgehub(s.bridgehub).sharedBridge();
        address legacySharedBridge = IL1SharedBridgeLegacy(sharedBridge).l2BridgeAddress(s.chainId);
        ZKChainSpecificForceDeploymentsData
            memory additionalForceDeploymentsData = ZKChainSpecificForceDeploymentsData({
                baseTokenAssetId: s.baseTokenAssetId,
                l2LegacySharedBridge: legacySharedBridge,
                l2Weth: address(0) // kl todo
            });
        return abi.encode(additionalForceDeploymentsData);
    }
}
