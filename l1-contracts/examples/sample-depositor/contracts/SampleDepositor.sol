// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IBridgehubBase.sol";

/// @title SampleDepositor
/// @notice Example L1 contract that holds an ERC20 and bridges it to a contract on a ZK chain (e.g. a
/// `SampleWithdrawer`, which can then withdraw the tokens back to L1).
/// @dev The deposit is `Bridgehub.requestL2TransactionTwoBridges` with the L1AssetRouter as the second bridge:
/// the L1NativeTokenVault pulls the tokens from this contract, and the L2 priority transaction mints the bridged
/// token to `_l2Receiver`. Only destination chains whose base token is ETH are supported, because the L2 gas
/// (`mintValue`) is paid with the ETH sent along with the call.
/// See {protocol-docs/bridging.md#deposit-initiation-source-side}.
contract SampleDepositor is Ownable {
    using SafeERC20 for IERC20;

    /// @notice The L1 Bridgehub of the ecosystem the tokens are bridged into.
    IL1Bridgehub public immutable BRIDGEHUB;

    /// @notice The ERC20 this contract holds and bridges.
    IERC20 public immutable TOKEN;

    /// @notice Emitted once a deposit has been requested on L1.
    /// @param chainId The destination chain.
    /// @param l2Receiver The address credited with the bridged token on the destination chain.
    /// @param amount The bridged amount.
    /// @param canonicalTxHash The hash of the L1 -> L2 priority transaction that finalizes the deposit.
    event BridgedToL2(uint256 indexed chainId, address indexed l2Receiver, uint256 amount, bytes32 canonicalTxHash);

    /// @notice The destination chain's base token is not ETH, so the L2 gas cannot be paid with `msg.value`.
    error OnlyEthBaseTokenChains(uint256 chainId);

    constructor(IL1Bridgehub _bridgehub, IERC20 _token) {
        BRIDGEHUB = _bridgehub;
        TOKEN = _token;
    }

    /// @notice Bridges `_amount` of `TOKEN` held by this contract to `_l2Receiver` on chain `_chainId`.
    /// @dev `msg.value` becomes the deposit's `mintValue`. It must cover
    /// `BRIDGEHUB.l2TransactionBaseCost(_chainId, tx.gasprice, _l2GasLimit, _l2GasPerPubdataByteLimit)`; the surplus
    /// is refunded as ETH to `_refundRecipient` on the destination chain.
    /// @param _chainId The destination chain id.
    /// @param _l2Receiver The address credited with the bridged token on the destination chain.
    /// @param _amount The amount of `TOKEN` to bridge.
    /// @param _l2GasLimit The gas limit of the L2 transaction that finalizes the deposit.
    /// @param _l2GasPerPubdataByteLimit The maximum L2 gas per pubdata byte the L2 transaction may pay.
    /// @param _refundRecipient The L2 address receiving the ETH surplus (and the tokens, should the L2 transaction
    /// fail); defaults to the caller. Pass an EOA: a contract address gets aliased on L2.
    /// @return canonicalTxHash The hash of the resulting L1 -> L2 priority transaction.
    function bridgeTo(
        uint256 _chainId,
        address _l2Receiver,
        uint256 _amount,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        address _refundRecipient
    ) external payable onlyOwner returns (bytes32 canonicalTxHash) {
        IL1AssetRouter assetRouter = IL1AssetRouter(address(BRIDGEHUB.assetRouter()));
        if (BRIDGEHUB.baseTokenAssetId(_chainId) != assetRouter.ETH_TOKEN_ASSET_ID()) {
            revert OnlyEthBaseTokenChains(_chainId);
        }

        canonicalTxHash = BRIDGEHUB.requestL2TransactionTwoBridges{value: msg.value}(
            L2TransactionRequestTwoBridgesOuter({
                chainId: _chainId,
                mintValue: msg.value,
                l2Value: 0,
                l2GasLimit: _l2GasLimit,
                l2GasPerPubdataByteLimit: _l2GasPerPubdataByteLimit,
                refundRecipient: _refundRecipient == address(0) ? msg.sender : _refundRecipient,
                secondBridgeAddress: address(assetRouter),
                secondBridgeValue: 0,
                secondBridgeCalldata: _prepareDeposit(assetRouter.nativeTokenVault(), _l2Receiver, _amount)
            })
        );

        emit BridgedToL2(_chainId, _l2Receiver, _amount, canonicalTxHash);
    }

    /// @dev Registers `TOKEN` with the vault if needed, lets the vault pull `_amount` from this contract while the
    /// deposit is processed, and returns the L1AssetRouter deposit calldata.
    function _prepareDeposit(
        INativeTokenVaultBase _nativeTokenVault,
        address _l2Receiver,
        uint256 _amount
    ) internal returns (bytes memory secondBridgeCalldata) {
        bytes32 assetId = _nativeTokenVault.ensureTokenIsRegistered(address(TOKEN));
        TOKEN.forceApprove(address(_nativeTokenVault), _amount);
        secondBridgeCalldata = DataEncoding.encodeAssetRouterBridgehubDepositData(
            assetId,
            DataEncoding.encodeBridgeBurnData(_amount, _l2Receiver, address(TOKEN))
        );
    }

    /// @notice Moves `_amount` of `TOKEN` out of this contract without bridging (e.g. to recover funds).
    /// @param _to The recipient.
    /// @param _amount The amount to transfer.
    function withdrawToken(address _to, uint256 _amount) external onlyOwner {
        TOKEN.safeTransfer(_to, _amount);
    }
}
