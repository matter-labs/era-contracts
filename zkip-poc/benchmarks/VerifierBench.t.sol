// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TRANSACTION_BASE_GAS, ZERO_BYTE_GAS, NONZERO_BYTE_GAS} from "./BenchmarkGasConfig.sol";

interface IBenchmarkVerifier {
    function verify(bytes calldata _proof, bytes32[] calldata _publicInputs) external view returns (bool);
}

contract VerifierBench is Test {
    function test_realProofsAndPublicInputBinding() external {
        string memory manifest = vm.readFile("manifest.json");
        string[] memory names = vm.parseJsonStringArray(manifest, ".names");
        for (uint256 i = 0; i < names.length; ++i) {
            this.measureOne(names[i]);
        }
    }

    function measureOne(string calldata _name) external {
        // A fresh call frame prevents earlier cases' memory growth from biasing later cases.
        string memory fixture = vm.readFile(string.concat("fixtures/", _name, ".json"));
        bytes memory proof = vm.parseJsonBytes(fixture, ".proof");
        bytes32[] memory inputs = vm.parseJsonBytes32Array(fixture, ".public_inputs");
        address deployed = deployCode(string.concat(_name, ".sol:HonkVerifier"));
        IBenchmarkVerifier verifier = IBenchmarkVerifier(deployed);
        // A cold call reflects a separate submission; looping must not amortize verifier access.
        vm.cool(deployed);
        uint256 beforeGas = gasleft();
        bool valid = verifier.verify(proof, inputs);
        uint256 executionGas = beforeGas - gasleft();
        assertTrue(valid, _name);
        bytes memory data = abi.encodeCall(IBenchmarkVerifier.verify, (proof, inputs));
        uint256 calldataGas;
        for (uint256 j = 0; j < data.length; ++j) {
            calldataGas += data[j] == 0 ? ZERO_BYTE_GAS : NONZERO_BYTE_GAS;
        }
        console2.log(string.concat("BENCH ", _name));
        console2.log("execution_gas", executionGas);
        console2.log("calldata_gas", calldataGas);
        console2.log("transaction_gas", executionGas + calldataGas + TRANSACTION_BASE_GAS);
        console2.log("verifier_runtime_bytes", deployed.code.length);
        inputs[0] = bytes32(uint256(inputs[0]) + 1);
        vm.expectRevert();
        verifier.verify(proof, inputs);
    }
}
