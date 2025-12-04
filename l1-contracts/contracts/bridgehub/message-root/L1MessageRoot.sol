// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MessageRootBase} from "./MessageRootBase.sol";
import {FinalizeL1DepositParams} from "../../bridge/interfaces/IL1Nullifier.sol";
import {UnsafeBytes} from "../../common/libraries/UnsafeBytes.sol";
import {IncorrectFunctionSignature, LocallyNoChainsAtGenesis, NotWhitelistedSettlementLayer, OnlyGateway, OnlyL2MessageRoot, V30UpgradeChainBatchNumberAlreadySet} from "../core/L1BridgehubErrors.sol";
import {L2_MESSAGE_ROOT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {InvalidProof} from "../../common/L1ContractErrors.sol";
import {L2MessageRoot} from "./L2MessageRoot.sol";
import {IBridgehubBase} from "../core/IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract L1MessageRoot is MessageRootBase {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    address public immutable BRIDGE_HUB;

    /// @notice The chain id of the Gateway chain.
    uint256 public immutable override ERA_GATEWAY_CHAIN_ID;

    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// Used for V30 upgrade deployment and local deployments.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @param _bridgehub Address of the Bridgehub.
    /// @param _eraGatewayChainId Chain ID of the Gateway chain.
    constructor(address _bridgehub, uint256 _eraGatewayChainId) {
        BRIDGE_HUB = _bridgehub;
        ERA_GATEWAY_CHAIN_ID = _eraGatewayChainId;
        uint256[] memory allZKChains = IBridgehubBase(_bridgehub).getAllZKChainChainIDs();
        _v30InitializeInner(allZKChains);
        _initialize();
        _disableInitializers();
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
    function initialize() external reinitializer(2) {
        _initialize();
        uint256[] memory allZKChains = IBridgehubBase(BRIDGE_HUB).getAllZKChainChainIDs();
        uint256 allZKChainsLength = allZKChains.length;
        /// locally there are no chains deployed before.
        require(allZKChainsLength == 0, LocallyNoChainsAtGenesis());
    }

    /// @dev The initialized used for the V30 upgrade.
    /// On L2s the initializers are disabled.
    function initializeL1V30Upgrade() external reinitializer(2) onlyL1 {
        uint256[] memory allZKChains = IBridgehubBase(BRIDGE_HUB).getAllZKChainChainIDs();
        _v30InitializeInner(allZKChains);
    }
    function saveV30UpgradeChainBatchNumberOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        require(_finalizeWithdrawalParams.l2Sender == L2_MESSAGE_ROOT_ADDR, OnlyL2MessageRoot());
        bool success = proveL1DepositParamsInclusion(_finalizeWithdrawalParams);
        if (!success) {
            revert InvalidProof();
        }

        require(_finalizeWithdrawalParams.chainId == ERA_GATEWAY_CHAIN_ID, OnlyGateway());
        require(
            IBridgehubBase(BRIDGE_HUB).whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
            NotWhitelistedSettlementLayer(_finalizeWithdrawalParams.chainId)
        );

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_finalizeWithdrawalParams.message, 0);
        require(
            bytes4(functionSignature) == L2MessageRoot.sendV30UpgradeBlockNumberFromGateway.selector,
            IncorrectFunctionSignature()
        );

        // slither-disable-next-line unused-return
        (uint256 chainId, ) = UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, offset);
        // slither-disable-next-line unused-return
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

    function _bridgehub() internal view override returns (address) {
        return BRIDGE_HUB;
    }

    function L1_CHAIN_ID() public view override returns (uint256) {
        return block.chainid;
    }

    function _eraGatewayChainId() internal view override returns (uint256) {
        return ERA_GATEWAY_CHAIN_ID;
    }
}
