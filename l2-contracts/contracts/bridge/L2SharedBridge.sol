// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL2SharedBridge} from "./interfaces/IL2SharedBridge.sol";
import {IL2StandardAsset} from "./interfaces/IL2StandardAsset.sol";
import {IL2StandardToken} from "./interfaces/IL2StandardToken.sol";
import {IL2StandardDeployer} from "./interfaces/IL2StandardDeployer.sol";

import {L2StandardERC20} from "./L2StandardERC20.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {L2ContractHelper, DEPLOYER_SYSTEM_CONTRACT, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, IContractDeployer} from "../L2ContractHelper.sol";
import {SystemContractsCaller} from "../SystemContractsCaller.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2SharedBridge is IL2SharedBridge, Initializable {
    /// @dev The address of the L1 shared bridge counterpart.
    address public override l1SharedBridge;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public l2TokenBeacon;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal l2TokenProxyBytecodeHash;

    /// @dev A mapping l2 token address => l1 token address
    mapping(address l2TokenAddress => address l1TokenAddress) public override l1TokenAddress;

    /// @dev The address of the legacy L1 erc20 bridge counterpart.
    /// This is non-zero only on Era, and should not be renamed for backward compatibility with the SDKs.
    address public override l1Bridge;

    /// @dev Chain ID of Era for legacy reasons
    uint256 immutable ERA_CHAIN_ID;

    /// @dev Chain ID of L1 for bridging reasons
    uint256 immutable L1_CHAIN_ID;

    IL2StandardDeployer public standardDeployer;

    /// @dev A mapping l2 token address => l1 token address
    mapping(bytes32 assetInfo => address assetAddress) public override assetAddress;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    constructor(uint256 _eraChainId, uint256 _l1ChainId) {
        ERA_CHAIN_ID = _eraChainId;
        L1_CHAIN_ID = _l1ChainId;
        _disableInitializers();
    }

    /// @notice Initializes the bridge contract for later use. Expected to be used in the proxy.
    /// @param _l1SharedBridge The address of the L1 Bridge contract.
    /// @param _l1Bridge The address of the legacy L1 Bridge contract.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _aliasedOwner The address of the governor contract.
    function initialize(
        address _l1SharedBridge,
        address _l1Bridge,
        bytes32 _l2TokenProxyBytecodeHash,
        address _aliasedOwner
    ) external reinitializer(2) {
        require(_l1SharedBridge != address(0), "bf");
        require(_l2TokenProxyBytecodeHash != bytes32(0), "df");
        require(_aliasedOwner != address(0), "sf");

        l1SharedBridge = _l1SharedBridge;

        if (block.chainid != ERA_CHAIN_ID) {
            address l2StandardToken = address(new L2StandardERC20{salt: bytes32(0)}());
            l2TokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);
            l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
            l2TokenBeacon.transferOwnership(_aliasedOwner);
        } else {
            require(_l1Bridge != address(0), "bf2");
            l1Bridge = _l1Bridge;
            // l2StandardToken and l2TokenBeacon are already deployed on ERA, and stored in the proxy
        }
    }

    /// @notice Finalize the deposit and mint funds
    /// @param _l1Sender The account address that initiated the deposit on L1
    // / @param _l2Receiver The account address that would receive minted ether
    /// @param _l1Token The address of the token that was locked on the L1
    // / @param _amount Total amount of tokens deposited from L1
    /// @param _data The additional data that user can pass with the deposit
    function finalizeDeposit(bytes32 _assetInfo, bytes calldata _data) public override {
        // Only the L1 bridge counterpart can initiate and finalize the deposit.

        // require(
        //     AddressAliasHelper.undoL1ToL2Alias(msg.sender) == l1Bridge ||
        //         AddressAliasHelper.undoL1ToL2Alias(msg.sender) == l1LegacyBridge,
        //     "mq"
        // );

        address asset = assetAddress[_assetInfo];
        if (asset != address(0)) {
            IL2StandardAsset(asset).bridgeMint(L1_CHAIN_ID, _assetInfo, _data);
        } else {
            IL2StandardAsset(standardDeployer).bridgeMint(L1_CHAIN_ID, _assetInfo, _data);
        }

        emit FinalizeDepositSharedBridge(L1_CHAIN_ID, _assetInfo, keccak256(_data));
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @param _assetInfo The L2 token address which is withdrawn
    /// @param _assetData The data that is passed to the asset contract
    function withdraw(bytes32 _assetInfo, bytes calldata _assetData) external override {
        address asset = assetAddress[_assetInfo];
        bytes memory _bridgeMintData = IL2StandardAsset(assetAddress[_assetInfo]).bridgeBurn(
            L1_CHAIN_ID,
            0,
            _assetInfo,
            msg.sender,
            _assetData
        );

        bytes memory message = _getL1WithdrawMessage(_assetInfo, _bridgeMintData);
        L2ContractHelper.sendMessageToL1(message);

        emit WithdrawalInitiatedSharedBridge(L1_CHAIN_ID, msg.sender, _assetInfo, keccak256(_assetData));
    }

    /// @dev Encode the message for l2ToL1log sent with withdraw initialization
    function _getL1WithdrawMessage(
        bytes32 _assetInfo,
        bytes memory _bridgeMintData
    ) internal pure returns (bytes memory) {
        // note we use the IL1ERC20Bridge.finalizeWithdrawal function selector to specify the selector for L1<>L2 messages,
        // and we use this interface so that when the switch happened the old messages could be processed
        return abi.encodePacked(IL1ERC20Bridge.finalizeWithdrawal.selector, _assetInfo, _bridgeMintData);
    }

    /*//////////////////////////////////////////////////////////////
                            LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external override { // onlyBridge {
        bytes32 assetInfo = keccak256(
            abi.encode(L1_CHAIN_ID, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, bytes32(uint160(_l1Token)))
        );
        bytes memory data = abi.encode(_l1Sender, _amount, _l2Receiver, _data, _l1Token);
        finalizeDeposit(assetInfo, data);
    }

    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external {
        bytes32 assetInfo = keccak256(
            abi.encode(L1_CHAIN_ID, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, bytes32(uint160(getL1TokenAddress(_l2Token))))
        );
        bytes memory data = abi.encode(_amount, _l1Receiver);
    }

    function getL1TokenAddress(address _l2Token) public view returns (address) {
        return IL2StandardToken(_l2Token).l1Address();
    }

    /// @return Address of an L2 token counterpart
    function l2TokenAddress(address _l1Token) public view returns (address) {
        return standardDeployer.l2TokenAddress(_l1Token);
    }
}
