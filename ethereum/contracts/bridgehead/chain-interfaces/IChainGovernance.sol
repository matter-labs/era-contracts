// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
import "./IChainBase.sol";

interface IChainGovernance is IChainBase {
    function setPendingGovernor(address _newPendingGovernor) external;

    function acceptGovernor() external;

    function setAllowList(IAllowList _newAllowList) external;

    /// @notice pendingGovernor is changed
    /// @dev Also emitted when new governor is accepted and in this case, `newPendingGovernor` would be zero address
    event NewPendingGovernor(address indexed oldPendingGovernor, address indexed newPendingGovernor);

    /// @notice Governor changed
    event NewGovernor(address indexed oldGovernor, address indexed newGovernor);

    /// @notice Allow list address changed
    event NewAllowList(address indexed oldAllowList, address indexed newAllowList);
}
