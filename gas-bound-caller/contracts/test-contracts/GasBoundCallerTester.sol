// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {GasBoundCaller} from "../GasBoundCaller.sol";
import {SystemContractHelper} from "./SystemContractHelper.sol";

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

            // It is not needed to query the exact value for the test.
            uint256 pubdataGas = 100;

            // `2/3` to ensure that the constant is good with sufficient overhead
            SystemContractHelper.burnGas(uint32(gasleft() - (2 * CALL_RETURN_OVERHEAD) / 3), 0);
            assembly {
                // This place does interfere with the memory layout, however, it is done right before
                // the `return` statement, so it is safe to do.
                // We need to transform `bytes memory returnData` into (bytes memory returndata, gasSpentOnPubdata)
                // `bytes memory returnData` is encoded as `length` + `data`.
                // We need to prepend it with 0x40 and `pubdataGas`.
                //
                // It is assumed that the position of returndata is >= 0x40, since 0x40 is the free memory pointer location.
                mstore(sub(returnData, 0x40), 0x40)
                mstore(sub(returnData, 0x20), pubdataGas)
                let returndataLen := add(mload(returnData), 0x60)

                return(sub(returnData, 0x40), returndataLen)
            }
        }
    }

    function testReturndataOverhead(uint256 len) external {
        uint256 gasbefore = gasleft();
        this.testReturndataOverheadInner(false, len);
        lastRecordedGasLeft = gasbefore - gasleft();
    }

    function spender(uint32 _ergsToBurn, uint32 _pubdataToUse, bytes memory expectedReturndata) external {
        SystemContractHelper.burnGas(_ergsToBurn, _pubdataToUse);

        assembly {
            // Return the expected returndata
            return(add(expectedReturndata, 0x20), mload(expectedReturndata))
        }
    }

    function gasBoundCallRelayer(
        uint256 _gasToPass,
        address _to,
        uint256 _maxTotalGas,
        bytes calldata _data,
        bytes memory expectedReturndata,
        uint256 expectedPubdataGas
    ) external payable {
        (bool success, bytes memory returnData) = address(this).call{gas: _gasToPass}(
            abi.encodeWithSelector(GasBoundCaller.gasBoundCall.selector, _to, _maxTotalGas, _data)
        );

        require(success);

        (bytes memory realReturnData, uint256 pubdataGas) = abi.decode(returnData, (bytes, uint256));

        require(keccak256(expectedReturndata) == keccak256(realReturnData), "Return data is incorrect");
        require(pubdataGas == expectedPubdataGas, "Pubdata gas is incorrect");
    }
}
