// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {GasBoundCaller} from "../GasBoundCaller.sol";
import {SystemContractHelper} from "../libraries/SystemContractHelper.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that allows to limit the final gas expenditure of the call.
 */
contract GasBoundCallerTester is GasBoundCaller {
    uint256 public lastRecordedGasLeft;

    function testEntryOverheadInner(uint256 _expectedGas) external payable {
        // `2/3` to ensure that the constant is good with sufficient overhead
        require(gasleft() + (2 * CALL_ENTRY_OVERHEAD) / 3 >= _expectedGas, "Entry overhead is incorrect");

        lastRecordedGasLeft = gasleft();
    }

    function testEntryOverhead(uint256 _expectedGas) external payable {
        this.testEntryOverheadInner{gas: _expectedGas}(_expectedGas);
    }

    function testReturndataOverheadInner(bool _shouldReturn, uint256 _len) external {
        if (_shouldReturn) {
            assembly {
                return(0, _len)
            }
        } else {
            (bool success, bytes memory returnData) = address(this).call(
                abi.encodeWithSignature("testReturndataOverheadInner(bool,uint256)", true, _len)
            );
            require(success, "Call failed");

            // `2/3` to ensure that the constant is good with sufficient overhead
            SystemContractHelper.burnGas(uint32(gasleft() - (2 * CALL_RETURN_OVERHEAD) / 3), 0);
            assembly {
                // We just relay the return data from the call.
                return(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function testReturndataOverhead(uint256 len) external {
        uint256 gasbefore = gasleft();
        this.testReturndataOverheadInner(false, len);
        lastRecordedGasLeft = gasbefore - gasleft();
    }

    function spender(uint32 _ergsToBurn, uint32 _pubdataToUse) external {
        SystemContractHelper.burnGas(_ergsToBurn, _pubdataToUse);
    }

    function gasBoundCallRelayer(
        uint256 _gasToPass,
        address _to,
        uint256 _maxTotalGas,
        bytes calldata _data
    ) external payable {
        this.gasBoundCall{gas: _gasToPass}(_to, _maxTotalGas, _data);
    }
}
