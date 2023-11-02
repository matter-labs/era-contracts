// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IAllowList {
    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Access mode of target contract is changed
    event UpdateAccessMode(address indexed target, AccessMode previousMode, AccessMode newMode);

    /// @notice Permission to call is changed
    event UpdateCallPermission(address indexed caller, address indexed target, bytes4 indexed functionSig, bool status);

    /// @notice Type of access to a specific contract includes three different modes
    /// @param Closed No one has access to the contract
    /// @param SpecialAccessOnly Any address with granted special access can interact with a contract (see `hasSpecialAccessToCall`)
    /// @param Public Everyone can interact with a contract
    enum AccessMode {
        Closed,
        SpecialAccessOnly,
        Public
    }

    /// @dev A struct that contains deposit limit data of a token
    /// @param depositLimitation Whether any deposit limitation is placed or not
    /// @param depositCap The maximum amount that can be deposited.
    struct Deposit {
        bool depositLimitation;
        uint256 depositCap;
    }

    /*//////////////////////////////////////////////////////////////
                            GETTERS
    //////////////////////////////////////////////////////////////*/

    function getAccessMode(address _target) external view returns (AccessMode);

    function hasSpecialAccessToCall(address _caller, address _target, bytes4 _functionSig) external view returns (bool);

    function canCall(address _caller, address _target, bytes4 _functionSig) external view returns (bool);

    function getTokenDepositLimitData(address _l1Token) external view returns (Deposit memory);

    /*//////////////////////////////////////////////////////////////
                           ALLOW LIST LOGIC
    //////////////////////////////////////////////////////////////*/

    function setBatchAccessMode(address[] calldata _targets, AccessMode[] calldata _accessMode) external;

    function setAccessMode(address _target, AccessMode _accessMode) external;

    function setBatchPermissionToCall(
        address[] calldata _callers,
        address[] calldata _targets,
        bytes4[] calldata _functionSigs,
        bool[] calldata _enables
    ) external;

    function setPermissionToCall(address _caller, address _target, bytes4 _functionSig, bool _enable) external;

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    function setDepositLimit(address _l1Token, bool _depositLimitation, uint256 _depositCap) external;
}
