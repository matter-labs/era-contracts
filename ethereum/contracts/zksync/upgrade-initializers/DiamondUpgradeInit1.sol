// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../facets/Mailbox.sol";
import "../libraries/Diamond.sol";
import "../../common/L2ContractHelper.sol";
import "../Config.sol";

/// @author Matter Labs
contract DiamondUpgradeInit1 is MailboxFacet {
    /// @dev Request priority operation on behalf of force deployer address to the deployer system contract
    /// @return The message indicating the successful force deployment of contract on L2
    function forceDeployL2Contract(
        bytes calldata _forceDeployCalldata,
        bytes[] calldata _factoryDeps,
        uint256 _l2GasLimit
    ) external payable returns (bytes32) {
        _requestL2Transaction(
            FORCE_DEPLOYER,
            DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
            0,
            _forceDeployCalldata,
            _l2GasLimit,
            DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps,
            true,
            address(0)
        );

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
