// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {IChainRegistrationSender} from "./IChainRegistrationSender.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IL1CrossChainSender} from "../../bridge/interfaces/IL1CrossChainSender.sol";

import {IBridgehubBase, L2TransactionRequestTwoBridgesInner} from "../bridgehub/IBridgehubBase.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";

import {L2_BRIDGEHUB_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {TWO_BRIDGES_MAGIC_VALUE} from "../../common/Config.sol";

import {Unauthorized, UnsupportedEncodingVersion} from "../../common/L1ContractErrors.sol";
import {ChainAlreadyRegistered, NoEthAllowed, ZKChainNotRegistered} from "../bridgehub/L1BridgehubErrors.sol";
import {IL2Bridgehub} from "../bridgehub/IL2Bridgehub.sol";

/// @dev The encoding version of the data.
bytes1 constant CHAIN_REGISTRATION_SENDER_ENCODING_VERSION = 0x01;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainRegistrationSender contract is used to register chains in other chains for interop via a service transaction.
contract ChainRegistrationSender is
    IChainRegistrationSender,
    IL1CrossChainSender,
    ReentrancyGuard,
    Ownable2StepUpgradeable
{
    IBridgehubBase public immutable BRIDGE_HUB;

    mapping(uint256 chainToBeRegistered => mapping(uint256 chainRegisteredOn => bool isRegistered))
        public chainRegisteredOnChain;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor(IBridgehubBase _bridgehub) {
        BRIDGE_HUB = _bridgehub;
    }

    /// @notice used to initialize the contract
    /// @notice this contract is also deployed on L2 as a system contract there the owner and the related functions will not be used
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @notice used to register a chain for interop via a service transaction.abi
    /// @notice this is provided for ease of use, base tokens does not have to be provided.
    /// @notice to prevent spamming, we only allow this to be called once.
    /// @param chainToBeRegistered the chain to be registered
    /// @param chainRegisteredOn the chain to register on
    function registerChain(uint256 chainToBeRegistered, uint256 chainRegisteredOn) external {
        require(!chainRegisteredOnChain[chainToBeRegistered][chainRegisteredOn], ChainAlreadyRegistered());
        chainRegisteredOnChain[chainToBeRegistered][chainRegisteredOn] = true;

        IMailbox chainRegisteredOnAddress = IMailbox(BRIDGE_HUB.getZKChain(chainRegisteredOn));
        // slither-disable-next-line unused-return
        chainRegisteredOnAddress.requestL2ServiceTransaction(
            address(L2_BRIDGEHUB_ADDR),
            _getL2TxCalldata(chainToBeRegistered)
        );
    }

    /// @inheritdoc IL1CrossChainSender
    /// @notice Registers a chain on the L2 via a normal deposit.
    /// @notice this is can be called by anyone (via the bridgehub), but baseTokens need to be provided.
    // slither-disable-next-line locked-ether
    function bridgehubDeposit(
        uint256,
        address,
        uint256,
        bytes calldata _data
    ) external payable virtual override onlyBridgehub returns (L2TransactionRequestTwoBridgesInner memory request) {
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
        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_BRIDGEHUB_ADDR,
            l2Calldata: _getL2TxCalldata(chainToBeRegistered),
            factoryDeps: new bytes[](0),
            // The `txDataHash` is typically used in usual ERC20 bridges to commit to the transaction data
            // so that the user can recover funds in case the bridging fails on L2.
            // However, this contract uses the `requestL2TransactionTwoBridges` method just to perform an L1->L2 transaction.
            // We do not need to recover anything and so `bytes32(0)` here is okay.
            txDataHash: bytes32(0)
        });
    }

    /// @notice Used to get the L2 transaction calldata for the chain registration.
    /// @param chainToBeRegistered the chain to be registered
    /// @return the L2 transaction calldata
    function _getL2TxCalldata(uint256 chainToBeRegistered) internal view returns (bytes memory) {
        bytes32 baseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(chainToBeRegistered);
        return abi.encodeCall(IL2Bridgehub.registerChainForInterop, (chainToBeRegistered, baseTokenAssetId));
    }

    /// @inheritdoc IL1CrossChainSender
    /// @notice This function is not used for ChainRegistrationSender, since we do not need to support failed L1->L2 transactions.
    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external override {}
}
