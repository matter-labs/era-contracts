// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL2SharedBridge} from "./interfaces/IL2SharedBridge.sol";
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
contract L2StandardDeployer is IL2StandardDeployer, Ownable2StepUpgradeable {
    IL2SharedBridge public override l2Bridge;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public l2TokenBeacon;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal l2TokenProxyBytecodeHash;

    mapping(bytes32 assetInfo => address tokenAddress) public override tokenAddress;

    modifier onlyBridge() {
        require(msg.sender == address(l2Bridge), "SD: only Bridge"); // Only L2 bridge can call this method
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    constructor() {
        _disableInitializers();
    }

    /// @dev Sets the L1ERC20Bridge contract address. Should be called only once.
    function setSharedBridge(IL2SharedBridge _sharedBridge) external onlyOwner {
        require(address(l2Bridge) == address(0), "SD: shared bridge already set");
        require(address(_sharedBridge) != address(0), "SD: shared bridge 0");
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
        require(_l2TokenProxyBytecodeHash != bytes32(0), "df");
        require(_aliasedOwner != address(0), "sf");

        if (!_contractsDeployedAlready) {
            address l2StandardToken = address(new L2StandardERC20{salt: bytes32(0)}());
            l2TokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);
            l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
            l2TokenBeacon.transferOwnership(_aliasedOwner);
        }

        _transferOwnership(_aliasedOwner);
    }

    function bridgeMint(uint256 _chainId, bytes32 _assetInfo, bytes calldata _data) external payable override {
        address token = tokenAddress[_assetInfo];
        (uint256 _amount, address _l1Sender, address _l2Receiver, bytes memory erc20Data, address originToken) = abi
            .decode(_data, (uint256, address, address, bytes, address));
        address expectedToken = l2TokenAddress(originToken);
        if (token == address(0)) {
            require(
                _assetInfo ==
                    keccak256(
                        abi.encode(_chainId, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, bytes32(uint256(uint160(originToken))))
                    ),
                "gg"
            ); // Make sure that a NativeTokenVault sent the message
            address deployedToken = _deployL2Token(originToken, erc20Data);
            require(deployedToken == expectedToken, "mt");
            tokenAddress[_assetInfo] = expectedToken;
        }

        IL2StandardToken(expectedToken).bridgeMint(_l2Receiver, _amount);
        /// backwards compatible event
        emit FinalizeDeposit(_l1Sender, _l2Receiver, expectedToken, _amount);
    }

    function bridgeBurn(
        uint256 _chainId,
        uint256 _mintValue,
        bytes32 _assetInfo,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridge returns (bytes memory _bridgeMintData) {
        (uint256 _amount, address _l1Receiver) = abi.decode(_data, (uint256, address));
        require(_amount > 0, "Amount cannot be zero");

        address l2Token = tokenAddress[_assetInfo];
        IL2StandardToken(l2Token).bridgeBurn(_prevMsgSender, _amount);

        /// backwards compatible event
        emit WithdrawalInitiated(_prevMsgSender, _l1Receiver, l2Token, _amount);
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
        require(success, "mk");
        proxy = BeaconProxy(abi.decode(returndata, (address)));
    }

    /// @dev Convert the L1 token address to the create2 salt of deployed L2 token
    function _getCreate2Salt(address _l1Token) internal pure returns (bytes32 salt) {
        salt = bytes32(uint256(uint160(_l1Token)));
    }

    /// @return Address of an L2 token counterpart
    function l2TokenAddress(address _l1Token) public view override returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = _getCreate2Salt(_l1Token);
        return
            L2ContractHelper.computeCreate2Address(address(this), salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }
}
