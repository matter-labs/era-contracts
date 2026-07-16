// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1EcosystemContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/ICoreRegistry.sol";

/// @dev Mutable core-registry double for unit fixtures with dynamic deployment addresses.
contract TestCoreRegistry is ICoreRegistry {
    uint256 internal oldVersion;
    uint256 internal newVersion;
    address internal proxyAdminAddress;
    L1EcosystemContract[] internal contractList;
    mapping(L1EcosystemContract contractId => address proxy) internal proxies;
    mapping(L1EcosystemContract contractId => address impl) internal newImpls;

    function setVersions(uint256 _oldVersion, uint256 _newVersion) external {
        oldVersion = _oldVersion;
        newVersion = _newVersion;
    }

    function setProxyAdmin(address _proxyAdmin) external {
        proxyAdminAddress = _proxyAdmin;
    }

    function addContract(L1EcosystemContract _contract, address _proxy, address _implNew) external {
        contractList.push(_contract);
        proxies[_contract] = _proxy;
        newImpls[_contract] = _implNew;
    }

    function oldProtocolVersion() external view returns (uint256) {
        return oldVersion;
    }

    function newProtocolVersion() external view returns (uint256) {
        return newVersion;
    }

    function proxyAddress(L1EcosystemContract _contract) external view returns (address) {
        return proxies[_contract];
    }

    function implAddress(L1EcosystemContract _contract) external view returns (address) {
        return newImpls[_contract];
    }

    function ecosystemContractList() external view returns (L1EcosystemContract[] memory) {
        return contractList;
    }

    function proxyAdmin() external view returns (address) {
        return proxyAdminAddress;
    }

    function verifyAll() external pure returns (bool) {
        return true;
    }

    function validate() external pure {}
}
