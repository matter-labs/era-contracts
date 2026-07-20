// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_ROUTER,
    L2_BRIDGEHUB,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_CENTER,
    L2_NATIVE_TOKEN_VAULT,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
// import {IInteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {AmountMustBeGreaterThanZero, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {ArgumentsLengthNotIdentical} from "./utils/ZkSyncScriptErrors.sol";

library InteropLibrary {
    /*//////////////////////////////////////////////////////////////
                               BUILDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Build the “second bridge” calldata. Check DataEncoding library for details.
    function buildSecondBridgeCalldata(
        bytes32 l2TokenAssetId,
        uint256 amount,
        address receiver,
        address maybeTokenAddress
    ) internal pure returns (bytes memory) {
        bytes memory inner = DataEncoding.encodeBridgeBurnData(amount, receiver, maybeTokenAddress);
        return DataEncoding.encodeAssetRouterBridgehubDepositData(l2TokenAssetId, inner);
    }

    /// @notice Create a single Interop call to the L2 asset router with the 7786 "indirectCall" attribute set.
    function buildSecondBridgeCall(
        bytes memory secondBridgeCalldata,
        address bridgeAddress
    ) internal pure returns (InteropCallStarter memory) {
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (uint256(0)));
        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(bridgeAddress),
                data: secondBridgeCalldata,
                callAttributes: callAttributes
            });
    }

    /// @notice Build a single InteropCallStarter with provided attributes for sending a call.
    /// @param salt User salt for `interopBundleSalt`; see {buildBundleAttributes}.
    function buildCall(
        uint256 destinationChainId,
        address target,
        address executionAddress,
        address unbundlerAddress,
        bytes memory data,
        bytes32 salt
    ) internal pure returns (InteropCallStarter memory, bytes[] memory) {
        bytes[] memory callAttributes = buildCallAttributes(false);
        bytes[] memory bundleAttributes = buildBundleAttributes(executionAddress, unbundlerAddress, false, salt);

        return (
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(destinationChainId, target),
                data: data,
                callAttributes: callAttributes
            }),
            bundleAttributes
        );
    }

    /// @notice Build a single InteropCallStarter with provided attributes for sending a bundle of calls.
    function buildBundleCall(address target, bytes memory data) internal pure returns (InteropCallStarter memory) {
        bytes[] memory callAttributes = buildCallAttributes(true);

        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(target),
                data: data,
                callAttributes: callAttributes
            });
    }

    /// @notice Build a single InteropCallStarter with provided attributes for sending native tokens.
    function buildSendDestinationChainBaseTokenCall(
        uint256 destination,
        address recipient,
        uint256 amount
    ) internal view returns (InteropCallStarter memory call) {
        bytes32 destinationBaseTokenAssetId = L2_BRIDGEHUB.baseTokenAssetId(destination);
        bytes32 thisChainBaseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        bool indirectCall = destinationBaseTokenAssetId != thisChainBaseTokenAssetId;

        uint256 attributesLength = indirectCall ? 2 : 1;
        bytes[] memory callAttributes = new bytes[](attributesLength);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (indirectCall ? 0 : amount));
        if (indirectCall) {
            callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (amount));
        }
        bytes memory empty = hex"";

        address destinationAddress = indirectCall ? L2_ASSET_ROUTER_ADDR : recipient;

        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(destinationAddress),
                data: indirectCall
                    ? buildSecondBridgeCalldata(thisChainBaseTokenAssetId, amount, recipient, address(0))
                    : empty,
                callAttributes: callAttributes
            });
    }

    /// @notice Build bundle attributes with execution address, unbundler address, fee type, and a salt.
    /// @param executionAddress     Optional executor (EOA/contract) on destination chain
    /// @param unbundlerAddress     Unbundler address on destination chain
    /// @param useFixedFee          Whether to use fixed ZK token fees (true) or dynamic base token fees (false)
    /// @param salt                 User salt for `interopBundleSalt`: must be unique per sender, random recommended;
    ///                             see {protocol-docs/interop.md}. `bytes32(0)` omits the attribute (usable at most
    ///                             once per sender). Deliberately no salt-less overload — callers must choose a salt.
    function buildBundleAttributes(
        address executionAddress,
        address unbundlerAddress,
        bool useFixedFee,
        bytes32 salt
    ) internal pure returns (bytes[] memory) {
        uint256 length = 1; // Always include useFixedFee
        if (executionAddress != address(0)) ++length;
        if (unbundlerAddress != address(0)) ++length;
        if (salt != bytes32(0)) ++length;
        bytes[] memory attributes = new bytes[](length);
        uint attributesPointer = 0;
        if (executionAddress != address(0)) {
            attributes[attributesPointer++] = abi.encodeCall(
                IERC7786Attributes.executionAddress,
                (InteroperableAddress.formatEvmV1(executionAddress))
            );
        }
        if (unbundlerAddress != address(0)) {
            attributes[attributesPointer++] = abi.encodeCall(
                IERC7786Attributes.unbundlerAddress,
                (InteroperableAddress.formatEvmV1(unbundlerAddress))
            );
        }
        attributes[attributesPointer++] = abi.encodeCall(IERC7786Attributes.useFixedFee, (useFixedFee));
        if (salt != bytes32(0)) {
            attributes[attributesPointer++] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (salt));
        }
        return attributes;
    }

    /// @notice Appends an `interopBundleSalt` attribute to an existing bundle attributes array.
    /// @dev Prefer passing the salt directly to {buildBundleAttributes}/the senders; useful when one base
    ///      attributes array is reused for several bundles, each needing a distinct salt.
    function withInteropBundleSalt(
        bytes[] memory _attributes,
        bytes32 _salt
    ) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](_attributes.length + 1);
        for (uint256 i = 0; i < _attributes.length; ++i) {
            attrs[i] = _attributes[i];
        }
        attrs[_attributes.length] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
    }

    /// @notice Build a call-level 7786 attributes array.
    function buildCallAttributes(bool indirectCall) internal pure returns (bytes[] memory) {
        uint256 length;
        if (indirectCall) ++length;
        bytes[] memory attributes = new bytes[](length);
        uint attributesPointer = 0;
        if (indirectCall) {
            attributes[attributesPointer++] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        }
        return attributes;
    }

    /*//////////////////////////////////////////////////////////////
                           ONE-SHOT SENDER
    //////////////////////////////////////////////////////////////*/

    /// @notice Build and send a token transfer bundle.
    /// @param  destinationChainId  Destination chain id (e.g., 271 for zkSync Era testnet), later wrapped via InteroperableAddress.formatEvmV1.
    /// @param  l2TokenAddress      Address of token on L2
    /// @param  amount              Amount to transfer
    /// @param  recipient           Recipient on destination chain
    /// @param  unbundlerAddress     Address authorized to unbundle and execute the bundle on the  destination chain.
    /// @param  useFixedFee         Whether to use fixed ZK token fees (true) or dynamic base token fees (false)
    /// @param  salt                User salt for `interopBundleSalt`; see {buildBundleAttributes}.
    /// @return bundleHash Hash of the sent bundle
    function sendToken(
        uint256 destinationChainId,
        address l2TokenAddress,
        uint256 amount,
        address recipient,
        address unbundlerAddress,
        bool useFixedFee,
        bytes32 salt
    ) internal returns (bytes32 bundleHash) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        if (l2TokenAddress == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }

        bytes32 l2TokenAssetId = L2_NATIVE_TOKEN_VAULT.assetId(l2TokenAddress);
        bytes memory secondBridgeCalldata = buildSecondBridgeCalldata(
            l2TokenAssetId,
            amount,
            recipient,
            address(0) // maybeTokenAddress
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = buildSecondBridgeCall(secondBridgeCalldata, L2_ASSET_ROUTER_ADDR); // Using the default address as second bridge.

        bytes[] memory bundleAttrs = buildBundleAttributes(address(0), unbundlerAddress, useFixedFee, salt);

        return L2_INTEROP_CENTER.sendBundle(InteroperableAddress.formatEvmV1(destinationChainId), calls, bundleAttrs);
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWALS (L2 -> L1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Build the single-attribute (`interopBundleSalt`) bundle-attribute array used by L2->L1
    /// withdrawal bundles.
    /// @dev Each (sender, salt) pair may be used only once by the InteropCenter, so callers derive the salt
    /// deterministically from the withdrawal content.
    /// @param _salt Salt mixed into the bundle's `interopBundleSalt`.
    function buildWithdrawalBundleAttributes(bytes32 _salt) internal pure returns (bytes[] memory attributes) {
        attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
    }

    /// @notice ABI-encode the `InteropCenter.sendBundle` calldata for an L2->L1 withdrawal of a single
    /// registered (non-base-token) asset. Used where the call is wrapped into an admin L1->L2 transaction /
    /// ChainAdmin multicall rather than sent directly.
    /// @param _l1ChainId Destination L1 chain id.
    /// @param _assetId The withdrawn asset id (an ERC20 or the CTM/ZK asset — NOT a base-token asset).
    /// @param _transferData Bridgehub-burn transfer data for the asset.
    /// @param _salt User salt for `interopBundleSalt`; see {buildBundleAttributes}.
    function encodeWithdrawalSendBundleCalldata(
        uint256 _l1ChainId,
        bytes32 _assetId,
        bytes memory _transferData,
        bytes32 _salt
    ) internal pure returns (bytes memory) {
        return
            abi.encodeCall(
                InteropCenter.sendBundle,
                (
                    InteroperableAddress.formatEvmV1(_l1ChainId),
                    DataEncoding.encodeInteropWithdrawalCallStarters(_assetId, _transferData),
                    buildWithdrawalBundleAttributes(_salt)
                )
            );
    }

    /// @notice Send an L2->L1 withdrawal bundle for a single registered (non-base-token) asset directly through
    /// the InteropCenter. Wrap in `vm.broadcast()` when broadcasting.
    /// @param _l1ChainId Destination L1 chain id.
    /// @param _assetId The withdrawn asset id (an ERC20 or the CTM/ZK asset — NOT a base-token asset).
    /// @param _transferData Bridgehub-burn transfer data for the asset.
    /// @param _salt User salt for `interopBundleSalt`; see {buildBundleAttributes}.
    /// @return bundleHash Hash of the sent bundle.
    function sendWithdrawal(
        uint256 _l1ChainId,
        bytes32 _assetId,
        bytes memory _transferData,
        bytes32 _salt
    ) internal returns (bytes32 bundleHash) {
        return
            L2_INTEROP_CENTER.sendBundle(
                InteroperableAddress.formatEvmV1(_l1ChainId),
                DataEncoding.encodeInteropWithdrawalCallStarters(_assetId, _transferData),
                buildWithdrawalBundleAttributes(_salt)
            );
    }

    /// @notice Build and send a bundle of interop calls.
    /// @dev
    /// - All arrays must be the same length; each index describes one call.
    /// - If an entry in `executionAddresses` is the zero address, the default executor will be used (see library policy).
    /// - `destination` is the destination chain id; it is converted to an interoperable chain identifier internally.
    /// @param destination          Destination chain id (e.g., 271 for zkSync Era testnet), later wrapped via InteroperableAddress.formatEvmV1.
    /// @param targets              Target contracts to call on the destination chain (one per call).
    /// @param dataArray            Calldata payloads for each target (one per call).
    /// @param executionAddress     Default executor used whenever a corresponding entry in `executionAddresses` is address(0).
    /// @param unbundlerAddress     Address authorized to unbundle and execute the bundle on the  destination chain.
    /// @param useFixedFee          Whether to use fixed ZK token fees (true) or dynamic base token fees (false)
    /// @param salt                 User salt for `interopBundleSalt`; see {buildBundleAttributes}.
    /// @return bundleHash Hash of the sent bundle
    function sendDirectCallBundle(
        uint256 destination,
        address[] memory targets,
        bytes[] memory dataArray,
        address executionAddress,
        address unbundlerAddress,
        bool useFixedFee,
        bytes32 salt
    ) internal returns (bytes32 bundleHash) {
        if (targets.length != dataArray.length) {
            revert ArgumentsLengthNotIdentical();
        }
        uint256 totalCalls = targets.length;
        InteropCallStarter[] memory calls = new InteropCallStarter[](totalCalls);
        for (uint256 i = 0; i < totalCalls; ++i) {
            if (targets[i] == address(0)) {
                revert ZeroAddress();
            }

            calls[i] = buildBundleCall(targets[i], dataArray[i]);
        }

        bytes[] memory bundleAttrs = buildBundleAttributes(executionAddress, unbundlerAddress, useFixedFee, salt);

        return L2_INTEROP_CENTER.sendBundle(InteroperableAddress.formatEvmV1(destination), calls, bundleAttrs);
    }

    /// @notice Build and send a call in one go.
    /// @param  destination       Destination chain id, wrapped via InteroperableAddress.formatEvmV1 internally
    /// @param  target            Address that will be called on destination chain
    /// @param  executionAddress  If necessary, custom execution address can be specified. If 0 address is passed, then default executor will be used
    /// @param  data              Data which will be passed to the target
    /// @param  salt              User salt for `interopBundleSalt`; see {buildBundleAttributes}.
    /// @return sendId Hash of the sent bundle containing a single call
    function sendDirectCall(
        uint256 destination,
        address target,
        bytes memory data,
        address executionAddress,
        address unbundlerAddress,
        bytes32 salt
    ) internal returns (bytes32 sendId) {
        if (target == address(0)) {
            revert ZeroAddress();
        }

        InteropCallStarter[] memory calls = new InteropCallStarter[](1); // merge then call and bundle attrs
        bytes[] memory bundleAttributes;
        (calls[0], bundleAttributes) = buildCall({
            destinationChainId: destination,
            target: target,
            executionAddress: executionAddress,
            unbundlerAddress: unbundlerAddress,
            data: data,
            salt: salt
        });

        bytes[] memory mergedAttributes = _concatBytesArrays(calls[0].callAttributes, bundleAttributes);

        return
            IERC7786GatewaySource(address(L2_INTEROP_CENTER)).sendMessage(calls[0].to, calls[0].data, mergedAttributes);
    }

    /// @notice Build and send a call to receive native tokens on remote chain.
    /// @param  destinationChainId      The normal chain id of the destination chain
    /// @param  recipient               Address that will receive the tokens on remote chain
    /// @param  unbundlerAddress        Address authorized to unbundle and execute the bundle on the  destination chain.
    /// @param  amount                  Amount to transfer
    /// @param  useFixedFee             Whether to use fixed ZK token fees (true) or dynamic base token fees (false)
    /// @param  salt                    User salt for `interopBundleSalt`; see {buildBundleAttributes}.
    /// @return bundleHash Hash of the sent bundle
    function sendNative(
        uint256 destinationChainId,
        address recipient,
        address unbundlerAddress,
        uint256 amount,
        bool useFixedFee,
        bytes32 salt
    ) internal returns (bytes32 bundleHash) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = buildSendDestinationChainBaseTokenCall(destinationChainId, recipient, amount);
        bytes[] memory bundleAttributes = buildBundleAttributes(address(0), unbundlerAddress, useFixedFee, salt);

        return
            L2_INTEROP_CENTER.sendBundle{value: amount}(
                InteroperableAddress.formatEvmV1(destinationChainId),
                calls,
                bundleAttributes
            );
    }

    /// @notice Send message to L1 using the system contract.
    /// @param message Data to be sent to L1.
    /// @return hash (keccak256) of the sent message.
    function sendMessage(bytes memory message) internal returns (bytes32 hash) {
        return L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(message);
    }

    function _concatBytesArrays(bytes[] memory a, bytes[] memory b) internal pure returns (bytes[] memory result) {
        result = new bytes[](a.length + b.length);

        uint256 idx = 0;

        // copy first array
        for (uint256 i = 0; i < a.length; i++) {
            result[idx] = a[i];
            idx++;
        }

        // copy second array
        for (uint256 i = 0; i < b.length; i++) {
            result[idx] = b[i];
            idx++;
        }
    }
}
