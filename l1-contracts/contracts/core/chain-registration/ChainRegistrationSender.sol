// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {IChainRegistrationSender} from "./IChainRegistrationSender.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IL1CrossChainSender} from "../../bridge/interfaces/IL1CrossChainSender.sol";

import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {IndirectCallRequest} from "../../common/Messaging.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";

import {L2_BRIDGEHUB_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INDIRECT_CALL_MAGIC_VALUE} from "../../common/Config.sol";

import {Unauthorized, UnsupportedEncodingVersion} from "../../common/L1ContractErrors.sol";
import {
    ChainAlreadyRegistered,
    ChainHasNoBatchesInMessageRoot,
    ChainsSettlementLayerMismatch,
    NoEthAllowed,
    ZKChainNotRegistered
} from "../bridgehub/L1BridgehubErrors.sol";
import {IL2Bridgehub} from "../bridgehub/IL2Bridgehub.sol";

/// @dev The encoding version of the data.
bytes1 constant CHAIN_REGISTRATION_SENDER_ENCODING_VERSION = 0x01;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Registers chains on other chains' L2 Bridgehubs to enable interop between them.
/// See {protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}.
contract ChainRegistrationSender is
    IChainRegistrationSender,
    IL1CrossChainSender,
    ReentrancyGuard,
    Ownable2StepUpgradeable
{
    IBridgehubBase public immutable BRIDGE_HUB;

    mapping(uint256 chainToBeRegistered => mapping(uint256 chainRegisteredOn => bool isRegistered))
        public chainRegisteredOnChain;

    /// @notice Checks that the caller is the registered L1 Interop Center.
    modifier onlyL1InteropCenter() {
        if (msg.sender != BRIDGE_HUB.interopCenter()) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor(IBridgehubBase _bridgehub) {
        BRIDGE_HUB = _bridgehub;
    }

    /// @notice Used to initialize the contract.
    /// @dev Also deployed on L2 as a system contract; there the owner and related functions are unused.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @notice Registers a chain for interop via a service transaction, so no base tokens are
    /// needed (ease-of-use path). Callable only once per pair to prevent spamming; both chains must
    /// settle on the same settlement layer.
    /// @param chainToBeRegistered the chain to be registered
    /// @param chainRegisteredOn the chain to register on
    function registerChain(uint256 chainToBeRegistered, uint256 chainRegisteredOn) external {
        require(!chainRegisteredOnChain[chainToBeRegistered][chainRegisteredOn], ChainAlreadyRegistered());
        _checkSettlementLayers(chainToBeRegistered, chainRegisteredOn);

        chainRegisteredOnChain[chainToBeRegistered][chainRegisteredOn] = true;

        IMailbox chainRegisteredOnAddress = IMailbox(BRIDGE_HUB.getZKChain(chainRegisteredOn));
        // slither-disable-next-line unused-return
        chainRegisteredOnAddress.requestL2ServiceTransaction(
            address(L2_BRIDGEHUB_ADDR),
            _getL2TxCalldata(chainToBeRegistered)
        );
    }

    /// @inheritdoc IL1CrossChainSender
    /// @dev Registers a chain on the L2 via a normal deposit: anyone can trigger it (via the
    /// L1 Interop Center), but the caller provides the base tokens.
    // slither-disable-next-line locked-ether
    function initiateIndirectCall(
        uint256 chainRegisteredOn,
        address,
        uint256,
        bytes calldata _data
    ) external payable virtual override onlyL1InteropCenter returns (IndirectCallRequest memory request) {
        if (msg.value != 0) {
            revert NoEthAllowed();
        }
        bytes1 encodingVersion = _data[0];
        if (encodingVersion != CHAIN_REGISTRATION_SENDER_ENCODING_VERSION) {
            revert UnsupportedEncodingVersion();
        }

        uint256 chainToBeRegistered = abi.decode(_data[1:], (uint256));
        address chainToBeRegisteredAddress = BRIDGE_HUB.getZKChain(chainToBeRegistered);
        if (chainToBeRegisteredAddress == address(0)) {
            revert ZKChainNotRegistered();
        }
        _checkSettlementLayers(chainToBeRegistered, chainRegisteredOn);

        request = IndirectCallRequest({
            magicValue: INDIRECT_CALL_MAGIC_VALUE,
            l2Contract: L2_BRIDGEHUB_ADDR,
            l2Calldata: _getL2TxCalldata(chainToBeRegistered),
            factoryDeps: new bytes[](0),
            // `txDataHash` exists so token bridges can recover funds after a failed L2 leg; nothing
            // to recover here, so `bytes32(0)` is fine.
            txDataHash: bytes32(0)
        });
    }

    /// @notice Used to get the L2 transaction calldata for the chain registration.
    /// @dev Also enforces the atomic-interop timeout precondition: the chain being registered must
    /// already have at least one batch inside this layer's message root. No backfill of
    /// pre-existing chains is needed — see {protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}.
    /// @param chainToBeRegistered the chain to be registered
    /// @return the L2 transaction calldata
    function _getL2TxCalldata(uint256 chainToBeRegistered) internal view returns (bytes memory) {
        bytes32 baseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(chainToBeRegistered);
        if (baseTokenAssetId == bytes32(0)) {
            revert ZKChainNotRegistered();
        }
        if (BRIDGE_HUB.messageRoot().chainTreeLeafCount(chainToBeRegistered) == 0) {
            revert ChainHasNoBatchesInMessageRoot(chainToBeRegistered);
        }
        return abi.encodeCall(IL2Bridgehub.registerChainForInterop, (chainToBeRegistered, baseTokenAssetId));
    }

    /// @notice Checks that both chains are settling on the same settlement layer. As of v32 both
    /// settling directly on L1 is permitted — see {protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}.
    /// @param chainToBeRegistered the chain to be registered
    /// @param chainRegisteredOn the chain to register on
    function _checkSettlementLayers(uint256 chainToBeRegistered, uint256 chainRegisteredOn) internal view {
        uint256 chainToBeRegisteredSettlementLayer = BRIDGE_HUB.settlementLayer(chainToBeRegistered);
        uint256 chainRegisteredOnSettlementLayer = BRIDGE_HUB.settlementLayer(chainRegisteredOn);
        if (chainToBeRegisteredSettlementLayer != chainRegisteredOnSettlementLayer) {
            revert ChainsSettlementLayerMismatch(chainToBeRegisteredSettlementLayer, chainRegisteredOnSettlementLayer);
        }
    }

    /// @inheritdoc IL1CrossChainSender
    /// @dev No-op: failed L1->L2 transactions need no recovery here.
    function confirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyL1InteropCenter {}
}
