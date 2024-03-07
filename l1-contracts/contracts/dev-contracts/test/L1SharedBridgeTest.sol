// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../bridge/L1SharedBridge.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import "../../bridge/interfaces/IL1SharedBridge.sol";

/// @author Matter Labs
contract L1SharedBridgeTest is L1SharedBridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    address private immutable eraDiamondProxy;

    constructor(
        address _diamondProxyAddress,
        address payable _l1WethAddress,
        IBridgehub _bridgehub,
        IL1ERC20Bridge _legacyBridge
    ) L1SharedBridge(_l1WethAddress, _bridgehub, _legacyBridge) {
        eraDiamondProxy = _diamondProxyAddress;
    }

    /// @notice Checks that the message sender is the bridgehub or Era
    modifier onlyBridgehubOrTestEra(uint256 _chainId) {
        require(
            (msg.sender == address(bridgehub)) || (_chainId == ERA_CHAIN_ID && msg.sender == eraDiamondProxy),
            "L1SharedBridge: not bridgehub or era chain"
        );
        _;
    }

    /// @notice used by bridgehub to aquire mintValue. If l2Tx fails refunds are sent to refundrecipient on L2
    /// we also use it to keep to track each chain's assets
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        address _prevMsgSender,
        address _l1Token,
        uint256 _amount
    ) external payable override onlyBridgehubOrTestEra(_chainId) {
        if (_l1Token == ETH_TOKEN_ADDRESS) {
            require(msg.value == _amount, "L1SharedBridge: msg.value not equal to amount");
        } else {
            // The Bridgehub also checks this, but we want to be sure
            require(msg.value == 0, "ShB m.v > 0 b d.it");

            uint256 amount = _depositFunds(_prevMsgSender, IERC20(_l1Token), _amount); // note if _prevMsgSender is this contract, this will return 0. This does not happen.
            require(amount == _amount, "3T"); // The token has non-standard transfer logic
        }

        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId][_l1Token] += _amount;
        }
        // Note we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
    }
}
