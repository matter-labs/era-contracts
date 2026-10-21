// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {ChainRegistrationSender} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadMockUtils} from "./L1SloadMockUtils.sol";

/// @notice Shared fixture for the L1SLOAD tests: the real L1 `L1MessageRoot` and `ChainRegistrationSender` behind
/// proxies, the real L2 `L2InteropRootStorage` at its built-in address, and the mock L1SLOAD precompile
/// ({L1SloadMockUtils}). The Bridgehub, the vault and the chains' diamonds are mocked to isolate the gating state
/// from chain creation; the `ChainRegistrationSender` state is written through its real entry points.
/// @dev Reads are pinned to the anchor, as on a chain: each anchor import serves the gating slots of the fixture's
/// chains as L1 holds them at that moment ({_importL1Anchor}), and once an anchor exists every L1 helper below
/// imports the next one, standing for the anchor the chain imports after the L1 change. A test that changes L1
/// through the contracts directly sees the change on L2 only after it imports a newer anchor.
/// See {protocol-docs/l1sload.md}.
abstract contract L1SloadSharedTest is Test {
    uint256 internal constant L1_CHAIN_ID = 31337;
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant PEER_CHAIN_ID = 272;
    uint256 internal constant THIRD_CHAIN_ID = 273;

    address internal bridgehub;
    address internal governance;
    L1MessageRoot internal l1MessageRoot;
    ChainRegistrationSender internal chainRegistrationSender;
    L2InteropRootStorage internal rootStorage = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

    function setUp() public virtual {
        vm.chainId(L1_CHAIN_ID);
        bridgehub = makeAddr("bridgehub");
        governance = makeAddr("governance");
        address chainAssetHandler = makeAddr("chainAssetHandler");

        vm.mockCall(bridgehub, abi.encodeCall(IOwnable.owner, ()), abi.encode(governance));
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(new uint256[](0))
        );
        l1MessageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(bridgehub, chainAssetHandler)),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
        chainRegistrationSender = ChainRegistrationSender(
            address(
                new TransparentUpgradeableProxy(
                    _chainRegistrationSenderImplementation(),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(ChainRegistrationSender.initialize, (governance))
                )
            )
        );
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.messageRoot, ()), abi.encode(address(l1MessageRoot)));
        address nativeTokenVault = makeAddr("nativeTokenVault");
        address assetRouter = makeAddr("assetRouter");
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(assetRouter));
        vm.mockCall(assetRouter, abi.encodeCall(IL1AssetRouter.nativeTokenVault, ()), abi.encode(nativeTokenVault));
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(IL1NativeTokenVault.chainBalanceBackfillPending.selector),
            abi.encode(false)
        );

        _registerChain(CHAIN_ID);
        _registerChain(PEER_CHAIN_ID);
        _registerChain(THIRD_CHAIN_ID);

        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
        L1SloadMockUtils.installMock();
    }

    /// @dev The implementation the `ChainRegistrationSender` proxy starts with.
    function _chainRegistrationSenderImplementation() internal virtual returns (address) {
        return address(new ChainRegistrationSender(IBridgehubBase(bridgehub)));
    }

    /// @dev A chain registered on L1 with a settled batch in the message root, as `allowInteropPeer` requires.
    function _registerChain(uint256 _chainId) internal {
        address diamond = makeAddr(string.concat("diamond", vm.toString(_chainId)));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (_chainId)), abi.encode(diamond));
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (_chainId)),
            abi.encode(_baseTokenAssetId(_chainId))
        );
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.settlementLayer, (_chainId)), abi.encode(L1_CHAIN_ID));
        vm.mockCall(diamond, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(_chainAdmin(_chainId)));
        vm.mockCall(diamond, abi.encodeCall(IGetters.isZKsyncOSL1SloadEnabled, ()), abi.encode(true));

        vm.prank(bridgehub);
        l1MessageRoot.addNewChain(_chainId, 0);
        vm.prank(diamond);
        l1MessageRoot.addChainBatchRootV32(_chainId, 1, keccak256(abi.encode("batchRoot", _chainId)));
    }

    function _chainAdmin(uint256 _chainId) internal returns (address) {
        return makeAddr(string.concat("admin", vm.toString(_chainId)));
    }

    function _baseTokenAssetId(uint256 _chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode("baseToken", _chainId));
    }

    function _enableInterop(uint256 _chainId) internal {
        vm.prank(governance);
        l1MessageRoot.enableInterop(_chainId, false);
    }

    function _suspendInterop(uint256 _chainId) internal {
        vm.prank(governance);
        chainRegistrationSender.suspendInterop(_chainId);
        _followL1();
    }

    function _resumeInterop(uint256 _chainId) internal {
        vm.prank(governance);
        chainRegistrationSender.resumeInterop(_chainId);
        _followL1();
    }

    /// @dev `_chainId`'s admin allows `_peerChainId` on L1 (one side of the pair).
    function _allowInteropPeer(uint256 _chainId, uint256 _peerChainId) internal {
        vm.prank(_chainAdmin(_chainId));
        chainRegistrationSender.allowInteropPeer(_chainId, _peerChainId);
        _followL1();
    }

    /// @dev Enables both chains if needed, and each admin allows the other.
    function _allowBothWays(uint256 _chainId, uint256 _peerChainId) internal {
        if (!l1MessageRoot.isInteropEnabled(_chainId)) {
            _enableInterop(_chainId);
        }
        if (!l1MessageRoot.isInteropEnabled(_peerChainId)) {
            _enableInterop(_peerChainId);
        }
        _allowInteropPeer(_chainId, _peerChainId);
        _allowInteropPeer(_peerChainId, _chainId);
    }

    function _deregisterInteropPeer(uint256 _chainId, uint256 _peerChainId) internal {
        uint256[] memory peers = new uint256[](1);
        peers[0] = _peerChainId;
        vm.prank(_chainAdmin(_chainId));
        chainRegistrationSender.deregisterInteropPairs(_chainId, peers);
        _followL1();
    }

    function _anchorRoot(
        uint256 _blockNumber,
        bytes32 _blockHash,
        uint256 _timestamp
    ) internal pure returns (InteropRoot memory) {
        return L1SloadMockUtils.anchorRoot(_blockNumber, _blockHash, _timestamp);
    }

    /// @dev Imports an L1 block-hash anchor the way the bootloader does, and serves the fixture's gating slots as L1
    /// holds them now.
    function _importL1Anchor(uint256 _blockNumber, bytes32 _blockHash, uint256 _timestamp) internal {
        L1SloadMockUtils.importAnchor(_blockNumber, _blockHash, _timestamp);
        L1SloadMockUtils.syncFromL1(address(chainRegistrationSender), _gatingSlots());
    }

    /// @dev Imports the anchor after the current one.
    function _importNextL1Anchor() internal {
        uint256 blockNumber = rootStorage.l1AnchorBlockNumber() + 1;
        _importL1Anchor(blockNumber, keccak256(abi.encode("l1 block", blockNumber)), block.timestamp);
    }

    /// @dev A chain that already reads L1 imports a newer anchor after an L1 change.
    function _followL1() internal {
        if (rootStorage.l1AnchorBlockHash() != bytes32(0)) {
            _importNextL1Anchor();
        }
    }

    /// @dev Every `ChainRegistrationSender` slot the L2 reads for the fixture's chains, plus {_extraSyncedSlots}.
    function _gatingSlots() internal view returns (bytes32[] memory slots) {
        uint256[3] memory chains = [CHAIN_ID, PEER_CHAIN_ID, THIRD_CHAIN_ID];
        bytes32[] memory extra = _extraSyncedSlots();
        slots = new bytes32[](12 + extra.length);
        uint256 n = 0;
        for (uint256 i = 0; i < chains.length; ++i) {
            slots[n++] = L1View.interopSuspendedSlot(chains[i]);
            slots[n++] = L1View.interopBaseTokenAssetIdSlot(chains[i]);
            for (uint256 j = 0; j < chains.length; ++j) {
                if (i != j) {
                    slots[n++] = L1View.interopPeerAllowedSlot(chains[i], chains[j]);
                }
            }
        }
        for (uint256 i = 0; i < extra.length; ++i) {
            slots[n++] = extra[i];
        }
    }

    /// @dev Further `ChainRegistrationSender` slots a suite reads.
    function _extraSyncedSlots() internal view virtual returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    /// @dev L2 contracts read their own chain id from `block.chainid`; the L1 contracts in this fixture run on
    /// `L1_CHAIN_ID`.
    function _onL2() internal {
        vm.chainId(CHAIN_ID);
    }

    function _onL1() internal {
        vm.chainId(L1_CHAIN_ID);
    }
}
