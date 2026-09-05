// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1InteropRequests} from "../../../../deploy-scripts/utils/L1InteropRequests.sol";
import {L1L2MessageParams} from "../../../../deploy-scripts/utils/L1InteropRequests.sol";

import {ConstructorForwarder} from "contracts/dev-contracts/ConstructorForwarder.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";

import {BridgehubInvariantTests} from "test/foundry/l1/integration/BridgehubTests.t.sol";

contract Bridgehub_ConstructorCaller is BridgehubInvariantTests {
    function setUp() public {
        prepare();
    }

    function prepare() public override {
        _generateUserAddresses();

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);
            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    // Regression test for the default refund recipient resolution: a contract calling the Bridgehub
    // from its own constructor has no deployed code yet, so the `code.length`-based aliasing in the
    // Mailbox cannot recognize it as a contract. With `refundRecipient` unset, the refund recipient
    // must resolve to the same aliased L2 address as the sender.
    function test_DepositEthConstructorCallerUnsetRefundRecipient() external {
        currentChainId = 10;
        currentChainAddress = getZKChainAddress(currentChainId);
        uint256 l2Value = 100;
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 1000000;
        uint256 minRequiredGas = _getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        uint256 mintValue = l2Value + minRequiredGas;

        bytes memory callData = abi.encode(ETH_TOKEN_ADDRESS, l2Value, chainContracts[currentChainId]);
        L1L2MessageParams memory txRequest = _createL1L2MessageParams({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _l2Value: l2Value,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: callData
        });
        // The refund recipient is deliberately left unset to exercise the default resolution.
        txRequest.refundRecipient = address(0);

        bytes memory bridgehubCalldata = L1InteropRequests.encodeDirectCalldata(txRequest);

        vm.deal(address(this), mintValue);
        vm.recordLogs();
        // The forwarder performs the center call inside its own constructor.
        ConstructorForwarder forwarder = new ConstructorForwarder{value: mintValue}(
            address(addresses.interopCenter),
            bridgehubCalldata
        );

        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(vm.getRecordedLogs());
        assertNotEq(request.txHash, bytes32(0), "Transaction hash should not be zero");

        address aliasedForwarder = AddressAliasHelper.applyL1ToL2Alias(address(forwarder));
        assertEq(
            address(uint160(request.transaction.from)),
            aliasedForwarder,
            "Sender should be the aliased constructor caller"
        );
        assertEq(
            address(uint160(request.transaction.reserved[1])),
            aliasedForwarder,
            "Default refund recipient should resolve to the same aliased L2 identity as the sender"
        );
    }

    function testBoundedBridgehubInvariant() internal {}
}
