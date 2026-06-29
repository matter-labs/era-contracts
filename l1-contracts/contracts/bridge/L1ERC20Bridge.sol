// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "./interfaces/IL1Nullifier.sol";
import {IL1NativeTokenVault} from "./ntv/IL1NativeTokenVault.sol";
import {IL1AssetRouter} from "./asset-router/IL1AssetRouter.sol";

import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

import {WithdrawalAlreadyFinalized} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Smart contract that allows depositing ERC20 tokens from Ethereum to ZK chains
/// @dev It is a legacy bridge from ZKsync Era, that was deprecated in favour of shared bridge.
/// It is needed for backward compatibility with already integrated projects.
contract L1ERC20Bridge is IL1ERC20Bridge, ReentrancyGuard {
    /// @dev The shared bridge that is now used for all bridging, replacing the legacy contract.
    IL1Nullifier public immutable override L1_NULLIFIER;

    /// @dev The asset router, which holds deposited tokens.
    IL1AssetRouter public immutable override L1_ASSET_ROUTER;

    /// @dev The native token vault, which holds deposited tokens.
    IL1NativeTokenVault public immutable override L1_NATIVE_TOKEN_VAULT;

    /// @dev The chainId of Era
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev A mapping L2 batch number => message number => flag.
    /// @dev Used to indicate that L2 -> L1 message was already processed for ZKsync Era withdrawals.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized))
        public isWithdrawalFinalized;

    /// @dev A mapping account => L1 token address => L2 deposit transaction hash => amount.
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail in ZKsync Era.
    mapping(address account => mapping(address l1Token => mapping(bytes32 depositL2TxHash => uint256 amount)))
        public depositAmount;

    /// @dev The address that is used as a L2 bridge counterpart in ZKsync Era.
    // slither-disable-next-line uninitialized-state
    address public l2Bridge;

    /// @dev The address that is used as a beacon for L2 tokens in ZKsync Era.
    // slither-disable-next-line uninitialized-state
    address public l2TokenBeacon;

    /// @dev Stores the hash of the L2 token proxy contract's bytecode on ZKsync Era.
    // slither-disable-next-line uninitialized-state
    bytes32 public l2TokenProxyBytecodeHash;

    /// @dev Deprecated storage variable related to withdrawal limitations.
    mapping(address => uint256) private __DEPRECATED_lastWithdrawalLimitReset;

    /// @dev Deprecated storage variable related to withdrawal limitations.
    mapping(address => uint256) private __DEPRECATED_withdrawnAmountInWindow;

    /// @dev Deprecated storage variable related to deposit limitations.
    mapping(address => mapping(address => uint256)) private __DEPRECATED_totalDepositedAmountPerUser;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        IL1Nullifier _nullifier,
        IL1AssetRouter _assetRouter,
        IL1NativeTokenVault _nativeTokenVault,
        uint256 _eraChainId
    ) reentrancyGuardInitializer {
        L1_NULLIFIER = _nullifier;
        L1_ASSET_ROUTER = _assetRouter;
        L1_NATIVE_TOKEN_VAULT = _nativeTokenVault;
        ERA_CHAIN_ID = _eraChainId;
    }

    /// @notice Initializes the reentrancy guard for the proxy implementation.
    function initialize() external reentrancyGuardInitializer {}

    /*//////////////////////////////////////////////////////////////
                            ERA LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        require(!isWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex], WithdrawalAlreadyFinalized());
        // We don't need to set finalizeWithdrawal here, as we set it in the L1 Nullifier

        FinalizeL1DepositParams memory finalizeWithdrawalParams = FinalizeL1DepositParams({
            chainId: ERA_CHAIN_ID,
            l2BatchNumber: _l2BatchNumber,
            l2MessageIndex: _l2MessageIndex,
            l2Sender: L1_NULLIFIER.l2BridgeAddress(ERA_CHAIN_ID),
            l2TxNumberInBatch: _l2TxNumberInBatch,
            message: _message,
            merkleProof: _merkleProof
        });
        L1_NULLIFIER.finalizeDeposit(finalizeWithdrawalParams);
    }

    /*//////////////////////////////////////////////////////////////
                            ERA LEGACY GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the L2 token address for a given L1 token using CREATE2.
    /// @param _l1Token The L1 token address to calculate the L2 counterpart for.
    /// @return The L2 token address that would be minted for deposit of the given L1 token on ZKsync Era.
    function l2TokenAddress(address _l1Token) external view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(l2TokenBeacon, ""));
        bytes32 salt = bytes32(uint256(uint160(_l1Token)));
        return L2ContractHelper.computeCreate2Address(l2Bridge, salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }
}
