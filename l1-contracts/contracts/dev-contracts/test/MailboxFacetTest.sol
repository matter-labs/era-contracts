// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../zksync/facets/Mailbox.sol";
import "../../zksync/Config.sol";

contract MailboxFacetTest is MailboxFacet {
    constructor() {
        s.governor = msg.sender;
    }

    function setFeeParams(FeeParams memory _feeParams) external {
        s.feeParams = _feeParams;
    }

    function getL2GasPrice(uint256 _l1GasPrice) external view returns (uint256) {
        return _deriveL2GasPrice(_l1GasPrice, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
    }
}
