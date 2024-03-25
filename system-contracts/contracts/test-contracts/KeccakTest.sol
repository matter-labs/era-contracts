// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma abicoder v2;

import {LOAD_LATEST_RETURNDATA_INTO_ACTIVE_PTR_CALL_ADDRESS, PTR_PACK_INTO_ACTIVE_CALL_ADDRESS, SystemContractsCaller, CalldataForwardingMode, RAW_FAR_CALL_BY_REF_CALL_ADDRESS} from "../libraries/SystemContractsCaller.sol";
import {EfficientCall, KECCAK256_SYSTEM_CONTRACT} from "../libraries/EfficientCall.sol";

// In this test it is important to actually change the real Keccak256's contract's bytecode,
// which requires changes in the real AccountCodeStorage contract
address constant REAL_DEPLOYER_SYSTEM_CONTRACT = address(0x8006);
address constant REAL_FORCE_DEPLOYER_ADDRESS = address(0x8007);

contract KeccakTest {
    bytes32 constant EMPTY_STRING_KECCAK = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    // Just some computation-heavy function, it will be used to test out of gas
    function infiniteFunction(uint256 n) public pure returns (uint256 sumOfSquares) {
        for (uint256 i = 0; i < n; i++) {
            sumOfSquares += i * i;
        }
    }

    function _loadFarCallABIIntoActivePtr(uint256 _gas) private view {
        uint256 farCallAbi = SystemContractsCaller.getFarCallABIWithEmptyFatPointer({
            gasPassed: uint32(_gas),
            // Only rollup is supported for now
            shardId: 0,
            forwardingMode: CalldataForwardingMode.ForwardFatPointer,
            isConstructorCall: false,
            isSystemCall: false
        });
        _ptrPackIntoActivePtr(farCallAbi);
    }

    function _loadReturnDataIntoActivePtr() internal {
        address callAddr = LOAD_LATEST_RETURNDATA_INTO_ACTIVE_PTR_CALL_ADDRESS;
        assembly {
            pop(staticcall(0, callAddr, 0, 0xFFFF, 0, 0))
        }
    }

    function _ptrPackIntoActivePtr(uint256 _farCallAbi) internal view {
        address callAddr = PTR_PACK_INTO_ACTIVE_CALL_ADDRESS;
        assembly {
            pop(staticcall(_farCallAbi, callAddr, 0, 0xFFFF, 0, 0))
        }
    }

    function rawCallByRef(address _address) internal returns (bool success) {
        address callAddr = RAW_FAR_CALL_BY_REF_CALL_ADDRESS;
        assembly {
            success := call(_address, callAddr, 0, 0, 0xFFFF, 0, 0)
        }
    }

    function zeroPointerTest() external {
        try this.infiniteFunction{gas: 1000000}(1000000) returns (uint256) {
            revert("The transaction should have failed");
        } catch {}

        _loadReturnDataIntoActivePtr();
        _loadFarCallABIIntoActivePtr(1000000);
        bool success = rawCallByRef(KECCAK256_SYSTEM_CONTRACT);
        require(success, "The call to keccak should have succeeded");

        uint256 returndataSize = 0;
        assembly {
            returndataSize := returndatasize()
        }
        require(returndataSize == 32, "The return data size should be 32 bytes");

        bytes32 result;
        assembly {
            returndatacopy(0, 0, 32)
            result := mload(0)
        }

        require(result == EMPTY_STRING_KECCAK, "The result is not correct");
    }

    function keccakUpgradeTest(
        bytes calldata eraseCallData,
        bytes calldata upgradeCalldata
    ) external returns (bytes32 hash) {
        // Firstly, we reset keccak256 bytecode to be some random bytecode
        EfficientCall.mimicCall({
            _gas: gasleft(),
            _address: address(REAL_DEPLOYER_SYSTEM_CONTRACT),
            _data: eraseCallData,
            _whoToMimic: REAL_FORCE_DEPLOYER_ADDRESS,
            _isConstructor: false,
            _isSystem: false
        });

        // Since the keccak contract has been erased, it should not work anymore
        try this.callKeccak(msg.data[0:0]) returns (bytes32) {
            revert("The keccak should not work anymore");
        } catch {}

        // Upgrading it back to the correct version:
        EfficientCall.mimicCall({
            _gas: gasleft(),
            _address: address(REAL_DEPLOYER_SYSTEM_CONTRACT),
            _data: upgradeCalldata,
            _whoToMimic: REAL_FORCE_DEPLOYER_ADDRESS,
            _isConstructor: false,
            _isSystem: false
        });

        // Now it should work again
        hash = this.callKeccak(msg.data[0:0]);
        require(hash == EMPTY_STRING_KECCAK, "Keccak should start working again");
    }

    function keccakPerformUpgrade(bytes calldata upgradeCalldata) external {
        EfficientCall.mimicCall({
            _gas: gasleft(),
            _address: address(REAL_DEPLOYER_SYSTEM_CONTRACT),
            _data: upgradeCalldata,
            _whoToMimic: REAL_FORCE_DEPLOYER_ADDRESS,
            _isConstructor: false,
            _isSystem: false
        });
    }

    function callKeccak(bytes calldata _data) external pure returns (bytes32 hash) {
        hash = keccak256(_data);
    }

    function keccakValidationTest(
        bytes calldata upgradeCalldata,
        bytes calldata resetCalldata,
        bytes[] calldata testInputs,
        bytes32[] calldata expectedOutputs
    ) external {
        require(testInputs.length == expectedOutputs.length, "mismatch between number of inputs and outputs");

        // Firstly, we upgrade keccak256 bytecode to the correct version.
        EfficientCall.mimicCall({
            _gas: gasleft(),
            _address: address(REAL_DEPLOYER_SYSTEM_CONTRACT),
            _data: upgradeCalldata,
            _whoToMimic: REAL_FORCE_DEPLOYER_ADDRESS,
            _isConstructor: false,
            _isSystem: false
        });

        bytes32[] memory result = new bytes32[](testInputs.length);

        for (uint256 i = 0; i < testInputs.length; i++) {
            bytes32 res = this.callKeccak(testInputs[i]);
            result[i] = res;
        }

        for (uint256 i = 0; i < result.length; i++) {
            require(result[i] == expectedOutputs[i], "hash was not calculated correctly");
        }

        // Upgrading it back to the original version:
        EfficientCall.mimicCall({
            _gas: gasleft(),
            _address: address(REAL_DEPLOYER_SYSTEM_CONTRACT),
            _data: resetCalldata,
            _whoToMimic: REAL_FORCE_DEPLOYER_ADDRESS,
            _isConstructor: false,
            _isSystem: false
        });
    }
}
