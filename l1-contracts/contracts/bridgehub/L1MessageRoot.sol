// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBridgehub} from "./IBridgehub.sol";

import {MessageRootBase} from "./MessageRootBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract L1MessageRoot is MessageRootBase {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable BRIDGE_HUB;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice The chain id of the Gateway chain.
    uint256 public immutable override GATEWAY_CHAIN_ID;

    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// Used for V30 upgrade deployment and local deployments.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @param _bridgehub Address of the Bridgehub.
    /// @param _l1ChainId Chain ID of L1.
    /// @param _gatewayChainId Chain ID of the Gateway chain.
    constructor(IBridgehub _bridgehub, uint256 _l1ChainId, uint256 _gatewayChainId) {
        BRIDGE_HUB = _bridgehub;
        L1_CHAIN_ID = _l1ChainId;
        GATEWAY_CHAIN_ID = _gatewayChainId;
        uint256[] memory allZKChains = BRIDGE_HUB.getAllZKChainChainIDs();
        _v30InitializeInner(allZKChains);
        _initialize();
        _disableInitializers();
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
    function initialize() external initializer {
        _initialize();
    }

        /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
        function initialize() external reinitializer(2) {
            _initialize();
            uint256[] memory allZKChains = BRIDGE_HUB.getAllZKChainChainIDs();
            uint256 allZKChainsLength = allZKChains.length;
            /// locally there are no chains deployed before.
            require(allZKChainsLength == 0, LocallyNoChainsAtGenesis());
        }
    
        /// @dev The initialized used for the V30 upgrade.
    /// On L2s the initializers are disabled.
    function initializeL1V30Upgrade() external reinitializer(2) onlyL1 {
        uint256[] memory allZKChains = BRIDGE_HUB.getAllZKChainChainIDs();
        _v30InitializeInner(allZKChains);
    }
    function saveV30UpgradeChainBatchNumberOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        require(_finalizeWithdrawalParams.l2Sender == L2_MESSAGE_ROOT_ADDR, OnlyL2MessageRoot());
        bool success = proveL1DepositParamsInclusion(_finalizeWithdrawalParams);
        if (!success) {
            revert InvalidProof();
        }

        require(_finalizeWithdrawalParams.chainId == GATEWAY_CHAIN_ID, OnlyGateway());
        require(
            BRIDGE_HUB.whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
            NotWhitelistedSettlementLayer(_finalizeWithdrawalParams.chainId)
        );
        require(block.chainid == L1_CHAIN_ID, OnlyL1());

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_finalizeWithdrawalParams.message, 0);
        require(
            bytes4(functionSignature) == this.sendV30UpgradeBlockNumberFromGateway.selector,
            IncorrectFunctionSignature()
        );

        (uint256 chainId, ) = UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, offset);
        (uint256 receivedV30UpgradeChainBatchNumber, ) = UnsafeBytes.readUint256(
            _finalizeWithdrawalParams.message,
            offset
        );
        require(v30UpgradeChainBatchNumber[chainId] == 0, V30UpgradeChainBatchNumberAlreadySet());
        v30UpgradeChainBatchNumber[chainId] = receivedV30UpgradeChainBatchNumber;
    }

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _bridgehub() internal view override returns (IBridgehub) {
        return BRIDGE_HUB;
    }

    function _l1ChainId() internal view override returns (uint256) {
        return block.chainid;
    }
}
