// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L1L2MessageParams, L1L2IndirectMessageParams} from "../../../../deploy-scripts/utils/L1InteropRequests.sol";
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

    function _addL2ChainContract(uint256 _chainId, address _chainContract) internal {
        chainContracts[_chainId] = _chainContract;
    }

    function _createL1L2MessageParams(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _l2Value,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes memory _l2CallData
    ) internal returns (L1L2MessageParams memory request) {
        request.chainId = _chainId;
        request.mintValue = _mintValue;
        request.l2Value = _l2Value;
        request.l2GasLimit = _l2GasLimit;
        request.l2GasPerPubdataByteLimit = _l2GasPerPubdataByteLimit;
        request.l2Contract = chainContracts[_chainId];
        request.l2Calldata = _l2CallData;

        //mocked
        request.factoryDeps = mockFactoryDeps;
        request.refundRecipient = mockRefundRecipient;
    }

    function _createL1L2IndirectMessageParams(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _indirectCallValue,
        address _crossChainSender,
        uint256 _l2Value,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes memory _indirectCallData
    ) internal returns (L1L2IndirectMessageParams memory request) {
        request.chainId = _chainId;
        request.mintValue = _mintValue;
        request.crossChainSender = _crossChainSender;
        request.indirectCallValue = _indirectCallValue;
        request.l2Value = _l2Value;
        request.l2GasLimit = _l2GasLimit;
        request.l2GasPerPubdataByteLimit = _l2GasPerPubdataByteLimit;
        request.indirectCallData = _indirectCallData;

        //mocks
        request.refundRecipient = mockRefundRecipient;
    }

    // add this to be excluded from coverage report
    function testL2TxMocker() internal {}
}
