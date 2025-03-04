// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {DEPLOYER_SYSTEM_CONTRACT, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "./Constants.sol";
import {EVMEmulationNotSupported, InvalidInput, HashMismatch} from "./SystemContractErrors.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The deployer of special widely-used EVM contracts to pre-defined addresses (usually done with presigned keyless transactions).
 */
contract EvmPredeploysManager {
    // https://github.com/Arachnid/deterministic-deployment-proxy
    address private constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 private constant CREATE2_PROXY_INPUT_HASH =
        0x50ea9137a35a9ad33b0ed4a431e9b6996ea9ed1f14781126cec78f168c0e64e5;
    bytes32 private constant CREATE2_PROXY_BYTECODE_HASH =
        0x020000453cf89ad86bc13761a15f8f205faa1dbb41ccd3553352fa3c5dd3a9a0;

    // https://github.com/Zoltu/deterministic-deployment-proxy
    address private constant DETERMINISTIC_CREATE2_PROXY = 0x7A0D94F55792C434d74a40883C6ed8545E406D12;
    bytes32 private constant DETERMINISTIC_CREATE2_PROXY_INPUT_HASH =
        0xa4d93d1dea5ac777c77f60dfbe95efcfc8847f592b1fb7e235171ed60949f4b0;
    bytes32 private constant DETERMINISTIC_CREATE2_PROXY_BYTECODE_HASH =
        0x0200001f3bd554e541ab39bcf6e19564c9a6cbd700acceb65bfad0170c324d95;

    // https://github.com/pcaversaccio/create2deployer
    address private constant CREATE2_DEPLOYER = 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2;
    bytes32 private constant CREATE2_DEPLOYER_INPUT_HASH =
        0xc9cdbda80cd4ba1961148079822602f7bd7619c26f78fec2fd1fc0beaf39d7d0;
    bytes32 private constant CREATE2_DEPLOYER_BYTECODE_HASH =
        0x02000aab5ea35752b7904cb5c3d2a2608f283b04c4da41202326c0f712c85568;

    // https://eips.ethereum.org/EIPS/eip-2470
    address private constant ERC2470_SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    bytes32 private constant ERC2470_SINGLETON_FACTORY_INPUT_HASH =
        0x122b6b28aeddfd05fa3ce4348e93d357b3ce50d9ab7dda4e8ee524a5b9a6ab3b;
    bytes32 private constant ERC2470_SINGLETON_FACTORY_BYTECODE_HASH =
        0x0200013423ebb21b5377c3afaef4cbb0117243b48d1b32a751500760027b87a4;

    // https://github.com/safe-global/safe-singleton-factory/blob/main/source/deterministic-deployment-proxy.yul
    address private constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    bytes32 private constant SAFE_SINGLETON_FACTORY_INPUT_HASH =
        0x50ea9137a35a9ad33b0ed4a431e9b6996ea9ed1f14781126cec78f168c0e64e5;
    bytes32 private constant SAFE_SINGLETON_FACTORY_BYTECODE_HASH =
        0x020000453cf89ad86bc13761a15f8f205faa1dbb41ccd3553352fa3c5dd3a9a0;

    // https://github.com/mds1/multicall/tree/main
    address private constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    bytes32 private constant MULTICALL3_INPUT_HASH = 0x0b2046aa018109118d518235014ac2c679dcbdff32c64705fdf50d048cd32d22;
    bytes32 private constant MULTICALL3_BYTECODE_HASH =
        0x02000ee02baee85cacb504f6ee1df7aad6809ac8d94a4a111d76991f90d36d6e;

    /// @notice The method used to deploy pre-defined contract at specified address
    /// @dev Can only use the date of the corresponding presigned deployment transaction as constructorInput
    /// @param contractAddress The address of contract
    /// @param constructorInput The input data for constructor
    function deployPredeployedContract(address contractAddress, bytes calldata constructorInput) external {
        if (
            DEPLOYER_SYSTEM_CONTRACT.allowedBytecodeTypesToDeploy() !=
            IContractDeployer.AllowedBytecodeTypes.EraVmAndEVM
        ) {
            revert EVMEmulationNotSupported();
        }

        bytes32 inputHash = EfficientCall.keccak(constructorInput);
        bytes32 expectedInputHash;
        bytes32 expectedBytecodeHash;

        if (contractAddress == CREATE2_PROXY) {
            expectedInputHash = CREATE2_PROXY_INPUT_HASH;
            expectedBytecodeHash = CREATE2_PROXY_BYTECODE_HASH;
        } else if (contractAddress == DETERMINISTIC_CREATE2_PROXY) {
            expectedInputHash = DETERMINISTIC_CREATE2_PROXY_INPUT_HASH;
            expectedBytecodeHash = DETERMINISTIC_CREATE2_PROXY_BYTECODE_HASH;
        } else if (contractAddress == CREATE2_DEPLOYER) {
            expectedInputHash = CREATE2_DEPLOYER_INPUT_HASH;
            expectedBytecodeHash = CREATE2_DEPLOYER_BYTECODE_HASH;
        } else if (contractAddress == ERC2470_SINGLETON_FACTORY) {
            expectedInputHash = ERC2470_SINGLETON_FACTORY_INPUT_HASH;
            expectedBytecodeHash = ERC2470_SINGLETON_FACTORY_BYTECODE_HASH;
        } else if (contractAddress == SAFE_SINGLETON_FACTORY) {
            expectedInputHash = SAFE_SINGLETON_FACTORY_INPUT_HASH;
            expectedBytecodeHash = SAFE_SINGLETON_FACTORY_BYTECODE_HASH;
        } else if (contractAddress == MULTICALL3) {
            expectedInputHash = MULTICALL3_INPUT_HASH;
            expectedBytecodeHash = MULTICALL3_BYTECODE_HASH;
        } else {
            revert InvalidInput();
        }

        if (inputHash != expectedInputHash) {
            revert InvalidInput();
        }

        if (ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(contractAddress) == expectedBytecodeHash) {
            // Already deployed
            return;
        }

        ForceDeployment[] memory deployments = new ForceDeployment[](1);
        deployments[0] = ForceDeployment({
            bytecodeHash: bytes32(0x0200000000000000000000000000000000000000000000000000000000000000), // BytecodeHash is ignored for EVM deploys with constructor call
            newAddress: contractAddress,
            callConstructor: true,
            value: 0,
            input: constructorInput
        });

        DEPLOYER_SYSTEM_CONTRACT.forceDeployOnAddresses(deployments);

        bytes32 actualBytecodeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(contractAddress);
        if (actualBytecodeHash != expectedBytecodeHash) {
            revert HashMismatch(expectedBytecodeHash, actualBytecodeHash);
        }
    }
}
