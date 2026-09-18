// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {IAccountCodeStorage} from "../common/interfaces/IAccountCodeStorage.sol";
import {
    L2_ACCOUNT_CODE_STORAGE_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @notice Deployment info for the Across protocol on a specific L2 chain.
struct AcrossInfo {
    /// @notice The address of the Across proxy contract.
    address proxy;
    /// @notice The address of the Across EVM implementation contract.
    address evmImplementation;
    /// @notice The address of the Across ZKsync Era recovery implementation contract.
    address zkevmRecoveryImplementation;
    /// @notice The constructor calldata for the ZKsync Era recovery implementation.
    LensSpokePoolConstructorParams zkevmRecoveryImplConstructorParams;
}

struct LensSpokePoolConstructorParams {
    address wrappedNativeTokenAddress;
    address circleUSDC;
    address zkUSDCBridge;
    address cctpTokenMessenger;
    uint32 depositQuoteTimeBuffer;
    uint32 fillDeadlineBuffer;
}

/// @dev The L2 chain id of the Lens network where the Across proxy is deployed.
uint256 constant LENS_MAINNET_CHAIN_ID = 232;

/// @title V31AcrossRecovery
/// @author Matter Labs
/// @notice Abstract contract for performing emergency recovery of the Across protocol on ZKsync Era.
/// @dev Marked as abstract (rather than a library) so that `getAcrossInfo` can be overridden in tests
/// to supply custom deployment addresses.
/// @dev Not expected to be used as a standalone contract, but rather to be inherited by L2V31Upgrade.
abstract contract V31AcrossRecovery {
    /// @notice Returns the Across deployment info for the current L2 chain.
    /// @dev It is virtual so that we can override it in tests to provide custom Across deployment info.
    /// @dev It is marked as view for easier testing, even though on mainnet the hardcoded values below will be used.
    /// @return info The Across deployment info. All zeros if no deployment is known for the current chain.
    function getAcrossInfo() internal view virtual returns (AcrossInfo memory info) {
        if (block.chainid == LENS_MAINNET_CHAIN_ID) {
            info = AcrossInfo({
                proxy: 0xe7cb3e167e7475dE1331Cf6E0CEb187654619E12,
                evmImplementation: 0xc7772Ce23a3ED7F87fE51b87617C7C7d21f15d39,
                zkevmRecoveryImplementation: 0x11c9d12cC96Ae9B1fb30eb5D2D2a6F85656917e5,
                zkevmRecoveryImplConstructorParams: LensSpokePoolConstructorParams({
                    wrappedNativeTokenAddress: address(0x6bDc36E20D267Ff0dd6097799f82e78907105e2F),
                    circleUSDC: address(0x88F08E304EC4f90D644Cec3Fb69b8aD414acf884),
                    zkUSDCBridge: address(0x7188B6975EeC82ae914b6eC7AC32b3c9a18b2c81),
                    cctpTokenMessenger: address(0x0000000000000000000000000000000000000000),
                    depositQuoteTimeBuffer: uint32(3600),
                    fillDeadlineBuffer: uint32(21600)
                })
            });
        }
        // Default: all fields are zero.
    }

    /// @notice Performs the Across recovery by force-deploying the recovery implementation bytecode
    ///         at the EVM implementation address.
    function acrossRecovery() internal {
        AcrossInfo memory info = getAcrossInfo();

        if (info.proxy == address(0)) {
            return;
        }

        // Read the bytecode hash of the recovery implementation.
        bytes32 recoveryBytecodeHash = IAccountCodeStorage(L2_ACCOUNT_CODE_STORAGE_ADDR).getRawCodeHash(
            info.zkevmRecoveryImplementation
        );

        // Force deploy the recovery implementation bytecode at the EVM implementation address.
        IL2ContractDeployer.ForceDeployment[] memory deployments = new IL2ContractDeployer.ForceDeployment[](1);
        deployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: recoveryBytecodeHash,
            newAddress: info.evmImplementation,
            callConstructor: true,
            value: 0,
            input: abi.encode(
                info.zkevmRecoveryImplConstructorParams.wrappedNativeTokenAddress,
                info.zkevmRecoveryImplConstructorParams.circleUSDC,
                info.zkevmRecoveryImplConstructorParams.zkUSDCBridge,
                info.zkevmRecoveryImplConstructorParams.cctpTokenMessenger,
                info.zkevmRecoveryImplConstructorParams.depositQuoteTimeBuffer,
                info.zkevmRecoveryImplConstructorParams.fillDeadlineBuffer
            )
        });

        IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(deployments);
    }
}
