// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    BundleAttributes,
    InteropBundle,
    InteropCall,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION
} from "era/common/Messaging.sol";
import {AtomicFlowPreimage, ATOMIC_COMMIT_LEAF_TAG, ATOMIC_FLOW_PREIMAGE_VERSION} from "era/atomic-interop/IAtomicInterop.sol";
import {DataEncoding} from "era/common/libraries/DataEncoding.sol";
import {InteroperableAddress} from "era/vendor/draft-InteroperableAddress.sol";
import {L2_ASSET_ROUTER_ADDR} from "era/common/l2-helpers/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS} from "era/common/Config.sol";

/// @notice Builds atomic-interop legs exactly as the L2 atomic-interop contracts do: the bundle of
/// InteropCenter._buildInteropBundle for one L2AssetRouter.initiateIndirectCall (NTV bridge-mint data with
/// BridgeHelper.getERC20Getters metadata), and the AtomicFlowPreimage / commit value of AtomicFlowManager.
library LegBuilder {
    bytes4 internal constant FINALIZE_DEPOSIT = 0x9c884fd1;

    struct Token {
        address originToken;
        uint256 originChainId;
        string name;
        string symbol;
        uint8 decimals;
    }

    struct Leg {
        uint256 sourceChainId;
        uint256 destinationChainId;
        Token token;
        uint256 amount;
        address sender;
        address receiver;
        bytes32 salt;
    }

    function assetId(Token memory _token) internal pure returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(_token.originChainId, _token.originToken);
    }

    function bundle(Leg memory _leg) internal pure returns (bytes memory) {
        bytes memory metadata = DataEncoding.encodeTokenData(
            _leg.token.originChainId,
            abi.encode(_leg.token.name),
            abi.encode(_leg.token.symbol),
            abi.encode(_leg.token.decimals)
        );
        bytes memory transferData = DataEncoding.encodeBridgeMintData(
            _leg.sender,
            _leg.receiver,
            _leg.token.originToken,
            _leg.amount,
            metadata
        );
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: L2_ASSET_ROUTER_ADDR,
            value: 0,
            data: abi.encodeWithSelector(FINALIZE_DEPOSIT, _leg.sourceChainId, assetId(_leg.token), transferData)
        });
        return
            abi.encode(
                InteropBundle({
                    version: INTEROP_BUNDLE_VERSION,
                    sourceChainId: _leg.sourceChainId,
                    destinationChainId: _leg.destinationChainId,
                    destinationBaseTokenAssetId: DataEncoding.encodeNTVAssetId(1, ETH_TOKEN_ADDRESS),
                    interopBundleSalt: keccak256(abi.encodePacked(_leg.sender, _leg.salt)),
                    calls: calls,
                    bundleAttributes: BundleAttributes({
                        executionAddress: "",
                        unbundlerAddress: InteroperableAddress.formatEvmV1(_leg.sourceChainId, _leg.sender),
                        useFixedFee: false,
                        salt: _leg.salt
                    })
                })
            );
    }

    /// @notice A two-leg flow over `_bundleA` (from `_chainA`) and `_bundleB` (from `_chainB`), hashes ascending.
    /// @return pre The abi-encoded preimage. @return legOfA Which slot holds bundle A.
    function flow(
        bytes memory _bundleA,
        uint256 _chainA,
        bytes memory _bundleB,
        uint256 _chainB,
        uint64 _deadline,
        uint256 _settlementLayer
    ) internal pure returns (bytes memory pre, uint256 legOfA) {
        bytes32 ha = keccak256(_bundleA);
        bytes32 hb = keccak256(_bundleB);
        legOfA = ha < hb ? 0 : 1;
        AtomicFlowPreimage memory p;
        p.version = ATOMIC_FLOW_PREIMAGE_VERSION;
        p.deadline = _deadline;
        p.settlementLayerChainId = _settlementLayer;
        p.legBundleHashes = new bytes32[](2);
        p.legSourceChainIds = new uint256[](2);
        p.legBundleHashes[legOfA] = ha;
        p.legBundleHashes[1 - legOfA] = hb;
        p.legSourceChainIds[legOfA] = _chainA;
        p.legSourceChainIds[1 - legOfA] = _chainB;
        pre = abi.encode(p);
    }

    /// @notice AtomicInteropProof.commitValue(keccak256(preimage), keccak256(bundle)).
    function commitValue(bytes memory _pre, bytes memory _bundle) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, keccak256(_pre), keccak256(_bundle))));
    }
}
