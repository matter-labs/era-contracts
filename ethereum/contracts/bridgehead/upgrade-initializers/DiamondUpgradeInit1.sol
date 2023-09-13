// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../chain-deps/Mailbox.sol";
import "../../common/libraries/Diamond.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "../../common/L2ContractAddresses.sol";
import "../Config.sol";

/// @author Matter Labs
contract DiamondUpgradeInit1 is Mailbox {
    /// @dev Request priority operation on behalf of force deployer address to the deployer system contract
    /// @return The message indicating the successful force deployment of contract on L2
    function forceDeployL2Contract(
        bytes calldata _forceDeployCalldata,
        bytes[] calldata _factoryDeps,
        uint256 _l2GasLimit
    ) external payable returns (bytes32) {
        WritePriorityOpParams memory params;

        params.sender = L2_FORCE_DEPLOYER_ADDR;
        params.l2Value = 0;
        params.contractAddressL2 = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR;
        params.l2GasLimit = _l2GasLimit;
        params.l2GasPricePerPubdata = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        params.refundRecipient = address(0);

        _requestL2Transaction(params, _forceDeployCalldata, _factoryDeps, true);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
