// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../../../lib/forge-std/src/Test.sol";
import "../../../lib/forge-std/src/console.sol";
import "./CelestiaL1DAValidator.sol";
import "../../IL1DAValidator.sol";

contract CelestiaL1DAValidatorTest is Test {
    CelestiaL1DAValidator public validator;

    // Test variables
    uint256 public constant MAX_BLOBS_SUPPORTED = 1;

    // Fork-related variables
    uint256 public mainnetFork;
    string public MAINNET_RPC_URL;
    bool public forksInitialized;

    function setUp() public {
        // Get the RPC URL from environment variable
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            MAINNET_RPC_URL = url;
            console.log("Using MAINNET_RPC_URL:", MAINNET_RPC_URL);

            // Create a fork of mainnet
            mainnetFork = vm.createFork(MAINNET_RPC_URL);
            vm.selectFork(mainnetFork);
            forksInitialized = true;

            console.log("Testing against mainnet fork at block:", block.number);
        } catch {
            console.log("MAINNET_RPC_URL not set. Mock testing only.");
            forksInitialized = false;
        }

        // Deploy the validator contract
        validator = new CelestiaL1DAValidator(
            0x397A5f7f3dBd538f23DE225B51f532c34448dA9B, // SP1Groth16Verifier
            0xF0c6429ebAB2e7DC6e05DaFB61128bE21f13cb1e, // Blobstream
            0x005a902e725cde951470b808cc74ba08d2470219e281b82aec0a1c239da7db7e // EQS Vkey
        );
    }

    function testMultipleCases() public {
        // Skip test if fork is not available
        if (!forksInitialized) {
            console.log("Skipping test - MAINNET_RPC_URL not set");
            return;
        }

        // Read and parse the JSON file
        string memory json = vm.readFile("celestia_test_cases.json");
        string[] memory testCases = abi.decode(vm.parseJson(json), (string[]));

        console.log("Running", testCases.length, "test cases");

        // Make sure we're using the fork
        vm.selectFork(mainnetFork);

        // Run each test case
        for (uint i = 0; i < testCases.length; i++) {
            console.log("\nTesting case", i);
            
            // Convert hex string to bytes
            bytes memory operatorDAInput = vm.parseBytes(testCases[i]);
            console.log("Parsed input");

            // Decode the input
            CelestiaZKStackInput memory decodedInput = abi.decode(operatorDAInput, (CelestiaZKStackInput));
            console.log("Decoded input");
            (bytes32 eqKeccakHash, bytes32 eqDataRoot) = abi.decode(decodedInput.publicValues, (bytes32, bytes32));
            console.log("Decoded public values");

            console.log("eqKeccakHash", vm.toString(eqKeccakHash));
            console.log("eqDataRoot", vm.toString(eqDataRoot));
            console.log("Input data length:", operatorDAInput.length);

            try validator.checkDA(0, 0, eqKeccakHash, operatorDAInput, MAX_BLOBS_SUPPORTED) returns (L1DAValidatorOutput memory output) {
                console.log("Case", i, "succeeded!");
                console.log("State diff hash:", vm.toString(output.stateDiffHash));
            } catch Error(string memory reason) {
                console.log("Case", i, "failed with reason:", reason);
            } catch (bytes memory) {
                console.log("Case", i, "failed with unknown error");
            }
        }
    }
}
