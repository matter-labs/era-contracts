// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2BaseTokenBase} from "./interfaces/IL2BaseTokenBase.sol";
import {IL2NativeTokenVault} from "../bridge/ntv/IL2NativeTokenVault.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {InteropCallStarter} from "../common/Messaging.sol";
import {IERC7786Attributes} from "../interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_ASSET_ROUTER_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L2_INTEROP_CENTER} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {Unauthorized} from "../common/L1ContractErrors.sol";

/**
 * @title L2BaseTokenBase
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Abstract base contract for L2 Base Token implementations.
 * @dev This contract contains the shared withdrawal logic for both Era and ZK OS versions.
 * @dev Pre-V31 storage variables (eraAccountBalance, __DEPRECATED_totalSupply) are declared here because they existed before the V31 upgrade. The storage gap allows adding new shared variables in future upgrades.
 */
abstract contract L2BaseTokenBase is IL2BaseTokenBase {
    /// @notice Ensures that only the ComplexUpgrader can call the function.
    modifier onlyComplexUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice The balances of the users.
    /// @dev Only used by the Era implementation. Declared in the base contract because it existed prior to V31.
    mapping(address account => uint256 balance) internal eraAccountBalance;

    /// @notice Deprecated: The old storage variable for total supply.
    /// @dev Only read during the V31 upgrade to initialize the BaseTokenHolder balance correctly. After V31, totalSupply is computed dynamically from the BaseTokenHolder's balance.
    /// @dev Only used by the Era implementation. Declared in the base contract because it existed prior to V31.
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_totalSupply;

    /// @notice Whether initL2 has already been called.
    bool internal baseTokenHolderBalanceInitialized;

    /// @notice The chain ID of L1.
    uint256 public L1_CHAIN_ID;

    /// @dev Storage gap to allow adding new shared storage variables in future upgrades.
    uint256[46] private __gap;

    /// @notice Initiate the withdrawal of the base token to L1.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable override {
        uint256 amount = msg.value;
        _withdrawViaAssetRouter(_l1Receiver, amount);

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    /// @notice Initiate the withdrawal of the base token to L1.
    /// @dev Base-token withdrawals now flow through the AssetRouter/InteropCenter — the same unified path
    /// as ERC20 withdrawals. `_additionalData` is emitted for L2 observers but is not carried in the proven
    /// withdrawal (L1 finalization only consumes the receiver and amount, so this matches prior behavior).
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data emitted alongside the withdrawal event.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable override {
        uint256 amount = msg.value;
        _withdrawViaAssetRouter(_l1Receiver, amount);

        emit WithdrawalWithMessage(msg.sender, _l1Receiver, amount, _additionalData);
    }

    /// @dev Routes the base-token withdrawal through the InteropCenter as a single-call bundle destined for
    /// L1, mirroring the ERC20 withdrawal flow: an indirect call to the L2 AssetRouter carrying the
    /// base-token assetId. The AssetRouter/NTV burn the value (via BaseTokenHolder) and produce the
    /// `finalizeDeposit` message that L1 consumes, so the base token no longer builds its own message.
    /// @dev The withdrawn ETH rides as the indirect-call message value (`msg.value` is forwarded to
    /// `sendBundle`); no value is delivered to an L1 call, so `interopCallValue` is zero.
    /// @param _l1Receiver The L1 receiver address.
    /// @param _amount The amount being withdrawn (equal to `msg.value`).
    function _withdrawViaAssetRouter(address _l1Receiver, uint256 _amount) internal {
        bytes32 baseTokenAssetId = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).BASE_TOKEN_ASSET_ID();
        bytes memory depositData = DataEncoding.encodeAssetRouterBridgehubDepositData(
            baseTokenAssetId,
            DataEncoding.encodeBridgeBurnData(_amount, _l1Receiver, address(0))
        );

        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (_amount));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));

        InteropCallStarter[] memory callStarters = new InteropCallStarter[](1);
        callStarters[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: depositData,
            callAttributes: callAttributes
        });

        // slither-disable-next-line unused-return
        L2_INTEROP_CENTER.sendBundle{value: _amount}(
            InteroperableAddress.formatEvmV1(L1_CHAIN_ID),
            callStarters,
            new bytes[](0)
        );
    }
}
