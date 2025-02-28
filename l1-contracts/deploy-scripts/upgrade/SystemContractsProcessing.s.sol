// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Utils, L2_WETH_IMPL_ADDRESS, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "../Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {L2ContractsBytecodesLib} from "../L2ContractsBytecodesLib.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

// solhint-disable no-console, gas-custom-errors

/// @notice Enum representing the programming language of the contract
enum Language {
    Solidity,
    Yul
}

/// @notice Struct representing a system contract's details
struct SystemContract {
    address addr; // Contract address
    string codeName; // Name of the contract code
    Language lang; // Programming language used
    bool isPrecompile; // Whether precompile or not
}

/// @dev The number of built-in contracts that reside within the "system-contracts" folder
uint256 constant SYSTEM_CONTRACTS_COUNT = 31;
/// @dev The number of built-in contracts that reside within the `l1-contracts` folder
uint256 constant OTHER_BUILT_IN_CONTRACTS_COUNT = 5;

library SystemContractsProcessing {
    /// @notice Retrieves the entire list of system contracts as a memory array
    /// @dev Note that it does not include all built-in contracts. Rather all those
    /// that are based in the `system-contracts` folder.
    /// @return An array of SystemContract structs containing all system contracts
    function getSystemContracts() public pure returns (SystemContract[] memory) {
        // Initialize the in-memory array
        SystemContract[] memory systemContracts = new SystemContract[](SYSTEM_CONTRACTS_COUNT);

        // Populate the array with system contract details
        // Populate the array with system contract details using named parameters
        systemContracts[0] = SystemContract({
            addr: 0x0000000000000000000000000000000000000000,
            codeName: "EmptyContract",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[1] = SystemContract({
            addr: 0x0000000000000000000000000000000000000001,
            codeName: "Ecrecover",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[2] = SystemContract({
            addr: 0x0000000000000000000000000000000000000002,
            codeName: "SHA256",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[3] = SystemContract({
            addr: 0x0000000000000000000000000000000000000004,
            codeName: "Identity",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[4] = SystemContract({
            addr: 0x0000000000000000000000000000000000000006,
            codeName: "EcAdd",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[5] = SystemContract({
            addr: 0x0000000000000000000000000000000000000007,
            codeName: "EcMul",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[6] = SystemContract({
            addr: 0x0000000000000000000000000000000000000008,
            codeName: "EcPairing",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[7] = SystemContract({
            addr: 0x0000000000000000000000000000000000008001,
            codeName: "EmptyContract",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[8] = SystemContract({
            addr: 0x0000000000000000000000000000000000008002,
            codeName: "AccountCodeStorage",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[9] = SystemContract({
            addr: 0x0000000000000000000000000000000000008003,
            codeName: "NonceHolder",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[10] = SystemContract({
            addr: 0x0000000000000000000000000000000000008004,
            codeName: "KnownCodesStorage",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[11] = SystemContract({
            addr: 0x0000000000000000000000000000000000008005,
            codeName: "ImmutableSimulator",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[12] = SystemContract({
            addr: 0x0000000000000000000000000000000000008006,
            codeName: "ContractDeployer",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[13] = SystemContract({
            addr: 0x0000000000000000000000000000000000008008,
            codeName: "L1Messenger",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[14] = SystemContract({
            addr: 0x0000000000000000000000000000000000008009,
            codeName: "MsgValueSimulator",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[15] = SystemContract({
            addr: 0x000000000000000000000000000000000000800A,
            codeName: "L2BaseToken",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[16] = SystemContract({
            addr: 0x000000000000000000000000000000000000800B,
            codeName: "SystemContext",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[17] = SystemContract({
            addr: 0x000000000000000000000000000000000000800c,
            codeName: "BootloaderUtilities",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[18] = SystemContract({
            addr: 0x000000000000000000000000000000000000800d,
            codeName: "EventWriter",
            lang: Language.Yul,
            isPrecompile: false
        });

        systemContracts[19] = SystemContract({
            addr: 0x000000000000000000000000000000000000800E,
            codeName: "Compressor",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[20] = SystemContract({
            addr: 0x000000000000000000000000000000000000800f,
            codeName: "ComplexUpgrader",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[21] = SystemContract({
            addr: 0x0000000000000000000000000000000000008010,
            codeName: "Keccak256",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[22] = SystemContract({
            addr: 0x0000000000000000000000000000000000008012,
            codeName: "CodeOracle",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[23] = SystemContract({
            addr: 0x0000000000000000000000000000000000008013,
            codeName: "EvmGasManager",
            lang: Language.Yul,
            isPrecompile: false
        });

        systemContracts[24] = SystemContract({
            addr: 0x0000000000000000000000000000000000008014,
            codeName: "EvmPredeploysManager",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[25] = SystemContract({
            addr: 0x0000000000000000000000000000000000008015,
            codeName: "EvmHashesStorage",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[26] = SystemContract({
            addr: 0x0000000000000000000000000000000000000100,
            codeName: "P256Verify",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[27] = SystemContract({
            addr: 0x0000000000000000000000000000000000008011,
            codeName: "PubdataChunkPublisher",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[28] = SystemContract({
            addr: 0x0000000000000000000000000000000000010000,
            codeName: "Create2Factory",
            lang: Language.Solidity,
            isPrecompile: false
        });
        systemContracts[29] = SystemContract({
            addr: 0x0000000000000000000000000000000000010001,
            codeName: "L2GenesisUpgrade",
            lang: Language.Solidity,
            isPrecompile: false
        });
        systemContracts[30] = SystemContract({
            addr: 0x0000000000000000000000000000000000010006,
            codeName: "SloadContract",
            lang: Language.Solidity,
            isPrecompile: false
        });

        return systemContracts;
    }

    /// @notice Deduplicates the array of bytecodes.
    function deduplicateBytecodes(bytes[] memory input) internal returns (bytes[] memory output) {
        // A more efficient way would be to sort + deduplicate, but
        // there is no built-in sorting in Solidity + this function should be only
        // used in scripts, so ineffiency is fine.
        // We'll do it on O(N^2)

        // In O(N^2) we'll mark duplicated hashes as zeroes.
        bytes32[] memory hashes = new bytes32[](input.length);
        for (uint256 i = 0; i < input.length; i++) {
            hashes[i] = keccak256(input[i]);
        }

        uint256 toInclude = 0;

        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] != bytes32(0)) {
                toInclude += 1;
            }

            for (uint j = i + 1; j < hashes.length; j++) {
                if (hashes[i] == hashes[j]) {
                    hashes[j] = bytes32(0);
                }
            }
        }

        output = new bytes[](toInclude);
        uint256 included = 0;
        for (uint256 i = 0; i < input.length; i++) {
            if (hashes[i] != bytes32(0)) {
                output[included] = input[i];
                ++included;
            }
        }

        // Sanity check
        require(included == toInclude, "Internal error: included != toInclude");
    }

    function getSystemContractsBytecodes() internal returns (bytes[] memory result) {
        result = new bytes[](SYSTEM_CONTRACTS_COUNT);

        SystemContract[] memory systemContracts = getSystemContracts();
        for (uint256 i = 0; i < SYSTEM_CONTRACTS_COUNT; i++) {
            if (systemContracts[i].isPrecompile) {
                result[i] = Utils.readPrecompileBytecode(systemContracts[i].codeName);
            } else {
                if (systemContracts[i].lang == Language.Solidity) {
                    result[i] = Utils.readSystemContractsBytecode(systemContracts[i].codeName);
                } else {
                    result[i] = Utils.readSystemContractsYulBytecode(systemContracts[i].codeName);
                }
            }
        }
    }

    function getSystemContractsForceDeployments()
        internal
        returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments)
    {
        forceDeployments = new IL2ContractDeployer.ForceDeployment[](SYSTEM_CONTRACTS_COUNT);

        SystemContract[] memory systemContracts = getSystemContracts();
        bytes[] memory bytecodes = getSystemContractsBytecodes();
        for (uint256 i = 0; i < SYSTEM_CONTRACTS_COUNT; i++) {
            forceDeployments[i] = IL2ContractDeployer.ForceDeployment({
                bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes[i]),
                newAddress: systemContracts[i].addr,
                callConstructor: false,
                value: 0,
                input: ""
            });
        }
    }

    function getOtherContractsBytecodes() internal view returns (bytes[] memory result) {
        result = new bytes[](OTHER_BUILT_IN_CONTRACTS_COUNT);

        result[0] = L2ContractsBytecodesLib.readBridgehubBytecode();
        result[1] = L2ContractsBytecodesLib.readL2AssetRouterBytecode();
        result[2] = L2ContractsBytecodesLib.readL2NativeTokenVaultBytecode();
        result[3] = L2ContractsBytecodesLib.readMessageRootBytecode();
        result[4] = L2ContractsBytecodesLib.readL2WrappedBaseToken();
    }

    /// Note, that while proper initialization may require multiple steps,
    /// those will be conducted inside a specialized upgrade. We still provide
    /// these force deployments here for the sake of consistency
    function getOtherBuiltinForceDeployments()
        internal
        returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments)
    {
        forceDeployments = new IL2ContractDeployer.ForceDeployment[](OTHER_BUILT_IN_CONTRACTS_COUNT);
        bytes[] memory bytecodes = getOtherContractsBytecodes();

        forceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes[0]),
            newAddress: L2_BRIDGEHUB_ADDRESS,
            callConstructor: false,
            value: 0,
            input: ""
        });
        forceDeployments[1] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes[1]),
            newAddress: L2_ASSET_ROUTER_ADDRESS,
            callConstructor: false,
            value: 0,
            input: ""
        });
        forceDeployments[2] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes[2]),
            newAddress: L2_NATIVE_TOKEN_VAULT_ADDRESS,
            callConstructor: false,
            value: 0,
            input: ""
        });
        forceDeployments[3] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes[3]),
            newAddress: L2_MESSAGE_ROOT_ADDRESS,
            callConstructor: false,
            value: 0,
            input: ""
        });
        forceDeployments[4] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes[4]),
            newAddress: L2_WETH_IMPL_ADDRESS,
            callConstructor: false,
            value: 0,
            input: ""
        });
    }

    function forceDeploymentsToHashes(
        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments
    ) internal returns (bytes32[] memory hashes) {
        hashes = new bytes32[](baseForceDeployments.length);
        for (uint256 i = 0; i < baseForceDeployments.length; i++) {
            hashes[i] = baseForceDeployments[i].bytecodeHash;
        }
    }

    function mergeForceDeployments(
        IL2ContractDeployer.ForceDeployment[] memory left,
        IL2ContractDeployer.ForceDeployment[] memory right
    ) internal returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments) {
        forceDeployments = new IL2ContractDeployer.ForceDeployment[](left.length + right.length);
        for (uint256 i = 0; i < left.length; i++) {
            forceDeployments[i] = left[i];
        }
        for (uint256 i = 0; i < right.length; i++) {
            forceDeployments[left.length + i] = right[i];
        }
    }

    function mergeBytesArrays(bytes[] memory left, bytes[] memory right) internal returns (bytes[] memory result) {
        result = new bytes[](left.length + right.length);
        for (uint256 i = 0; i < left.length; i++) {
            result[i] = left[i];
        }
        for (uint256 i = 0; i < right.length; i++) {
            result[left.length + i] = right[i];
        }
    }

    function getBaseForceDeployments()
        internal
        returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments)
    {
        IL2ContractDeployer.ForceDeployment[] memory otherForceDeployments = getOtherBuiltinForceDeployments();
        IL2ContractDeployer.ForceDeployment[] memory systemForceDeployments = getSystemContractsForceDeployments();

        forceDeployments = mergeForceDeployments(systemForceDeployments, otherForceDeployments);
    }

    function getBaseListOfDependencies() internal returns (bytes[] memory factoryDeps) {
        // Note that it is *important* that these go first in this exact order,
        // since the server will rely on it.
        bytes[] memory basicBytecodes = new bytes[](3);
        basicBytecodes[0] = Utils.getBatchBootloaderBytecodeHash();
        basicBytecodes[1] = Utils.readSystemContractsBytecode("DefaultAccount");
        basicBytecodes[2] = Utils.getEvmEmulatorBytecodeHash();

        bytes[] memory systemBytecodes = getSystemContractsBytecodes();
        bytes[] memory otherBytecodes = getOtherContractsBytecodes();

        factoryDeps = mergeBytesArrays(mergeBytesArrays(basicBytecodes, systemBytecodes), otherBytecodes);
    }
}
