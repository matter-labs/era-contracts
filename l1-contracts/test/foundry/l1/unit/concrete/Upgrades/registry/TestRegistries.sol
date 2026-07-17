// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1EcosystemContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ICoreRegistry, EcosystemContractRow} from "contracts/upgrades/registry/ICoreRegistry.sol";

/// @dev Mutable core-registry double for unit fixtures with dynamic deployment addresses.
///      Rows are source-checked edges, mirroring the production `EcosystemContractRow`.
contract TestCoreRegistry is ICoreRegistry {
    EcosystemContractRow[] internal rows_;

    function addContract(
        L1EcosystemContract _contract,
        address _proxy,
        address _expectedOldImpl,
        address _implNew
    ) external {
        rows_.push(
            EcosystemContractRow({
                key: _contract,
                proxy: _proxy,
                expectedOldImpl: _expectedOldImpl,
                implNew: _implNew,
                implNewCodehash: _implNew.codehash
            })
        );
    }

    function ecosystemRows() external view returns (EcosystemContractRow[] memory) {
        return rows_;
    }

    function verifyAll() external pure returns (bool) {
        return true;
    }

    function validate() external pure {}
}
