// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCallStarter} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {L1InteropCenter} from "contracts/interop/L1InteropCenter.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {LogFinder} from "test-utils/LogFinder.sol";

/// @notice Deploys an ecosystem with two chains and a token, and sends one-way bundles from its L1.
/// See {protocol-docs/interop.md#one-way-bundles-from-an-l1}.
abstract contract OneWayBundlesDeployer is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using LogFinder for Vm.Log[];

    /// @dev What the L1 interop center emitted for one sent bundle.
    struct SentBundle {
        bytes32 bundleHash;
        /// The ABI-encoded bundle, as the destination's interop handler takes it.
        bytes encodedBundle;
        InteropBundle bundle;
        /// The batch of L1's own slot in the message root that holds the bundle's message.
        uint256 batchNumber;
    }

    L1InteropCenter internal l1InteropCenter;
    L1MessageRoot internal messageRoot;

    /// @dev The destination chain of the bundles and its diamond.
    uint256 internal chainId;
    address internal zkChain;

    TestnetERC20Token internal token;
    bytes32 internal assetId;

    address internal user = makeAddr("user");
    address internal l2Receiver = makeAddr("l2Receiver");

    function _deployOneWayBundlesEcosystem() internal {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);
        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);

        chainId = zkChainIds[1];
        zkChain = getZKChainAddress(chainId);
        messageRoot = L1MessageRoot(address(ecosystemAddresses.bridgehub.proxies.messageRoot));
        l1InteropCenter = L1InteropCenter(addresses.sharedBridge.l1InteropCenter());
        vm.prank(IOwnable(address(l1InteropCenter)).pendingOwner());
        IOwnable(address(l1InteropCenter)).acceptOwnership();

        token = TestnetERC20Token(tokens[0]);
        assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
    }

    function _enableDestination(uint256 _chainId) internal {
        vm.prank(l1InteropCenter.owner());
        l1InteropCenter.setDestinationEnabled(_chainId, true);
    }

    /// @notice The destination argument of `sendBundle`.
    function _destination(uint256 _chainId) internal pure returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(_chainId);
    }

    /// @notice The call starters of a transfer of `_amount` of `_token` to `_receiver` on the destination.
    function _transferStarters(
        address _token,
        uint256 _amount,
        address _receiver
    ) internal view returns (InteropCallStarter[] memory starters) {
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        starters = new InteropCallStarter[](1);
        starters[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(addresses.sharedBridge)),
            data: DataEncoding.encodeAssetRouterBridgehubDepositData(
                DataEncoding.encodeNTVAssetId(block.chainid, _token),
                DataEncoding.encodeBridgeBurnData(_amount, _receiver, _token)
            ),
            callAttributes: callAttributes
        });
    }

    function _saltAttribute(bytes32 _salt) internal pure returns (bytes[] memory attributes) {
        attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
    }

    /// @notice Mints `_amount` of the token to the user and sends it to `l2Receiver` on the destination chain.
    function _sendTransfer(uint256 _amount, bytes32 _salt) internal returns (SentBundle memory sent) {
        token.mint(user, _amount);
        vm.prank(user);
        token.approve(address(addresses.l1NativeTokenVault), _amount);

        vm.recordLogs();
        vm.prank(user);
        sent.bundleHash = l1InteropCenter.sendBundle(
            _destination(chainId),
            _transferStarters(address(token), _amount, l2Receiver),
            _saltAttribute(_salt)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory bundleLog = logs.requireOneFrom(
            "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes,bool,bytes32)))",
            address(l1InteropCenter)
        );
        bytes32 messageHash;
        bytes32 emittedBundleHash;
        (messageHash, emittedBundleHash, sent.bundle) = abi.decode(bundleLog.data, (bytes32, bytes32, InteropBundle));
        sent.encodedBundle = abi.encode(sent.bundle);
        assertEq(emittedBundleHash, sent.bundleHash, "the event carries the returned bundle hash");
        assertEq(keccak256(sent.encodedBundle), sent.bundleHash, "the bundle hashes to the bundle hash");
        assertEq(
            messageHash,
            keccak256(bytes.concat(BUNDLE_IDENTIFIER, sent.encodedBundle)),
            "the message is the prefixed bundle"
        );

        Vm.Log memory sentLog = logs.requireOneFrom(
            "OneWayBundleSent(bytes32,uint256,uint256)",
            address(l1InteropCenter)
        );
        assertEq(sentLog.topics[1], sent.bundleHash);
        assertEq(uint256(sentLog.topics[2]), chainId);
        sent.batchNumber = abi.decode(sentLog.data, (uint256));
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
