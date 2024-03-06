// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../common/Config.sol";
import "../chain-deps/facets/Mailbox.sol";
import "../libraries/Diamond.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "../../common/L2ContractAddresses.sol";

interface IOldContractDeployer {
    struct ForceDeployment {
        bytes32 bytecodeHash;
        address newAddress;
        uint256 value;
        bytes input;
    }

    function forceDeployOnAddresses(ForceDeployment[] calldata _deployParams) external;
}

/// @author Matter Labs
contract DiamondUpgradeInit4 is MailboxFacet {
    function forceDeploy2(
        bytes calldata _upgradeDeployerCalldata,
        bytes calldata _upgradeSystemContractsCalldata,
        bytes[] calldata _factoryDeps
    ) external payable returns (bytes32) {
        WritePriorityOpParams memory params;

        params.sender = L2_FORCE_DEPLOYER_ADDR;
        params.l2Value = 0;
        params.contractAddressL2 = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR;
        params.l2GasLimit = $(PRIORITY_TX_MAX_GAS_LIMIT);
        params.l2GasPricePerPubdata = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        params.refundRecipient = address(0);

        // 1. Update bytecode for the deployer smart contract
        _requestL2Transaction(0, params, _upgradeDeployerCalldata, _factoryDeps, true);

        // 2. Redeploy other contracts by one transaction
        _requestL2Transaction(0, params, _upgradeSystemContractsCalldata, _factoryDeps, true);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
