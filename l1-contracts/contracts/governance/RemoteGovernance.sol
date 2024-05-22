// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IRemoteGovernance} from "./IRemoteGovernance.sol";
import {IBridgehub, L2TransactionRequestDirect} from "../bridgehub/Bridgehub.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Contract design is inspired by OpenZeppelin TimelockController and in-house Diamond Proxy upgrade mechanism.
/// @notice This contract manages operations (calls with preconditions) for governance tasks.
/// The contract allows for operations to be scheduled, executed, and canceled with
/// appropriate permissions and delays. It is used for managing and coordinating upgrades
/// and changes in all zkSync hyperchain governed contracts.
///
/// Operations can be proposed as either fully transparent upgrades with on-chain data,
/// or "shadow" upgrades where upgrade data is not published on-chain before execution. Proposed operations
/// are subject to a delay before they can be executed, but they can be executed instantly
/// with the security council’s permission.
contract RemoteGovernance is IRemoteGovernance, ReentrancyGuard, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    address public immutable GOVERNANCE;

    IBridgehub public immutable BRIDGEHUB;

    address public immutable SHARED_BRIDGE;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _governance, IBridgehub _bridgehub, address _sharedBridge) reentrancyGuardInitializer {
        GOVERNANCE = _governance;
        BRIDGEHUB = _bridgehub;
        SHARED_BRIDGE = _sharedBridge;
        _disableInitializers();
    }

    /// @notice Executes a governance operation.
    function requestL2TransactionDirect(L2TransactionRequestDirect memory _request) external payable override {
        require(msg.sender == GOVERNANCE, "RG: Not governance");
        IERC20 baseToken = IERC20(BRIDGEHUB.baseToken(_request.chainId));
        if (address(baseToken) != ETH_TOKEN_ADDRESS) {
            baseToken.forceApprove(SHARED_BRIDGE, _request.mintValue); // Approve the base token for the bridge
        }
        BRIDGEHUB.requestL2TransactionDirect{value: msg.value}(_request);
    }
}
