// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ForceDeployment, IContractDeployer} from "./interfaces/IContractDeployer.sol";
import {ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT, DEPLOYER_SYSTEM_CONTRACT} from "./Constants.sol";
import {EVMEmulationNotSupported, HashMismatch, InvalidInput} from "./SystemContractErrors.sol";
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

    // https://gist.github.com/Agusx1211/de05dabf918d448d315aa018e2572031
    address private constant UNIVERSAL_DEPLOYER = 0x1B926fBB24A9F78DCDd3272f2d86F5D0660E59c0;
    bytes32 private constant UNIVERSAL_DEPLOYER_INPUT_HASH =
        0x9723946f8683ec5fa08df6e3dcda1f58e270d9046d7802090cd8a78bf615850d;
    bytes32 private constant UNIVERSAL_DEPLOYER_BYTECODE_HASH =
        0x020000992c2947f596b268dba258e025e4ae12d2fa66a427d76758a224d34e7d;

    // https://github.com/pcaversaccio/createx
    address private constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 private constant CREATEX_INPUT_HASH = 0x12ec861579b63a3ab9db3b5a23c57d56402ad3061475b088f17054e2f2daf22f;
    bytes32 private constant CREATEX_BYTECODE_HASH = 0x02002e3ece4eb1376472ed3f5a29e6b29eb1bc9543121ae960336f76dbaf3c79;

    /////////////////// GNOSIS SAFE PREDEPLOYS ///////////////////

    // https://github.com/safe-global/safe-smart-account/blob/v1.0.0/contracts/proxies/ProxyFactory.sol
    address private constant SAFE_V_1_0_0_PROXY_FACTORY = 0x12302fE9c02ff50939BaAaaf415fc226C078613C;
    bytes32 private constant SAFE_V_1_0_0_PROXY_FACTORY_INPUT_HASH =
        0xbcacfea0a55dc0390ab8ef100d102719f7661a826928ed9a46c14e2edfea3bf6;
    bytes32 private constant SAFE_V_1_0_0_PROXY_FACTORY_BYTECODE_HASH =
        0x020008c4f0279eb49f9f14b7406d60eb289ca2787d82f483cb86d9e99bb8a101;

    // https://github.com/safe-global/safe-smart-account/blob/v1.0.0/contracts/common/MasterCopy.sol
    address private constant SAFE_V_1_0_0_MASTER_COPY = 0xb6029EA3B2c51D09a50B53CA8012FeEB05bDa35A;
    bytes32 private constant SAFE_V_1_0_0_MASTER_COPY_INPUT_HASH =
        0x97b9ea932e099f632f552d14b853fc6e515cd5e9ecd2deb4ce4af482d6080220;
    bytes32 private constant SAFE_V_1_0_0_MASTER_COPY_BYTECODE_HASH =
        0x02005e93b66a5362f40710b265a726a3e54980ec0671818218495686a7db4dec;

    // https://github.com/safe-global/safe-smart-account/blob/v1.1.1/contracts/proxies/ProxyFactory.sol
    address private constant SAFE_V_1_1_1_PROXY_FACTORY = 0x76E2cFc1F5Fa8F6a5b3fC4c8F4788F0116861F9B;
    bytes32 private constant SAFE_V_1_1_1_PROXY_FACTORY_INPUT_HASH =
        0xdc9862936dccef7f4d711ccb053f33cf4dab76cd12a6206d36c34831f53e2fc4;
    bytes32 private constant SAFE_V_1_1_1_PROXY_FACTORY_BYTECODE_HASH =
        0x02000f73eadfd3b87e92b698ac1ff0b7a437ef26e843a66a9946b7a308620d4c;

    // https://github.com/safe-global/safe-smart-account/blob/v1.1.1/contracts/common/MasterCopy.sol
    address private constant SAFE_V_1_1_1_MASTER_COPY = 0x34CfAC646f301356fAa8B21e94227e3583Fe3F5F;
    bytes32 private constant SAFE_V_1_1_1_MASTER_COPY_INPUT_HASH =
        0x3da4b71b70c73554af3f11c48a590eafa3808a746a69f712cd80b941d28de36e;
    bytes32 private constant SAFE_V_1_1_1_MASTER_COPY_BYTECODE_HASH =
        0x02005de8d155206e252a1b26b5483528523d0b4b4f87e3a5f76e38d52f5d232a;

    // https://github.com/safe-global/safe-smart-account/blob/v1.2.0/contracts/common/MasterCopy.sol
    address private constant SAFE_V_1_2_0_MASTER_COPY = 0x6851D6fDFAfD08c0295C392436245E5bc78B0185;
    bytes32 private constant SAFE_V_1_2_0_MASTER_COPY_INPUT_HASH =
        0x502b90a6c8b2e4005695010b5106ea006c1d128de42fca407ce309024b9266a7;
    bytes32 private constant SAFE_V_1_2_0_MASTER_COPY_BYTECODE_HASH =
        0x02005f5a803376f8aa603948a4d3b6b56e47cdbf0824bcc3ceab8fe14ce27d52;

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
        } else if (contractAddress == UNIVERSAL_DEPLOYER) {
            expectedInputHash = UNIVERSAL_DEPLOYER_INPUT_HASH;
            expectedBytecodeHash = UNIVERSAL_DEPLOYER_BYTECODE_HASH;
        } else if (contractAddress == CREATEX) {
            expectedInputHash = CREATEX_INPUT_HASH;
            expectedBytecodeHash = CREATEX_BYTECODE_HASH;

            // Further we have Gnosis Safe predeploys
        } else if (contractAddress == SAFE_V_1_0_0_PROXY_FACTORY) {
            expectedInputHash = SAFE_V_1_0_0_PROXY_FACTORY_INPUT_HASH;
            expectedBytecodeHash = SAFE_V_1_0_0_PROXY_FACTORY_BYTECODE_HASH;
        } else if (contractAddress == SAFE_V_1_0_0_MASTER_COPY) {
            expectedInputHash = SAFE_V_1_0_0_MASTER_COPY_INPUT_HASH;
            expectedBytecodeHash = SAFE_V_1_0_0_MASTER_COPY_BYTECODE_HASH;
        } else if (contractAddress == SAFE_V_1_1_1_PROXY_FACTORY) {
            expectedInputHash = SAFE_V_1_1_1_PROXY_FACTORY_INPUT_HASH;
            expectedBytecodeHash = SAFE_V_1_1_1_PROXY_FACTORY_BYTECODE_HASH;
        } else if (contractAddress == SAFE_V_1_1_1_MASTER_COPY) {
            expectedInputHash = SAFE_V_1_1_1_MASTER_COPY_INPUT_HASH;
            expectedBytecodeHash = SAFE_V_1_1_1_MASTER_COPY_BYTECODE_HASH;
        } else if (contractAddress == SAFE_V_1_2_0_MASTER_COPY) {
            expectedInputHash = SAFE_V_1_2_0_MASTER_COPY_INPUT_HASH;
            expectedBytecodeHash = SAFE_V_1_2_0_MASTER_COPY_BYTECODE_HASH;
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
