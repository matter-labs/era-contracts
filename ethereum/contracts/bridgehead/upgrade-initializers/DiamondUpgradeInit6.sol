// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../Config.sol";
import "../chain-deps/Mailbox.sol";
import "../../common/libraries/Diamond.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "../../common/L2ContractAddresses.sol";

/// @author Matter Labs
contract DiamondUpgradeInit6 is Mailbox {
    function forceDeploy(
        bytes calldata _upgradeL2WethTokenCalldata,
        bytes calldata _upgradeSystemContractsCalldata,
        bytes[] calldata _factoryDeps
    ) external payable returns (bytes32) {
        // 1. Update bytecode for the L2 WETH smart contract

        WritePriorityOpParams memory params;

        params.sender = L2_FORCE_DEPLOYER_ADDR;
        params.l2Value = 0;
        params.contractAddressL2 = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR;
        params.l2GasLimit = $(PRIORITY_TX_MAX_GAS_LIMIT);
        params.l2GasPricePerPubdata = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        params.refundRecipient = address(0);

        _requestL2Transaction(params, _upgradeL2WethTokenCalldata, _factoryDeps, true);

        // 2. Redeploy system contracts by one priority transaction
        _requestL2Transaction(params, _upgradeSystemContractsCalldata, _factoryDeps, true);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
