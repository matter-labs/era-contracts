// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IL2StandardToken} from "./interfaces/IL2StandardToken.sol";
import {IL2NativeTokenVault} from "./interfaces/IL2NativeTokenVault.sol";
import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";

import {L2StandardERC20} from "./L2StandardERC20.sol";
import {L2ContractHelper, DEPLOYER_SYSTEM_CONTRACT, L2_ASSET_ROUTER, IContractDeployer} from "../L2ContractHelper.sol";
import {SystemContractsCaller} from "../SystemContractsCaller.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {EmptyAddress, EmptyBytes32, AddressMismatch, AssetIdMismatch, DeployFailed, AmountMustBeGreaterThanZero, InvalidCaller} from "../L2ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2NativeTokenVault is IL2NativeTokenVault, Ownable2StepUpgradeable {
    /// @dev Chain ID of L1 for bridging reasons.
    uint256 public immutable L1_CHAIN_ID;

    /// @dev The address of the L2 legacy shared bridge.
    IL2SharedBridgeLegacy public L2_LEGACY_SHARED_BRIDGE;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal l2TokenProxyBytecodeHash;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public l2TokenBeacon;

    mapping(bytes32 assetId => address tokenAddress) public override tokenAddress;

    modifier onlyBridge() {
        if (msg.sender != address(L2_ASSET_ROUTER)) {
            revert InvalidCaller(msg.sender);
            // Only L2 bridge can call this method
        }
        _;
    }

    /// @notice Initializes the bridge contract for later use.
    /// @param _l1ChainId The L1 chain id differs between mainnet and testnets.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _aliasedOwner The address of the governor contract.
    /// @param _legacySharedBridge The address of the L2 legacy shared bridge.
    /// @param _l2TokenBeacon The address of the L2 token beacon for legacy chains.
    /// @param _contractsDeployedAlready Ensures beacon proxy for standard ERC20 has not been deployed.
    constructor(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _legacySharedBridge,
        address _l2TokenBeacon,
        bool _contractsDeployedAlready
    ) {
        L1_CHAIN_ID = _l1ChainId;
        L2_LEGACY_SHARED_BRIDGE = IL2SharedBridgeLegacy(_legacySharedBridge);

        _disableInitializers();
        if (_l2TokenProxyBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }
        if (_aliasedOwner == address(0)) {
            revert EmptyAddress();
        }

        l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
        _transferOwnership(_aliasedOwner);

        if (_contractsDeployedAlready) {
            if (_l2TokenBeacon == address(0)) {
                revert EmptyAddress();
            }
            l2TokenBeacon = UpgradeableBeacon(_l2TokenBeacon);
        } else {
            address l2StandardToken = address(new L2StandardERC20{salt: bytes32(0)}());
            l2TokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);
            l2TokenBeacon.transferOwnership(owner());
            emit L2TokenBeaconUpdated(_l2TokenBeacon, _l2TokenProxyBytecodeHash);
        }
    }

    function setLegacyTokenAssetId(address _l2TokenAddress) public {
        address l1TokenAddress = L2_LEGACY_SHARED_BRIDGE.l1TokenAddress(_l2TokenAddress);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1TokenAddress);
        tokenAddress[assetId] = _l2TokenAddress;
    }

    /// @notice Used when the chain receives a transfer from L1 Shared Bridge and correspondingly mints the asset.
    /// @param _chainId The chainId that the message is from.
    /// @param _assetId The assetId of the asset being bridged.
    /// @param _data The abi.encoded transfer data.
    function bridgeMint(uint256 _chainId, bytes32 _assetId, bytes calldata _data) external payable override onlyBridge {
        address token = tokenAddress[_assetId];
        (
            address _l1Sender,
            address _l2Receiver,
            address originToken,
            uint256 _amount,
            bytes memory erc20Data
        ) = DataEncoding.decodeBridgeMintData(_data);

        if (token == address(0)) {
            address expectedToken = calculateCreate2TokenAddress(originToken);
            bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, originToken);
            if (_assetId != expectedAssetId) {
                // Make sure that a NativeTokenVault sent the message
                revert AssetIdMismatch(expectedAssetId, _assetId);
            }
            address deployedToken = _deployL2Token(originToken, erc20Data);
            if (deployedToken != expectedToken) {
                revert AddressMismatch(expectedToken, deployedToken);
            }
            tokenAddress[_assetId] = expectedToken;
            token = expectedToken;
        }

        IL2StandardToken(token).bridgeMint(_l2Receiver, _amount);
        /// backwards compatible event
        emit FinalizeDeposit(_l1Sender, _l2Receiver, token, _amount);
        emit BridgeMint({
            chainId: _chainId,
            assetId: _assetId,
            sender: _l1Sender,
            l2Receiver: _l2Receiver,
            amount: _amount
        });
    }

    /// @notice Burns wrapped tokens and returns the calldata for L2 -> L1 message.
    /// @dev In case of native token vault _data is the tuple of _depositAmount and _l2Receiver.
    /// @param _chainId The chainId that the message will be sent to.
    /// @param _mintValue The L1 base token value bridged.
    /// @param _assetId The L2 assetId of the asset being bridged.
    /// @param _prevMsgSender The original caller of the shared bridge.
    /// @param _data The abi.encoded transfer data.
    /// @return l1BridgeMintData The calldata used by l1 asset handler to unlock tokens for recipient.
    function bridgeBurn(
        uint256 _chainId,
        uint256 _mintValue,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridge returns (bytes memory l1BridgeMintData) {
        (uint256 _amount, address _l1Receiver) = abi.decode(_data, (uint256, address));
        if (_amount == 0) {
            // "Amount cannot be zero");
            revert AmountMustBeGreaterThanZero();
        }

        address l2Token = tokenAddress[_assetId];
        IL2StandardToken(l2Token).bridgeBurn(_prevMsgSender, _amount);

        /// backwards compatible event
        emit WithdrawalInitiated(_prevMsgSender, _l1Receiver, l2Token, _amount);
        emit BridgeBurn({
            chainId: _chainId,
            assetId: _assetId,
            l2Sender: _prevMsgSender,
            receiver: _l1Receiver,
            mintValue: _mintValue,
            amount: _amount
        });
        l1BridgeMintData = _data;
    }

    /// @notice Calculates L2 wrapped token address corresponding to L1 token counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return expectedToken The address of token on L2.
    function l2TokenAddress(address _l1Token) public view override returns (address expectedToken) {
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1Token);
        expectedToken = tokenAddress[expectedAssetId];
    }

    /// @notice Deploys and initializes the L2 token for the L1 counterpart.
    /// @param _l1Token The address of token on L1.
    /// @param _erc20Data The ERC20 metadata of the token deployed.
    /// @return The address of the beacon proxy (L2 wrapped / bridged token).
    function _deployL2Token(address _l1Token, bytes memory _erc20Data) internal returns (address) {
        bytes32 salt = _getCreate2Salt(_l1Token);

        BeaconProxy l2Token;
        if (address(L2_LEGACY_SHARED_BRIDGE) == address(0)) {
            // Deploy the beacon proxy for the L2 token
            l2Token = _deployBeaconProxy(salt);
        } else {
            // Deploy the beacon proxy for the L2 token
            address l2TokenAddr = L2_LEGACY_SHARED_BRIDGE.deployBeaconProxy(salt);
            l2Token = BeaconProxy(payable(l2TokenAddr));
        }
        L2StandardERC20(address(l2Token)).bridgeInitialize(_l1Token, _erc20Data);

        return address(l2Token);
    }

    /// @notice Deploys the beacon proxy for the L2 token, while using ContractDeployer system contract.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `l2TokenProxyBytecodeHash` is used
    /// for the code of the proxy.
    /// @param salt The salt used for beacon proxy deployment of L2 wrapped token.
    /// @return proxy The beacon proxy, i.e. L2 wrapped / bridged token.
    function _deployBeaconProxy(bytes32 salt) internal returns (BeaconProxy proxy) {
        (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
            uint32(gasleft()),
            DEPLOYER_SYSTEM_CONTRACT,
            0,
            abi.encodeCall(
                IContractDeployer.create2,
                (salt, l2TokenProxyBytecodeHash, abi.encode(address(l2TokenBeacon), ""))
            )
        );

        // The deployment should be successful and return the address of the proxy
        if (!success) {
            revert DeployFailed();
        }
        proxy = BeaconProxy(abi.decode(returndata, (address)));
    }

    /// @notice Calculates L2 wrapped token address given the currently stored beacon proxy bytecode hash and beacon address.
    /// @param _l1Token The address of token on L1.
    /// @return Address of an L2 token counterpart.
    function calculateCreate2TokenAddress(address _l1Token) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = _getCreate2Salt(_l1Token);
        address deployerAddress = address(L2_LEGACY_SHARED_BRIDGE) == address(0)
            ? address(this)
            : address(L2_LEGACY_SHARED_BRIDGE);
        return
            L2ContractHelper.computeCreate2Address(
                deployerAddress,
                salt,
                l2TokenProxyBytecodeHash,
                constructorInputHash
            );
    }

    /// @notice Converts the L1 token address to the create2 salt of deployed L2 token.
    /// @param _l1Token The address of token on L1.
    /// @return salt The salt used to compute address of wrapped token on L2 and for beacon proxy deployment.
    function _getCreate2Salt(address _l1Token) internal pure returns (bytes32 salt) {
        salt = bytes32(uint256(uint160(_l1Token)));
    }
}
