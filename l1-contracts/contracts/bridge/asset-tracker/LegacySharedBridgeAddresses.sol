// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {InvalidL1AssetRouter} from "./AssetTrackerErrors.sol";

struct SharedBridgeOnChainId {
    uint256 chainId;
    address legacySharedBridgeAddress;
}

library LegacySharedBridgeAddresses {
    uint256 internal constant STAGE_LEGACY_BRIDGES = 0;
    uint256 internal constant TESTNET_LEGACY_BRIDGES = 0;
    uint256 internal constant MAINNET_LEGACY_BRIDGES = 0;

    address internal constant STAGE_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = 0x0000000000000000000000000000000000000000;
    address internal constant TESTNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = 0x0000000000000000000000000000000000000000;
    address internal constant MAINNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS = 0x0000000000000000000000000000000000000000;

    /// @dev We have Stage, Testnet and Mainnet ecosystems.
    /// We use the l1AssetRouter to distinguish between them, since stage and testnet are both on Sepolia.
    function getLegacySharedBridgeAddressOnGateway(
        address _l1AssetRouter
    ) internal pure returns (SharedBridgeOnChainId[] memory) {
        SharedBridgeOnChainId[] memory stageLegacySharedBridgeAddresses = new SharedBridgeOnChainId[](
            STAGE_LEGACY_BRIDGES
        );
        SharedBridgeOnChainId[] memory testnetLegacySharedBridgeAddresses = new SharedBridgeOnChainId[](
            TESTNET_LEGACY_BRIDGES
        );
        SharedBridgeOnChainId[] memory mainnetLegacySharedBridgeAddresses = new SharedBridgeOnChainId[](
            MAINNET_LEGACY_BRIDGES
        );

        if (_l1AssetRouter == STAGE_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS) {
            return stageLegacySharedBridgeAddresses;
        } else if (_l1AssetRouter == TESTNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS) {
            return testnetLegacySharedBridgeAddresses;
        } else if (_l1AssetRouter == MAINNET_ECOSYSTEM_L1_ASSET_ROUTER_ADDRESS) {
            return mainnetLegacySharedBridgeAddresses;
        }
        revert InvalidL1AssetRouter(_l1AssetRouter);
    }
}
