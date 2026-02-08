// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {IAccountCodeStorage} from "../common/interfaces/IAccountCodeStorage.sol";
import {L2_ACCOUNT_CODE_STORAGE_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @notice Deployment info for the Across protocol on a specific L2 chain.
struct AcrossInfo {
    /// @notice The address of the Across proxy contract.
    address proxy;
    /// @notice The address of the Across EVM implementation contract.
    address evmImplementation;
    /// @notice The address of the Across ZKsync Era recovery implementation contract.
    address zkevmRecoveryImplementation;
    /// @notice The expected L2 chain id where this deployment lives.
    uint256 expectedL2ChainId;
}

/// @title V31AcrossRecovery
/// @author Matter Labs
/// @notice Abstract contract for performing emergency recovery of the Across protocol on ZKsync Era.
/// @dev Marked as abstract (rather than a library) so that `getAcrossInfo` can be overridden in tests
/// to supply custom deployment addresses.
/// @dev Not expected to be used as a standalone contract, but rather to be inherited by L2V31Upgrade.
abstract contract V31AcrossRecovery {
    /// @notice Returns the Across deployment info based on the L1 chain id.
    /// @dev It is virtual so that we can override it in tests to provide custom Across deployment info.
    /// @dev It is marked as view for easier testing, even though on mainnet the hardcoded values below will be used.
    /// @param _l1ChainId The L1 chain id.
    /// @return info The Across deployment info. All zeros if no deployment is known for the given L1 chain id.
    function getAcrossInfo(uint256 _l1ChainId) internal virtual view returns (AcrossInfo memory info) {
        if (_l1ChainId == 1) {
            info = AcrossInfo({
                proxy: 0xe7cb3e167e7475dE1331Cf6E0CEb187654619E12,
                evmImplementation: 0xc7772Ce23a3ED7F87fE51b87617C7C7d21f15d39,
                zkevmRecoveryImplementation: 0x11c9d12cC96Ae9B1fb30eb5D2D2a6F85656917e5,
                expectedL2ChainId: 232
            });
        }
        // Default: all fields are zero.
    }

    /// @notice Performs the Across recovery by force-deploying the recovery implementation bytecode
    ///         at the EVM implementation address.
    /// @param _l1ChainId The L1 chain id used to determine the correct Across deployment info.
    function acrossRecovery(uint256 _l1ChainId) internal {
        AcrossInfo memory info = getAcrossInfo(_l1ChainId);

        if (info.expectedL2ChainId == 0 || info.expectedL2ChainId != block.chainid) {
            return;
        }

        // Read the bytecode hash of the recovery implementation.
        bytes32 recoveryBytecodeHash = IAccountCodeStorage(L2_ACCOUNT_CODE_STORAGE_ADDR)
            .getRawCodeHash(info.zkevmRecoveryImplementation);

        // Force deploy the recovery implementation bytecode at the EVM implementation address.
        IL2ContractDeployer.ForceDeployment[] memory deployments = new IL2ContractDeployer.ForceDeployment[](1);
        deployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: recoveryBytecodeHash,
            newAddress: info.evmImplementation,
            callConstructor: false,
            value: 0,
            input: hex""
        });

        IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(deployments);
    }
}
