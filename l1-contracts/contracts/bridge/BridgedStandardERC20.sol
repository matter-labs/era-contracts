// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Upgrade} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Upgrade.sol";

import {IBridgedStandardToken} from "./interfaces/IBridgedStandardToken.sol";
import {NonSequentialVersion, Unauthorized, ZeroAddress} from "../common/L1ContractErrors.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {L2NativeTokenVault} from "../bridge/ntv/L2NativeTokenVault.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The ERC20 token implementation, that is used in the "default" ERC20 bridge. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract BridgedStandardERC20 is ERC20PermitUpgradeable, IBridgedStandardToken, ERC1967Upgrade {
    /// @dev Records which of the `name`/`symbol`/`decimals` getters the origin token actually
    /// implemented; the missing ones are mimicked by reverting.
    struct ERC20Getters {
        bool ignoreName;
        bool ignoreSymbol;
        bool ignoreDecimals;
    }

    ERC20Getters private availableGetters;

    /// @dev The value returned by the `decimals` getter. Stored here (unlike `name`/`symbol`) because the
    /// standard OpenZeppelin token keeps `decimals` as a constant rather than a storage variable.
    uint8 private decimals_;

    /// @dev Deprecated address of the L2 bridge that was used as trustee to mint/burn tokens; use the
    /// L2AssetRouter and L2NativeTokenVault instead.
    address public override l2Bridge;

    /// @dev Address of the token on its origin chain that can be deposited to mint this bridged token
    address public override originToken;

    /// @dev Address of the native token vault that is used as trustee who can mint/burn tokens
    address public nativeTokenVault;

    /// @dev The assetId of the token.
    bytes32 public assetId;

    /// @dev Also lazily migrates legacy tokens (deployed before the NTV existed, only on L2s): sets
    /// `nativeTokenVault` to the canonical address and derives the asset ID on first use.
    modifier onlyNTV() {
        address ntv = nativeTokenVault;
        if (ntv == address(0)) {
            ntv = L2_NATIVE_TOKEN_VAULT_ADDR;
            nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
            assetId = DataEncoding.encodeNTVAssetId(
                L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).L1_CHAIN_ID(),
                originToken
            );
        }
        require(msg.sender == ntv, Unauthorized(msg.sender));
        _;
    }

    modifier onlyNextVersion(uint8 _version) {
        // The version should be incremented by 1. Otherwise, the governor risks disabling
        // future reinitialization of the token by providing too large a version.
        require(_version == _getInitializedVersion() + 1, NonSequentialVersion());
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    constructor() {
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @notice Initializes a contract token for later use. Expected to be used in the proxy.
    /// @dev Stores the L1 address of the bridge and set `name`/`symbol`/`decimals` getters that L1 token has.
    /// @param _assetId The assetId of the token.
    /// @param _originToken Address of the origin token that can be deposited to mint this bridged token
    /// @param _data The additional data that the L1 bridge provide for initialization.
    /// In this case, it is packed `name`/`symbol`/`decimals` of the L1 token.
    function bridgeInitialize(bytes32 _assetId, address _originToken, bytes calldata _data) external initializer {
        require(_originToken != address(0), ZeroAddress());
        originToken = _originToken;
        assetId = _assetId;

        nativeTokenVault = msg.sender;

        bytes memory nameBytes;
        bytes memory symbolBytes;
        bytes memory decimalsBytes;
        // We parse the data exactly as they were created on the L1 bridge
        // slither-disable-next-line unused-return
        (, nameBytes, symbolBytes, decimalsBytes) = DataEncoding.decodeTokenData(_data);

        ERC20Getters memory getters;
        string memory decodedName;
        string memory decodedSymbol;

        // The L1 bridge didn't validate the return types of the token's `name`/`symbol`/`decimals`, so
        // decode defensively: Solidity can only "try-decode" via an external self-call whose failure is
        // caught, marking the getter as unavailable.
        try this.decodeString(nameBytes) returns (string memory nameString) {
            decodedName = nameString;
        } catch {
            getters.ignoreName = true;
        }

        try this.decodeString(symbolBytes) returns (string memory symbolString) {
            decodedSymbol = symbolString;
        } catch {
            getters.ignoreSymbol = true;
        }

        // Set decoded values for name and symbol.
        __ERC20_init_unchained(decodedName, decodedSymbol);

        // Set the name for EIP-712 signature.
        __ERC20Permit_init(decodedName);

        try this.decodeUint8(decimalsBytes) returns (uint8 decimalsUint8) {
            // Set decoded value for decimals.
            decimals_ = decimalsUint8;
        } catch {
            getters.ignoreDecimals = true;
        }

        availableGetters = getters;
        emit BridgeInitialize(_originToken, decodedName, decodedSymbol, decimals_);
    }

    /// @notice A method to be called by the governor to update the token's metadata.
    /// @param _availableGetters The getters that the token has.
    /// @param _newName The new name of the token.
    /// @param _newSymbol The new symbol of the token.
    /// @param _version The version of the token that will be initialized.
    /// @dev The _version must be exactly the version higher by 1 than the current version. This is needed
    /// to ensure that the governor can not accidentally disable future reinitialization of the token.
    function reinitializeToken(
        ERC20Getters calldata _availableGetters,
        string calldata _newName,
        string calldata _newSymbol,
        uint8 _version
    ) external onlyNextVersion(_version) reinitializer(_version) {
        // It is expected that this token is deployed as a beacon proxy, so we'll
        // allow the governor of the beacon to reinitialize the token.
        address beaconAddress = _getBeacon();
        require(msg.sender == UpgradeableBeacon(beaconAddress).owner(), Unauthorized(msg.sender));

        __ERC20_init_unchained(_newName, _newSymbol);
        __ERC20Permit_init(_newName);
        availableGetters = _availableGetters;

        emit BridgeInitialize(originToken, _newName, _newSymbol, decimals_);
    }

    /// @inheritdoc IBridgedStandardToken
    function bridgeMint(address _to, uint256 _amount) external override onlyNTV {
        _mint(_to, _amount);
        emit BridgeMint(_to, _amount);
    }

    /// @inheritdoc IBridgedStandardToken
    function bridgeBurn(address _from, uint256 _amount) external override onlyNTV {
        _burn(_from, _amount);
        emit BridgeBurn(_from, _amount);
    }

    /// @notice Decodes a string from ABI-encoded bytes.
    /// @param _input The ABI-encoded bytes containing a string.
    /// @return result The decoded string.
    function decodeString(bytes calldata _input) external pure returns (string memory result) {
        (result) = abi.decode(_input, (string));
    }

    /// @notice Decodes a uint8 from ABI-encoded bytes.
    /// @param _input The ABI-encoded bytes containing a uint8.
    /// @return result The decoded uint8 value.
    function decodeUint8(bytes calldata _input) external pure returns (uint8 result) {
        (result) = abi.decode(_input, (uint8));
    }

    /// @notice Returns the token name, reverts if name getter is disabled.
    /// @return The token name string.
    function name() public view override returns (string memory) {
        // If method is not available, behave like a token that does not implement this method - revert on call.
        // solhint-disable-next-line reason-string, gas-custom-errors
        if (availableGetters.ignoreName) revert();
        return super.name();
    }

    /// @notice Returns the token symbol, reverts if symbol getter is disabled.
    /// @return The token symbol string.
    function symbol() public view override returns (string memory) {
        // If method is not available, behave like a token that does not implement this method - revert on call.
        // solhint-disable-next-line reason-string, gas-custom-errors
        if (availableGetters.ignoreSymbol) revert();
        return super.symbol();
    }

    /// @notice Returns the token decimals, reverts if decimals getter is disabled.
    /// @return The number of decimals for the token.
    function decimals() public view override returns (uint8) {
        // If method is not available, behave like a token that does not implement this method - revert on call.
        // solhint-disable-next-line reason-string, gas-custom-errors
        if (availableGetters.ignoreDecimals) revert();
        return decimals_;
    }
}
