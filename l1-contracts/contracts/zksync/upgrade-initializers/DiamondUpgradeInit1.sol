// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../facets/Mailbox.sol";
import "../libraries/Diamond.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "../../common/L2ContractAddresses.sol";
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
            L2_FORCE_DEPLOYER_ADDR,
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            0,
            _forceDeployCalldata,
            _l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps,
            true,
            address(0)
        );

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
