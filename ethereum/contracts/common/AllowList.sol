// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./interfaces/IAllowList.sol";
import "./libraries/UncheckedMath.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The smart contract that stores the permissions to call the function on different contracts.
/// @dev The contract is fully controlled by the owner, that can grant and revoke any permissions at any time.
/// @dev The permission list has three different modes:
/// - Closed. The contract cannot be called by anyone.
/// - SpecialAccessOnly. Only some contract functions can be called by specifically granted addresses.
/// - Public. Access list to call any function from the target contract by any caller
contract AllowList is IAllowList, Ownable2Step {
    using UncheckedMath for uint256;

    /// @notice The Access mode by which it is decided whether the caller has access
    mapping(address => AccessMode) public getAccessMode;

    /// @notice The mapping that stores permissions to call the function on the target address by the caller
    /// @dev caller => target => function signature => permission to call target function for the given caller address
    mapping(address => mapping(address => mapping(bytes4 => bool))) public hasSpecialAccessToCall;

    /// @dev The mapping L1 token address => struct Deposit
    mapping(address => Deposit) public tokenDeposit;

    constructor(address _initialOwner) {
        _transferOwnership(_initialOwner);
    }

    /// @return Whether the caller can call the specific function on the target contract
    /// @param _caller The caller address, who is granted access
    /// @param _target The address of the smart contract which is called
    /// @param _functionSig The function signature (selector), access to which need to check
    function canCall(address _caller, address _target, bytes4 _functionSig) external view returns (bool) {
        AccessMode accessMode = getAccessMode[_target];
        return
            accessMode == AccessMode.Public ||
            (accessMode == AccessMode.SpecialAccessOnly && hasSpecialAccessToCall[_caller][_target][_functionSig]);
    }

    /// @notice Set the permission mode to call the target contract
    /// @param _target The address of the smart contract, of which access to the call is to be changed
    /// @param _accessMode Whether no one, any or only some addresses can call the target contract
    function setAccessMode(address _target, AccessMode _accessMode) external onlyOwner {
        _setAccessMode(_target, _accessMode);
    }

    /// @notice Set many permission modes to call the target contracts
    /// @dev Analogous to function `setAccessMode` but performs a batch of changes
    /// @param _targets The array of smart contract addresses, of which access to the call is to be changed
    /// @param _accessModes The array of new permission modes, whether no one, any or only some addresses can call the
    /// target contract
    function setBatchAccessMode(address[] calldata _targets, AccessMode[] calldata _accessModes) external onlyOwner {
        uint256 targetsLength = _targets.length;
        require(targetsLength == _accessModes.length, "yg"); // The size of arrays should be equal

        for (uint256 i = 0; i < targetsLength; i = i.uncheckedInc()) {
            _setAccessMode(_targets[i], _accessModes[i]);
        }
    }

    /// @dev Changes access mode and emit the event if the access was changed
    function _setAccessMode(address _target, AccessMode _accessMode) internal {
        AccessMode accessMode = getAccessMode[_target];

        if (accessMode != _accessMode) {
            getAccessMode[_target] = _accessMode;
            emit UpdateAccessMode(_target, accessMode, _accessMode);
        }
    }

    /// @notice Set many permissions to call the function on the contract to the specified caller address
    /// @param _callers The array of caller addresses, who are granted access
    /// @param _targets The array of smart contract addresses, of which access to the call are to be changed
    /// @param _functionSigs The array of function signatures (selectors), access to which need to be changed
    /// @param _enables The array of boolean flags, whether enable or disable the function access to the corresponding
    /// target address
    function setBatchPermissionToCall(
        address[] calldata _callers,
        address[] calldata _targets,
        bytes4[] calldata _functionSigs,
        bool[] calldata _enables
    ) external onlyOwner {
        uint256 callersLength = _callers.length;

        // The size of arrays should be equal
        require(callersLength == _targets.length, "yw");
        require(callersLength == _functionSigs.length, "yx");
        require(callersLength == _enables.length, "yy");

        for (uint256 i = 0; i < callersLength; i = i.uncheckedInc()) {
            _setPermissionToCall(_callers[i], _targets[i], _functionSigs[i], _enables[i]);
        }
    }

    /// @notice Set the permission to call the function on the contract to the specified caller address
    /// @param _caller The caller address, who is granted access
    /// @param _target The address of the smart contract, of which access to the call is to be changed
    /// @param _functionSig The function signature (selector), access to which need to be changed
    /// @param _enable Whether enable or disable the permission
    function setPermissionToCall(
        address _caller,
        address _target,
        bytes4 _functionSig,
        bool _enable
    ) external onlyOwner {
        _setPermissionToCall(_caller, _target, _functionSig, _enable);
    }

    /// @dev Changes permission to call and emits the event if the permission was changed
    function _setPermissionToCall(address _caller, address _target, bytes4 _functionSig, bool _enable) internal {
        bool currentPermission = hasSpecialAccessToCall[_caller][_target][_functionSig];

        if (currentPermission != _enable) {
            hasSpecialAccessToCall[_caller][_target][_functionSig] = _enable;
            emit UpdateCallPermission(_caller, _target, _functionSig, _enable);
        }
    }

    /// @dev Set deposit limit data for a token
    /// @param _l1Token The address of L1 token
    /// @param _depositLimitation deposit limitation is active or not
    /// @param _depositCap The maximum amount that can be deposited.
    function setDepositLimit(address _l1Token, bool _depositLimitation, uint256 _depositCap) external onlyOwner {
        tokenDeposit[_l1Token].depositLimitation = _depositLimitation;
        tokenDeposit[_l1Token].depositCap = _depositCap;
    }

    /// @dev Get deposit limit data of a token
    /// @param _l1Token The address of L1 token
    function getTokenDepositLimitData(address _l1Token) external view returns (Deposit memory) {
        return tokenDeposit[_l1Token];
    }
}
