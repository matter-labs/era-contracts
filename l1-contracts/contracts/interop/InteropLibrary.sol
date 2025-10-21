// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2_ASSET_ROUTER_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
// import {IInteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "@openzeppelin/contracts-master/utils/draft-InteroperableAddress.sol";
import {AmountMustBeGreaterThanZero, ArgumentsLengthNotIdentical, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

library InteropLibrary {
    address internal constant UNBUNDLER_ADDRESS = address(0x1);
    address internal constant EXECUTION_ADDRESS = address(0x2);

    IL2NativeTokenVault internal constant l2NativeTokenVault = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
    InteropCenter internal constant l2InteropCenter = InteropCenter(L2_INTEROP_CENTER_ADDR);

    /*//////////////////////////////////////////////////////////////
                               BUILDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Build the “second bridge” calldata:
    ///         bytes.concat(NEW_ENCODING_VERSION, abi.encode(l2TokenAssetId, abi.encode(amount, receiver, fee)))
    function buildSecondBridgeCalldata(
        bytes32 l2TokenAssetId,
        uint256 amount,
        address receiver,
        uint256 fee
    ) internal pure returns (bytes memory) {
        // Inner payload: abi.encode(amount, receiver, fee)
        bytes memory inner = abi.encode(amount, receiver, fee);
        // Outer: abi.encode(l2TokenAssetId, inner), prefixed by version byte
        return bytes.concat(NEW_ENCODING_VERSION, abi.encode(l2TokenAssetId, inner));
    }

    /// @notice Create a single Interop call to the L2 asset router with the 7786 "indirectCall" attribute set.
    function buildSecondBridgeCall(
        bytes memory secondBridgeCalldata
    ) internal pure returns (InteropCallStarter memory) {
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (uint256(0)));
        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
                data: secondBridgeCalldata,
                callAttributes: callAttributes
            });
    }

    /// @notice Build a single InteropCallStarter with provided attributes for sending a call.
    function buildSendCall(
        uint256 destinationChainId,
        address target,
        address executionAddress,
        bytes memory data
    ) internal pure returns (InteropCallStarter memory) {
        bytes[] memory callAttributes = buildCallAttributes(executionAddress);

        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(destinationChainId, target),
                data: data,
                callAttributes: callAttributes
            });
    }

    /// @notice Build a single InteropCallStarter with provided attributes for sending a bundle of calls.
    function buildBundleCall(
        address target,
        address executionAddress,
        bytes memory data
    ) internal pure returns (InteropCallStarter memory) {
        bytes[] memory callAttributes = buildCallAttributes(executionAddress);

        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(target),
                data: data,
                callAttributes: callAttributes
            });
    }

    /// @notice Build a single InteropCallStarter with provided attributes for sending native tokens.
    function buildSendNativeCall(
        address recipient,
        uint256 amount
    ) internal pure returns (InteropCallStarter memory call) {
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (amount));

        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(recipient),
                data: hex"",
                callAttributes: callAttributes
            });
    }

    /// @notice Bundle-level attributes.
    function buildBundleAttributes() internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
    }

    /// @notice Build a call-level 7786 attributes array.
    /// @param executionAddress   Optional executor (EOA/contract) on destination chain
    function buildCallAttributes(address executionAddress) internal pure returns (bytes[] memory attributes) {
        bytes[] memory attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        attributes[1] = abi.encodeCall(
            IERC7786Attributes.executionAddress,
            (InteroperableAddress.formatEvmV1(executionAddress))
        );
        attributes[2] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ONE-SHOT SENDER
    //////////////////////////////////////////////////////////////*/

    /// @notice Build and send a token transfer bundle in one go.
    /// @param  destination       Interoperable chain identifier (e.g., InteroperableAddress.formatEvmV1(271))
    /// @param  l2TokenAddress    Address of token on L2
    /// @param  amount            Amount to transfer
    /// @param  recipient          Recipient on destination chain
    /// @return bundleHash Hash of the sent bundle
    function sendToken(
        uint256 destination,
        address l2TokenAddress,
        uint256 amount,
        address recipient
    ) internal returns (bytes32 bundleHash) {
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        bytes memory secondBridgeCalldata = buildSecondBridgeCalldata(
            l2TokenAssetId,
            amount,
            recipient,
            0 // fee
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = buildSecondBridgeCall(secondBridgeCalldata);

        bytes[] memory bundleAttrs = buildBundleAttributes();

        return l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(destination), calls, bundleAttrs);
    }

    /// @notice Build and send a bundle of interop calls in one go.
    /// @dev
    /// - All arrays must be the same length; each index describes one call.
    /// - If an entry in `executionAddresses` is the zero address, the default executor will be used (see library policy).
    /// - `destination` is the destination chain id; it is converted to an interoperable chain identifier internally.
    /// @param destination          Destination chain id (e.g., 271 for zkSync Era testnet), later wrapped via InteroperableAddress.formatEvmV1.
    /// @param targets              Target contracts to call on the destination chain (one per call).
    /// @param executionAddresses   Optional executor addresses (one per call). Use address(0) to accept the default.
    /// @param dataArray            Calldata payloads for each target (one per call).
    /// @return bundleHash Hash of the sent bundle
    function sendBundle(
        uint256 destination,
        address[] memory targets,
        address[] memory executionAddresses,
        bytes[] memory dataArray
    ) internal returns (bytes32 bundleHash) {
        if (targets.length != executionAddresses.length || targets.length != dataArray.length) {
            revert ArgumentsLengthNotIdentical();
        }
        uint256 totalCalls = targets.length;
        InteropCallStarter[] memory calls = new InteropCallStarter[](totalCalls);
        for (uint256 i = 0; i < totalCalls; ++i) {
            if (targets[i] == address(0)) {
                revert ZeroAddress();
            }

            if (executionAddresses[i] == address(0)) {
                executionAddresses[i] = EXECUTION_ADDRESS;
            }

            calls[i] = buildBundleCall(targets[i], executionAddresses[i], dataArray[i]);
        }

        bytes[] memory bundleAttrs = buildBundleAttributes();

        return l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(destination), calls, bundleAttrs);
    }

    /// @notice Build and send a call in one go.
    /// @param  destination       Interoperable chain identifier (e.g., InteroperableAddress.formatEvmV1(271))
    /// @param  target            Address that will be called on destination chain
    /// @param  executionAddress  If necessary, custom execution address can be specified. If 0 address is passed, then default executor will be used
    /// @param  data              Data which will be passed to the target
    /// @return sendId Hash of the sent bundle containing a single call
    function sendCall(
        uint256 destination,
        address target,
        address executionAddress,
        bytes memory data
    ) internal returns (bytes32 sendId) {
        if (target == address(0)) {
            revert ZeroAddress();
        }

        if (executionAddress == address(0)) {
            executionAddress = EXECUTION_ADDRESS;
        }

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = buildSendCall(destination, target, executionAddress, data);

        return l2InteropCenter.sendMessage(calls[0].to, calls[0].data, calls[0].callAttributes);
    }

    /// @notice Build and send a call to receive native tokens on remote chain in one go.
    /// @param  destination       Interoperable chain identifier (e.g., InteroperableAddress.formatEvmV1(271))
    /// @param  recipient         Address that will receive the tokens on remote chain
    /// @param  amount            Amount to transfer
    /// @return bundleHash Hash of the sent bundle
    function sendNative(uint256 destination, address recipient, uint256 amount) internal returns (bytes32 bundleHash) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = buildSendNativeCall(recipient, amount);
        bytes[] memory bundleAttributes = buildBundleAttributes();

        return
            l2InteropCenter.sendBundle{value: amount}(
                InteroperableAddress.formatEvmV1(destination),
                calls,
                bundleAttributes
            );
    }

    function sendMessage(bytes memory message) internal returns (bytes32 hash) {
        return L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(message);
    }
}
