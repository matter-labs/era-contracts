// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BaseTokenHolderBase} from "../BaseTokenHolderBase.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";

/**
 * @title BaseTokenHolderEra
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Era-specific implementation of BaseTokenHolder that uses L2BaseToken.transferFromTo.
 * @dev On Era, the base token balance is tracked by the L2BaseToken system contract,
 *      so we must use its transferFromTo method to properly update balances.
 */
// slither-disable-next-line locked-ether
contract BaseTokenHolderEra is BaseTokenHolderBase {
    /// @inheritdoc BaseTokenHolderBase
    function _transferTo(address _to, uint256 _amount) internal override {
        // Transfer base tokens from this holder to the recipient
        // This uses the L2BaseToken's transferFromTo which handles balance updates
        L2_BASE_TOKEN_SYSTEM_CONTRACT.transferFromTo(address(this), _to, _amount);
    }
}
