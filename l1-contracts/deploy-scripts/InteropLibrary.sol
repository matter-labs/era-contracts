// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_ROUTER,
    L2_BRIDGEHUB,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_CENTER,
    L2_NATIVE_TOKEN_VAULT,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
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
    function buildCall(
        uint256 destinationChainId,
        address target,
        address executionAddress,
        address unbundlerAddress,
        bytes memory data
    ) internal pure returns (InteropCallStarter memory, bytes[] memory) {
        bytes[] memory callAttributes = buildCallAttributes(false);
        bytes[] memory bundleAttributes = buildBundleAttributes(executionAddress, unbundlerAddress);

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

    /// @notice Bundle-level attributes.
    function buildBundleAttributes(address unbundlerAddress) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(unbundlerAddress))
        );
    }

    /// @notice Build a call-level 7786 attributes array.
    /// @param executionAddress     Optional executor (EOA/contract) on destination chain
    function buildBundleAttributes(
        address executionAddress,
        address unbundlerAddress
    ) internal pure returns (bytes[] memory) {
        uint256 length;
        if (executionAddress != address(0)) ++length;
        if (unbundlerAddress != address(0)) ++length;
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
        return attributes;
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

    /// @notice Build and send a token transfer bundle in one go.
    /// @param  destinationChainId  Destination chain id (e.g., 271 for zkSync Era testnet), later wrapped via InteroperableAddress.formatEvmV1.
    /// @param  l2TokenAddress      Address of token on L2
    /// @param  amount              Amount to transfer
    /// @param  recipient           Recipient on destination chain
    /// @param  unbundlerAddress     Address authorized to unbundle and execute the bundle on the  destination chain.
    /// @return bundleHash Hash of the sent bundle
    function sendToken(
        uint256 destinationChainId,
        address l2TokenAddress,
        uint256 amount,
        address recipient,
        address unbundlerAddress
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

        bytes[] memory bundleAttrs = buildBundleAttributes(unbundlerAddress);

        return L2_INTEROP_CENTER.sendBundle(InteroperableAddress.formatEvmV1(destinationChainId), calls, bundleAttrs);
    }

    /// @notice Build and send a bundle of interop calls in one go.
    /// @dev
    /// - All arrays must be the same length; each index describes one call.
    /// - If an entry in `executionAddresses` is the zero address, the default executor will be used (see library policy).
    /// - `destination` is the destination chain id; it is converted to an interoperable chain identifier internally.
    /// @param destination          Destination chain id (e.g., 271 for zkSync Era testnet), later wrapped via InteroperableAddress.formatEvmV1.
    /// @param targets              Target contracts to call on the destination chain (one per call).
    /// @param dataArray            Calldata payloads for each target (one per call).
    /// @param executionAddress     Default executor used whenever a corresponding entry in `executionAddresses` is address(0).
    /// @param unbundlerAddress     Address authorized to unbundle and execute the bundle on the  destination chain.
    /// @return bundleHash Hash of the sent bundle
    function sendDirectCallBundle(
        uint256 destination,
        address[] memory targets,
        bytes[] memory dataArray,
        address executionAddress,
        address unbundlerAddress
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

        bytes[] memory bundleAttrs = buildBundleAttributes(executionAddress, unbundlerAddress);

        return L2_INTEROP_CENTER.sendBundle(InteroperableAddress.formatEvmV1(destination), calls, bundleAttrs);
    }

    /// @notice Build and send a call in one go.
    /// @param  destination       Interoperable chain identifier (e.g., InteroperableAddress.formatEvmV1(271))
    /// @param  target            Address that will be called on destination chain
    /// @param  executionAddress  If necessary, custom execution address can be specified. If 0 address is passed, then default executor will be used
    /// @param  data              Data which will be passed to the target
    /// @return sendId Hash of the sent bundle containing a single call
    function sendDirectCall(
        uint256 destination,
        address target,
        bytes memory data,
        address executionAddress,
        address unbundlerAddress
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
            data: data
        });

        bytes[] memory mergedAttributes = _concatBytesArrays(calls[0].callAttributes, bundleAttributes);

        return
            IERC7786GatewaySource(address(L2_INTEROP_CENTER)).sendMessage(calls[0].to, calls[0].data, mergedAttributes);
    }

    /// @notice Build and send a call to receive native tokens on remote chain in one go.
    /// @param  destinationChainId      The normal chain id of the destination chain
    /// @param  recipient               Address that will receive the tokens on remote chain
    /// @param  unbundlerAddress        Address authorized to unbundle and execute the bundle on the  destination chain.
    /// @param  amount                  Amount to transfer
    /// @return bundleHash Hash of the sent bundle
    function sendNative(
        uint256 destinationChainId,
        address recipient,
        address unbundlerAddress,
        uint256 amount
    ) internal returns (bytes32 bundleHash) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = buildSendDestinationChainBaseTokenCall(destinationChainId, recipient, amount);
        bytes[] memory bundleAttributes = buildBundleAttributes(unbundlerAddress);

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
