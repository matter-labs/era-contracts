// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {DEPLOYER_SYSTEM_CONTRACT, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "./constants.sol";
import {EVMEmulationNotSupported, InvalidInput} from "./SystemContractErrors.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The deployer of special widely-used EVM contracts to pre-defined addresses.
 */
contract EvmPredeploysManager {
    // https://github.com/Arachnid/deterministic-deployment-proxy
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant CREATE2_PROXY_INPUT_HASH = 0x50ea9137a35a9ad33b0ed4a431e9b6996ea9ed1f14781126cec78f168c0e64e5;

    // https://github.com/pcaversaccio/create2deployer
    address constant CREATE2_DEPLOYER = 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2;
    bytes32 constant CREATE2_DEPLOYER_INPUT_HASH = 0xc9cdbda80cd4ba1961148079822602f7bd7619c26f78fec2fd1fc0beaf39d7d0;

    // https://eips.ethereum.org/EIPS/eip-2470
    address constant ERC2470_SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    bytes32 constant ERC2470_SINGLETON_FACTORY_INPUT_HASH =
        0x122b6b28aeddfd05fa3ce4348e93d357b3ce50d9ab7dda4e8ee524a5b9a6ab3b;

    // https://github.com/safe-global/safe-singleton-factory/blob/main/source/deterministic-deployment-proxy.yul
    address constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    bytes32 constant SAFE_SINGLETON_FACTORY_INPUT_HASH =
        0x50ea9137a35a9ad33b0ed4a431e9b6996ea9ed1f14781126cec78f168c0e64e5;

    // https://github.com/mds1/multicall/tree/main
    address constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    bytes32 constant MULTICALL3_INPUT_HASH = 0x0b2046aa018109118d518235014ac2c679dcbdff32c64705fdf50d048cd32d22;

    function deployPredeployedContract(
        address _contract,
        bytes calldata constructorInput
    ) external returns (bytes32 bytecodeHash) {
        if (
            DEPLOYER_SYSTEM_CONTRACT.allowedBytecodeTypesToDeploy() !=
            IContractDeployer.AllowedBytecodeTypes.EraVmAndEVM
        ) {
            revert EVMEmulationNotSupported();
        }

        bytes32 inputHash = EfficientCall.keccak(constructorInput);
        bytes32 expectedInputHash;

        if (_contract == CREATE2_PROXY) {
            expectedInputHash = CREATE2_PROXY_INPUT_HASH;
        } else if (_contract == CREATE2_DEPLOYER) {
            expectedInputHash = CREATE2_DEPLOYER_INPUT_HASH;
        } else if (_contract == ERC2470_SINGLETON_FACTORY) {
            expectedInputHash = ERC2470_SINGLETON_FACTORY_INPUT_HASH;
        } else if (_contract == SAFE_SINGLETON_FACTORY) {
            expectedInputHash = SAFE_SINGLETON_FACTORY_INPUT_HASH;
        } else if (_contract == MULTICALL3) {
            expectedInputHash = MULTICALL3_INPUT_HASH;
        } else {
            revert InvalidInput();
        }

        if (inputHash != expectedInputHash) {
            revert InvalidInput();
        }

        if (ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(_contract) != bytes32(0)) {
            return bytes32(0); // TODO
        }

        ForceDeployment[] memory deployments = new ForceDeployment[](1);
        deployments[0] = ForceDeployment({
            bytecodeHash: bytes32(0),
            newAddress: _contract,
            callConstructor: true,
            value: 0,
            input: constructorInput
        });

        DEPLOYER_SYSTEM_CONTRACT.forceDeployOnAddresses(deployments);

        return ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(_contract);
    }
}
