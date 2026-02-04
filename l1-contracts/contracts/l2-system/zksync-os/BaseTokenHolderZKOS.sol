// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BaseTokenHolderBase} from "../BaseTokenHolderBase.sol";
import {BaseTokenTransferFailed} from "../../common/L1ContractErrors.sol";

/**
 * @title BaseTokenHolderZKOS
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice ZK OS-specific implementation of BaseTokenHolder that uses native ETH transfers.
 * @dev On ZK OS, the base token is native ETH, so we use standard Solidity transfers.
 */
contract BaseTokenHolderZKOS is BaseTokenHolderBase {
    /// @inheritdoc BaseTokenHolderBase
    function _transferTo(address _to, uint256 _amount) internal override {
        // Transfer base tokens using native ETH transfer
        // slither-disable-next-line arbitrary-send-eth
        (bool success, ) = _to.call{value: _amount}("");
        if (!success) {
            revert BaseTokenTransferFailed();
        }
    }
}
