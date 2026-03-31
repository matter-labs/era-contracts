// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {BytecodePublisher} from "./bytecode/BytecodePublisher.s.sol";
import {L1L2DeployUtils} from "./deploy/L1L2DeployUtils.sol";

/// @title VMDeploymentStrategy
/// @notice Centralizes all Era-vs-ZKsyncOS deployment decisions.
/// @dev New code should call this library instead of branching on `isZKsyncOS`.
///      Existing code can be migrated incrementally.
library VMDeploymentStrategy {
    // ======================== 1. Contract name resolution ========================

    function ctmContractName(bool isZKsyncOS) internal pure returns (string memory) {
        return isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
    }

    function verifierFflonkName(bool isZKsyncOS) internal pure returns (string memory) {
        return isZKsyncOS ? "ZKsyncOSVerifierFflonk" : "EraVerifierFflonk";
    }

    function verifierPlonkName(bool isZKsyncOS) internal pure returns (string memory) {
        return isZKsyncOS ? "ZKsyncOSVerifierPlonk" : "EraVerifierPlonk";
    }

    function dualVerifierName(bool isZKsyncOS) internal pure returns (string memory) {
        return isZKsyncOS ? "ZKsyncOSDualVerifier" : "EraDualVerifier";
    }

    function testnetVerifierName(bool isZKsyncOS) internal pure returns (string memory) {
        return isZKsyncOS ? "ZKsyncOSTestnetVerifier" : "EraTestnetVerifier";
    }

    function mainVerifierName(bool isZKsyncOS, bool testnet) internal pure returns (string memory) {
        return testnet ? testnetVerifierName(isZKsyncOS) : dualVerifierName(isZKsyncOS);
    }

    function ntvFileName(bool isZKsyncOS) internal pure returns (string memory) {
        return isZKsyncOS ? "L2NativeTokenVaultZKOS.sol" : "L2NativeTokenVault.sol";
    }

    function ntvContractName(bool isZKsyncOS) internal pure returns (string memory) {
        return isZKsyncOS ? "L2NativeTokenVaultZKOS" : "L2NativeTokenVault";
    }

    function gatewayCTMDeployerName(bool isZKsyncOS) internal pure returns (string memory, string memory) {
        return isZKsyncOS
            ? ("GatewayCTMDeployerCTMZKsyncOS.sol", "GatewayCTMDeployerCTMZKsyncOS")
            : ("GatewayCTMDeployerCTM.sol", "GatewayCTMDeployerCTM");
    }

    function gatewayVerifiersDeployerName(bool isZKsyncOS) internal pure returns (string memory, string memory) {
        return isZKsyncOS
            ? ("GatewayCTMDeployerVerifiersZKsyncOS.sol", "GatewayCTMDeployerVerifiersZKsyncOS")
            : ("GatewayCTMDeployerVerifiers.sol", "GatewayCTMDeployerVerifiers");
    }

    // ======================== 2. Bytecode reading ========================

    /// @notice Read L1 contract bytecode from the correct artifact directory.
    ///         ZKsyncOS uses standard EVM artifacts (out/), Era uses ZK artifacts (zkout/).
    function readBytecodeL1(
        bool isZKsyncOS,
        string memory fileName,
        string memory contractName
    ) internal returns (bytes memory) {
        return isZKsyncOS
            ? Utils.readFoundryBytecodeL1(fileName, contractName)
            : Utils.readZKFoundryBytecodeL1(fileName, contractName);
    }

    // ======================== 3. Bytecode info encoding ========================

    /// @notice Get bytecode info for force deployments.
    ///         Era returns abi.encode(L2BytecodeHash), ZKsyncOS returns proxy upgrade bytecode info.
    ///         Uses the same file/contract name for both VMs.
    function getBytecodeInfo(
        bool isZKsyncOS,
        string memory contractName
    ) internal returns (bytes memory) {
        return getBytecodeInfo(
            isZKsyncOS,
            contractName,
            string.concat(contractName, ".sol"),
            contractName
        );
    }

    /// @notice Get bytecode info when Era and ZKsyncOS use different contract names.
    function getBytecodeInfo(
        bool isZKsyncOS,
        string memory eraContractName,
        string memory zkosFileName,
        string memory zkosContractName
    ) internal returns (bytes memory) {
        if (isZKsyncOS) {
            return Utils.getZKOSProxyUpgradeBytecodeInfo(zkosFileName, zkosContractName);
        }
        return abi.encode(
            L2ContractHelper.hashL2Bytecode(
                Utils.readZKFoundryBytecodeL1(
                    string.concat(eraContractName, ".sol"),
                    eraContractName
                )
            )
        );
    }

    /// @notice Get a bytecode hash suitable for force deployments.
    ///         Era hashes via L2ContractHelper, ZKsyncOS uses keccak256 of deployed bytecode.
    function getBytecodeHash(
        bool isZKsyncOS,
        string memory contractName
    ) internal view returns (bytes32) {
        return getBytecodeHash(
            isZKsyncOS,
            contractName,
            string.concat(contractName, ".sol"),
            contractName
        );
    }

    function getBytecodeHash(
        bool isZKsyncOS,
        string memory eraContractName,
        string memory zkosFileName,
        string memory zkosContractName
    ) internal view returns (bytes32) {
        if (isZKsyncOS) {
            return keccak256(Utils.readFoundryDeployedBytecodeL1(zkosFileName, zkosContractName));
        }
        return L2ContractHelper.hashL2Bytecode(
            Utils.readZKFoundryBytecodeL1(
                string.concat(eraContractName, ".sol"),
                eraContractName
            )
        );
    }

    // ======================== 4. CREATE2 address computation ========================

    /// @notice Compute a CREATE2 address using the VM-appropriate derivation.
    function computeCreate2Address(
        bool isZKsyncOS,
        address deployer,
        bytes32 salt,
        bytes memory bytecode,
        bytes memory constructorArgs
    ) internal returns (address) {
        if (isZKsyncOS) {
            bytes memory initCode = abi.encodePacked(bytecode, constructorArgs);
            return Utils.vm.computeCreate2Address(salt, keccak256(initCode), deployer);
        }
        return L2ContractHelper.computeCreate2Address(
            deployer,
            salt,
            L2ContractHelper.hashL2Bytecode(bytecode),
            keccak256(constructorArgs)
        );
    }

    // ======================== 5. Factory deps / bytecode publishing ========================

    /// @notice Publish bytecodes to BytecodesSupplier using the VM-appropriate method.
    function publishBytecodes(
        bool isZKsyncOS,
        BytecodesSupplier supplier,
        bytes[] memory deps
    ) internal {
        if (isZKsyncOS) {
            BytecodePublisher.publishEVMBytecodesInBatches(supplier, deps);
        } else {
            BytecodePublisher.publishEraBytecodesInBatches(supplier, deps);
        }
    }

    // ======================== 6. Genesis / config paths ========================

    function genesisConfigFilename(bool isZKsyncOS) internal pure returns (string memory) {
        return isZKsyncOS ? "zksync-os/latest.json" : "era/latest.json";
    }

    function genesisConfigPath(bool isZKsyncOS) internal returns (string memory) {
        return string.concat(
            Utils.vm.projectRoot(),
            "/../configs/genesis/",
            genesisConfigFilename(isZKsyncOS)
        );
    }

    // ======================== 7. Verifier constructor args ========================

    /// @notice ZKsyncOS verifiers take an extra `owner` parameter.
    function verifierCreationArgs(
        bool isZKsyncOS,
        address fflonk,
        address plonk,
        address owner
    ) internal pure returns (bytes memory) {
        if (isZKsyncOS) {
            return abi.encode(fflonk, plonk, owner);
        }
        return abi.encode(fflonk, plonk);
    }
}
