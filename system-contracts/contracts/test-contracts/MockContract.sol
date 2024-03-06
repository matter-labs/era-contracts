// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract MockContract {
    event Called(uint256 value, bytes data);

    struct CallResult {
        bytes input;
        bool failure;
        bytes returnData;
    }

    CallResult[] private results;

    constructor() {
        // Clean results if mock was redeployed.
        delete results;
    }

    // This function call will not pass to fallback, but this is fine for the tests.
    function setResult(CallResult calldata result) external {
        bytes32 inputKeccak = keccak256(result.input);
        for (uint256 i = 0; i < results.length; i++) {
            if (keccak256(results[i].input) == inputKeccak) {
                results[i] = result;
                return;
            }
        }
        results.push(result);
    }

    fallback() external payable {
        bytes memory data = msg.data;
        bytes32 inputKeccak = keccak256(data);

        // empty return data with successful result by default.
        bool failure;
        bytes memory returnData;

        for (uint256 i = 0; i < results.length; i++) {
            if (keccak256(results[i].input) == inputKeccak) {
                failure = results[i].failure;
                returnData = results[i].returnData;
                break;
            }
        }

        // Emitting event only if empty successful result expected.
        // Can fail if call context is static, but usually it's not a case,
        // because view/pure call without return data doesn't make sense.
        // Useful, because for such calls we can check for this event,
        // to be sure that the needed call was made.
        if (!failure && returnData.length == 0) {
            emit Called(msg.value, data);
        }

        assembly {
            switch failure
            case 0 {
                return(add(returnData, 0x20), mload(returnData))
            }
            default {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
