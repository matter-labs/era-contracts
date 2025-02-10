// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";

import {Constants} from "./Constants.sol";
import {UserActorHandler} from "./UserActorHandler.sol";

// no cheatcodes here because they won't work with `--zksync`
// forge 0.0.2 (27360d4 2024-12-02T00:28:35.872943000Z)
contract L1AssetRouterActorHandler is Test, Constants {
    UserActorHandler[] public receivers;
    // ghost variables
    // https://book.getfoundry.sh/forge/invariant-testing#handler-ghost-variables
    uint256 public totalDeposits;

    constructor(UserActorHandler[] memory _receivers) {
        receivers = _receivers;
    }

    function finalizeDeposit(uint256 _amount, address _sender, uint256 _receiverIndex) public {
        _amount = bound(_amount, 0, 1e30);
        // hopefully the `bound` function excludes the upper value
        uint256 receiverIndex = bound(_receiverIndex, 0, receivers.length);

        L2AssetRouter(L2_ASSET_ROUTER_ADDR).finalizeDeposit({
            _l1Sender: _sender,
            _l2Receiver: address(receivers[receiverIndex]),
            _l1Token: L1_TOKEN_ADDRESS,
            _amount: _amount,
            _data: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });

        totalDeposits += _amount;
    }

    // function finalizeDepositV2(uint256 _amount) public {
    // }

    // borrowed from https://github.com/matter-labs/era-contracts/blob/16dedf6d77695ce00f81fce35a3066381b97fca1/l1-contracts/test/foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol#L203-L217
    /// @notice Encodes the token data.
    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    /// @param decimals The decimals of the token.
    function encodeTokenData(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal pure returns (bytes memory) {
        bytes memory encodedName = abi.encode(name);
        bytes memory encodedSymbol = abi.encode(symbol);
        bytes memory encodedDecimals = abi.encode(decimals);

        return abi.encode(encodedName, encodedSymbol, encodedDecimals);
    }
}