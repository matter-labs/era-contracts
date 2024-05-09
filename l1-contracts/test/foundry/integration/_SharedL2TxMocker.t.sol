// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";

contract L2TxMocker is Test {
    address mockRefundRecipient;
    address mockL2Contract;
    address mockL2SharedBridge;

    uint256 mockL2GasLimit = 10000000;
    uint256 mockL2GasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

    bytes mockL2Calldata;
    bytes[] mockFactoryDeps;

    mapping(uint256 chainId => address l2MockContract) public chainContracts;

    constructor() {
        mockRefundRecipient = makeAddr("refundrecipient");
        mockL2Contract = makeAddr("mockl2contract");
        mockL2SharedBridge = makeAddr("mockl2sharedbridge");

        mockL2Calldata = "";
        mockFactoryDeps = new bytes[](1);
        mockFactoryDeps[0] = "11111111111111111111111111111111";
    }

    function addL2ChainContract(uint256 _chainId, address _chainContract) internal {
        chainContracts[_chainId] = _chainContract;
    }

    function createL2TransitionRequestDirectSecond(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _l2Value,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) internal returns (L2TransactionRequestDirect memory request) {
        request.chainId = _chainId;
        request.mintValue = _mintValue;
        request.l2Value = _l2Value;
        request.l2GasLimit = _l2GasLimit;
        request.l2GasPerPubdataByteLimit = _l2GasPerPubdataByteLimit;
        request.l2Contract = chainContracts[_chainId];

        //
        request.l2Calldata = mockL2Calldata;
        request.factoryDeps = mockFactoryDeps;
        request.refundRecipient = mockRefundRecipient;
    }

    function createMockL2TransactionRequestDirect(
        uint256 chainId,
        uint256 mintValue,
        uint256 l2Value
    ) internal returns (L2TransactionRequestDirect memory request) {
        request.chainId = chainId;
        request.mintValue = mintValue;
        request.l2Value = l2Value;

        // mocks
        request.l2Contract = mockL2Contract;
        request.l2Calldata = mockL2Calldata;
        request.l2GasLimit = mockL2GasLimit;
        request.l2GasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        request.factoryDeps = mockFactoryDeps;
        request.refundRecipient = mockRefundRecipient;
    }

    function createMockL2TransactionRequestTwoBridges(
        uint256 chainId,
        uint256 mintValue,
        uint256 secondBridgeValue,
        uint256 l2Value,
        address secondBridgeAddress,
        bytes memory secondBridgeCalldata
    ) internal returns (L2TransactionRequestTwoBridgesOuter memory request) {
        request.chainId = chainId;
        request.mintValue = mintValue;
        request.secondBridgeAddress = secondBridgeAddress;
        request.secondBridgeValue = secondBridgeValue;
        request.l2Value = l2Value;

        // mocks
        request.l2GasLimit = mockL2GasLimit;
        request.l2GasPerPubdataByteLimit = mockL2GasPerPubdataByteLimit;
        request.refundRecipient = mockRefundRecipient;
        request.secondBridgeCalldata = secondBridgeCalldata;
    }
}
