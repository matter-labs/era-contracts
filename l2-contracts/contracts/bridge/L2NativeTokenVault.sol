// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IL2SharedBridge} from "./interfaces/IL2SharedBridge.sol";
import {IL2StandardToken} from "./interfaces/IL2StandardToken.sol";
import {IL2NativeTokenVault} from "./interfaces/IL2NativeTokenVault.sol";

import {L2StandardERC20} from "./L2StandardERC20.sol";
import {L2ContractHelper, DEPLOYER_SYSTEM_CONTRACT, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, L1_CHAIN_ID, IContractDeployer} from "../L2ContractHelper.sol";
import {SystemContractsCaller} from "../SystemContractsCaller.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {EmptyAddress, EmptyBytes32, AddressMismatch, AssetIdMismatch, DeployFailed, AmountMustBeGreaterThanZero, InvalidCaller} from "../L2ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2NativeTokenVault is IL2NativeTokenVault, Ownable2StepUpgradeable {
    IL2SharedBridge public override l2Bridge;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public l2TokenBeacon;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal l2TokenProxyBytecodeHash;

    mapping(bytes32 assetId => address tokenAddress) public override tokenAddress;

    modifier onlyBridge() {
        if (msg.sender != address(l2Bridge)) {
            revert InvalidCaller(msg.sender);
            // Only L2 bridge can call this method
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    constructor() {
        _disableInitializers();
    }

    /// @dev Sets the Shared Bridge contract address. Should be called only once.
    function setSharedBridge(IL2SharedBridge _sharedBridge) external onlyOwner {
        if (address(l2Bridge) != address(0)) {
            // "SD: shared bridge already set";
            revert AddressMismatch(address(0), address(l2Bridge));
        }
        if (address(_sharedBridge) == address(0)) {
            // "SD: shared bridge 0");
            revert EmptyAddress();
        }

        l2Bridge = _sharedBridge;
    }

    /// @notice Initializes the bridge contract for later use. Expected to be used in the proxy.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _aliasedOwner The address of the governor contract.
    /// @param _contractsDeployedAlready Ensures beacon proxy for standard ERC20 has not been deployed
    function initialize(
        bytes32 _l2TokenProxyBytecodeHash,
        address _aliasedOwner,
        bool _contractsDeployedAlready
    ) external reinitializer(2) {
        if (_l2TokenProxyBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }
        if (_aliasedOwner == address(0)) {
            revert EmptyAddress();
        }

        if (!_contractsDeployedAlready) {
            address l2StandardToken = address(new L2StandardERC20{salt: bytes32(0)}());
            l2TokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);
            l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
            l2TokenBeacon.transferOwnership(_aliasedOwner);
        }

        _transferOwnership(_aliasedOwner);
    }

    /// @notice Sets the l2TokenBeacon, called after initialize.
    function setL2TokenBeacon(address _l2TokenBeacon, bytes32 _l2TokenProxyBytecodeHash) external onlyOwner {
        l2TokenBeacon = UpgradeableBeacon(_l2TokenBeacon);
        l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
        emit L2TokenBeaconUpdated(_l2TokenBeacon, _l2TokenProxyBytecodeHash);
    }

    /// @notice Used when the chain receives a transfer from L1 Shared Bridge and correspondingly mints the asset.
    function bridgeMint(uint256 _chainId, bytes32 _assetId, bytes calldata _data) external payable override onlyBridge {
        address token = tokenAddress[_assetId];
        (
            uint256 _amount,
            address _l1Sender,
            address _l2Receiver,
            bytes memory erc20Data,
            address originToken
        ) = DataEncoding.decodeBridgeMintData(_data);

        if (token == address(0)) {
            address expectedToken = _calculateCreate2TokenAddress(originToken);
            bytes32 expectedAssetId = keccak256(
                abi.encode(_chainId, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, bytes32(uint256(uint160(originToken))))
            );
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
        // solhint-disable-next-line func-named-parameters
        emit BridgeMint(_chainId, _assetId, _l1Sender, _l2Receiver, _amount);
    }

    /// @notice Used when the chain starts to send a tx and needs to burn the asset.
    function bridgeBurn(
        uint256 _chainId,
        uint256 _mintValue,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridge returns (bytes memory _bridgeMintData) {
        (uint256 _amount, address _l1Receiver) = abi.decode(_data, (uint256, address));
        if (_amount == 0) {
            // "Amount cannot be zero");
            revert AmountMustBeGreaterThanZero();
        }

        address l2Token = tokenAddress[_assetId];
        IL2StandardToken(l2Token).bridgeBurn(_prevMsgSender, _amount);

        /// backwards compatible event
        emit WithdrawalInitiated(_prevMsgSender, _l1Receiver, l2Token, _amount);
        // solhint-disable-next-line func-named-parameters
        emit BridgeBurn(_chainId, _assetId, _prevMsgSender, _l1Receiver, _mintValue, _amount);
        _bridgeMintData = _data;
    }

    /// @dev Deploy and initialize the L2 token for the L1 counterpart
    function _deployL2Token(address _l1Token, bytes memory _data) internal returns (address) {
        bytes32 salt = _getCreate2Salt(_l1Token);

        BeaconProxy l2Token = _deployBeaconProxy(salt);
        L2StandardERC20(address(l2Token)).bridgeInitialize(_l1Token, _data);

        return address(l2Token);
    }

    /// @dev Deploy the beacon proxy for the L2 token, while using ContractDeployer system contract.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `l2TokenProxyBytecodeHash` is used
    /// for the code of the proxy.
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

    /// @dev Convert the L1 token address to the create2 salt of deployed L2 token
    function _getCreate2Salt(address _l1Token) internal pure returns (bytes32 salt) {
        salt = bytes32(uint256(uint160(_l1Token)));
    }

    /// @notice Calculates L2 wrapped token address given the currently stored beacon proxy bytecode hash and beacon address.
    /// @param _l1Token The address of token on L1.
    /// @return Address of an L2 token counterpart.
    function _calculateCreate2TokenAddress(address _l1Token) internal view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = _getCreate2Salt(_l1Token);
        return
            L2ContractHelper.computeCreate2Address(address(this), salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }

    /// @notice Calculates L2 wrapped token address corresponding to L1 token counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return expectedToken The address of token on L2.
    function l2TokenAddress(address _l1Token) public view override returns (address expectedToken) {
        bytes32 expectedAssetId = keccak256(
            abi.encode(L1_CHAIN_ID, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, bytes32(uint256(uint160(_l1Token))))
        );
        expectedToken = tokenAddress[expectedAssetId];
        if (expectedToken == address(0)) {
            expectedToken = _calculateCreate2TokenAddress(_l1Token);
        }
    }
}
