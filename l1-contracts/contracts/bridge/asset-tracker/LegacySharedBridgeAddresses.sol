// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

struct SharedBridgeOnChainId {
    uint256 chainId;
    address legacySharedBridgeAddress;
}

library LegacySharedBridgeAddresses {
    uint256 internal constant STAGE_LEGACY_BRIDGES = 0;
    uint256 internal constant TESTNET_LEGACY_BRIDGES = 0;
    uint256 internal constant MAINNET_LEGACY_BRIDGES = 0;

    uint256 internal constant STAGE_GW_CHAIN_ID = 1;
    uint256 internal constant TESTNET_GW_CHAIN_ID = 2;
    uint256 internal constant MAINNET_GW_CHAIN_ID = 3;

    error InvalidGwChainId(uint256 gwChainId);

    function getLegacySharedBridgeLength(uint256 _gwChainId) internal pure returns (uint256) {
        if (_gwChainId == STAGE_GW_CHAIN_ID) {
            return STAGE_LEGACY_BRIDGES;
        } else if (_gwChainId == TESTNET_GW_CHAIN_ID) {
            return TESTNET_LEGACY_BRIDGES;
        } else if (_gwChainId == MAINNET_GW_CHAIN_ID) {
            return MAINNET_LEGACY_BRIDGES;
        }
    }

    /// @dev We have Stage, Testnet and Mainnet ecosystems.
    /// We use the gwChainId to distinguish between them, since stage and testnet are both on Sepolia.
    function getLegacySharedBridgeAddressOnGateway(
        uint256 _gwChainId
    ) internal pure returns (SharedBridgeOnChainId[] memory) {
        SharedBridgeOnChainId[] memory stageLegacySharedBridgeAddresses = new SharedBridgeOnChainId[](0);
        SharedBridgeOnChainId[] memory testnetLegacySharedBridgeAddresses = new SharedBridgeOnChainId[](0);
        SharedBridgeOnChainId[] memory mainnetLegacySharedBridgeAddresses = new SharedBridgeOnChainId[](0);

        if (_gwChainId == STAGE_GW_CHAIN_ID) {
            return stageLegacySharedBridgeAddresses;
        } else if (_gwChainId == TESTNET_GW_CHAIN_ID) {
            return testnetLegacySharedBridgeAddresses;
        } else if (_gwChainId == MAINNET_GW_CHAIN_ID) {
            return mainnetLegacySharedBridgeAddresses;
        }
        revert InvalidGwChainId(_gwChainId);
    }
}
