// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {L1SharedBridge} from "../../bridge/L1SharedBridge.sol";
import {IL1ERC20Bridge, IBridgehub} from "../../bridge/interfaces/IL1SharedBridge.sol";
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";

/// @author Matter Labs
contract L1SharedBridgeTest is L1SharedBridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    constructor(
        address _diamondProxyAddress,
        address payable _l1WethAddress,
        IBridgehub _bridgehub,
        IL1ERC20Bridge _legacyBridge,
        uint256 _eraChainId,
        address _eraErc20BridgeAddress
    )
        L1SharedBridge(
            _l1WethAddress,
            _bridgehub,
            _legacyBridge,
            _eraChainId,
            _eraErc20BridgeAddress,
            _diamondProxyAddress
        )
    {}

    /// @notice Checks that the message sender is the bridgehub or Era
    modifier onlyBridgehubOrTestEra(uint256 _chainId) {
        require(
            (msg.sender == address(bridgehub)) || (_chainId == eraChainId && msg.sender == eraDiamondProxy),
            "L1SharedBridge: not bridgehub or era chain"
        );
        _;
    }

    /// @notice used by bridgehub to acquire mintValue. If l2Tx fails refunds are sent to refund recipient on L2
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
