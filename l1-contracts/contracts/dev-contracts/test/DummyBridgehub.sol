// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {BridgehubL2TransactionRequest} from "../../common/Messaging.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {IMessageRootBase} from "../../core/message-root/IMessageRoot.sol";
import {L2TransactionRequestDirect} from "../../core/bridgehub/IBridgehubBase.sol";

import {IAssetRouterShared} from "../../bridge/asset-router/IAssetRouterShared.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";

/// @title DummyBridgehub
/// @notice A test smart contract that allows to set State Transition Manager for a given chain
contract DummyBridgehub {
    IMessageRootBase public messageRoot;

    address public zkChain;

    address public sharedBridge;

    address public chainAssetHandler;

    // add this to be excluded from coverage report
    function test() internal virtual {}

    function baseTokenAssetId(uint256) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    L2_NATIVE_TOKEN_VAULT_ADDR,
                    ETH_TOKEN_ADDRESS
                    // bytes32(uint256(uint160(IGetters(msg.sender).getBaseToken())))
                )
            );
    }

    function setMessageRoot(address _messageRoot) public {
        messageRoot = IMessageRootBase(_messageRoot);
    }

    function setZKChain(uint256, address _zkChain) external {
        zkChain = _zkChain;
    }

    function getZKChain(uint256) external view returns (address) {
        return zkChain;
    }

    function getAllZKChainChainIDs() external view returns (uint256[] memory) {
        uint256[] memory allZKChainChainIDs = new uint256[](0);
        // allZKChainChainIDs[0] = 271;
        return allZKChainChainIDs;
    }

    function setSharedBridge(address addr) external {
        sharedBridge = addr;
    }

    function setChainAssetHandler(address _handler) external {
        chainAssetHandler = _handler;
    }

    function assetRouter() external view returns (address) {
        return sharedBridge;
    }

    function settlementLayer(uint256) external view returns (uint256) {
        return 0;
    }

    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash) {
        IAssetRouterShared(sharedBridge).bridgehubDepositBaseToken{value: msg.value}(
            _request.chainId,
            baseTokenAssetId(_request.chainId),
            msg.sender,
            _request.mintValue
        );

        canonicalTxHash = IZKChain(zkChain).bridgehubRequestL2Transaction(
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _request.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: _request.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: _request.factoryDeps,
                refundRecipient: _request.refundRecipient
            })
        );
    }
}
