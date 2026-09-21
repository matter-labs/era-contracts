// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title MockContractDeployer
/// @notice EVM test adapter for Era force deployments, which Anvil cannot execute natively.
/// @dev Most bytecodes are installed by the harness before the transaction. Deferred deployments
/// use a proxy implementation switch to preserve the production ordering and target storage.
contract MockContractDeployer {
    mapping(address target => address implementation) public deferredImplementations;

    function registerDeferredDeployment(address _target, address _implementation) external {
        deferredImplementations[_target] = _implementation;
    }

    function forceDeployOnAddresses(IL2ContractDeployer.ForceDeployment[] calldata _deployments) external payable {
        for (uint256 i; i < _deployments.length; ++i) {
            address implementation = deferredImplementations[_deployments[i].newAddress];
            if (implementation != address(0)) {
                ITransparentUpgradeableProxy(_deployments[i].newAddress).upgradeTo(implementation);
            }
        }
    }

    // Other VM-specific deployment calls are supplied by the harness ahead of time.
    fallback() external payable {}

    receive() external payable {}
}

/// @notice Legacy immutable getter fixture for synthetic Anvil states that omit constructor data.
/// @dev Deployed normally on the EVM test chain; only the old getter is exercised before replacement.
contract MockLegacyNtvWeth {
    address public immutable WETH_TOKEN;

    constructor(address _wethToken) {
        WETH_TOKEN = _wethToken;
    }
}
