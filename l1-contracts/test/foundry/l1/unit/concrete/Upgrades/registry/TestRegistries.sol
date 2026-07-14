// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    L2EcosystemContract,
    CTMContract,
    L1EcosystemContract
} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/ICoreRegistry.sol";
import {ICTMRegistry} from "contracts/upgrades/registry/ICTMRegistry.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

/// @dev Storage-backed ICoreRegistry test double. Production registries are generated
///      constants-in-bytecode contracts; these mocks exist only because unit-test fixtures
///      deploy at dynamic addresses that cannot be pinned as compile-time constants.
contract TestCoreRegistry is ICoreRegistry {
    uint256 internal oldVersion;
    uint256 internal newVersion;
    address internal proxyAdminAddress;
    address internal eraCTMRegistry;
    address internal zksyncOSCTMRegistry;
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

    function setCTMRegistry(bool _isZKsyncOS, address _registry) external {
        if (_isZKsyncOS) {
            zksyncOSCTMRegistry = _registry;
        } else {
            eraCTMRegistry = _registry;
        }
    }

    /// @dev A zero `_implNew` pins "no new implementation" (the module skips the contract).
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

    function ctmRegistry(bool _isZKsyncOS) external view returns (address) {
        return _isZKsyncOS ? zksyncOSCTMRegistry : eraCTMRegistry;
    }

    function verifyAll() external pure returns (bool) {
        return true;
    }
}

/// @dev Storage-backed ICTMRegistry test double; see `TestCoreRegistry`.
contract TestCTMRegistry is ICTMRegistry {
    bool internal zksyncOS;
    uint256 internal oldVersion;
    uint256 internal newVersion;
    address internal ctmProxyAddress;
    mapping(uint256 protocolVersion => mapping(CTMContract contractId => address addr)) internal addresses;
    mapping(uint256 protocolVersion => address verifierAddress) internal verifiers;
    mapping(uint256 protocolVersion => CTMContract[] facets) internal facets;
    mapping(uint256 protocolVersion => mapping(CTMContract facet => bytes4[] selectors)) internal selectors;
    mapping(CTMContract facet => bool freezable) internal freezable;
    L2EcosystemContract[] internal deployList;
    mapping(L2EcosystemContract contractId => IComplexUpgrader.UniversalContractUpgradeInfo info) internal deployments;
    mapping(L2EcosystemContract contractId => bytes32 hash) internal l2Hashes;
    address internal delegateToAddress;
    bytes internal delegateCalldataBytes;
    uint256[] internal factoryDeps;
    bytes32 internal bootloaderHash;
    bytes32 internal defaultAccountHash;
    bytes32 internal evmEmulatorHash;
    bytes internal fixedFDD;
    address internal genesisUpgradeAddress;
    bytes32 internal genesisBatchHashValue;
    bytes32 internal genesisBatchCommitmentValue;
    uint64 internal genesisIndexValue;

    function setBase(bool _isZKsyncOS, uint256 _oldVersion, uint256 _newVersion, address _ctmProxy) external {
        zksyncOS = _isZKsyncOS;
        oldVersion = _oldVersion;
        newVersion = _newVersion;
        ctmProxyAddress = _ctmProxy;
    }

    function setCtmAddress(CTMContract _contract, uint256 _protocolVersion, address _addr) external {
        addresses[_protocolVersion][_contract] = _addr;
    }

    function setVerifier(uint256 _protocolVersion, address _verifier) external {
        verifiers[_protocolVersion] = _verifier;
    }

    /// @dev Adds a facet row: old-version rows form the upgrade plan (`_facetAddress` zero =
    ///      pure addition), new-version rows the post-upgrade facet set. The facet's address
    ///      resolves through `ctmAddress`, mirroring the production base.
    function addFacet(
        uint256 _protocolVersion,
        CTMContract _facet,
        address _facetAddress,
        bytes4[] calldata _selectors
    ) external {
        facets[_protocolVersion].push(_facet);
        addresses[_protocolVersion][_facet] = _facetAddress;
        selectors[_protocolVersion][_facet] = _selectors;
    }

    function setFreezable(CTMContract _facet, bool _isFreezable) external {
        freezable[_facet] = _isFreezable;
    }

    function addL2ForceDeployment(
        L2EcosystemContract _contract,
        IComplexUpgrader.UniversalContractUpgradeInfo calldata _info,
        bytes32 _bytecodeHash
    ) external {
        deployList.push(_contract);
        deployments[_contract] = _info;
        l2Hashes[_contract] = _bytecodeHash;
    }

    function setL2UpgradeDelegate(address _delegateTo, bytes calldata _calldata) external {
        delegateToAddress = _delegateTo;
        delegateCalldataBytes = _calldata;
    }

    function setFactoryDepHashes(uint256[] calldata _hashes) external {
        factoryDeps = _hashes;
    }

    function setBaseSystemContractHashes(bytes32 _bootloader, bytes32 _defaultAccount, bytes32 _evmEmulator) external {
        bootloaderHash = _bootloader;
        defaultAccountHash = _defaultAccount;
        evmEmulatorHash = _evmEmulator;
    }

    function setChainCreationData(bytes calldata _fixedFDD) external {
        fixedFDD = _fixedFDD;
    }

    function setGenesis(address _genesisUpgrade, bytes32 _batchHash, bytes32 _commitment, uint64 _index) external {
        genesisUpgradeAddress = _genesisUpgrade;
        genesisBatchHashValue = _batchHash;
        genesisBatchCommitmentValue = _commitment;
        genesisIndexValue = _index;
    }

    function isZKsyncOS() external view returns (bool) {
        return zksyncOS;
    }

    function oldProtocolVersion() external view returns (uint256) {
        return oldVersion;
    }

    function newProtocolVersion() external view returns (uint256) {
        return newVersion;
    }

    function ctmProxy() external view returns (address) {
        return ctmProxyAddress;
    }

    function ctmAddress(CTMContract _contract, uint256 _protocolVersion) external view returns (address) {
        return addresses[_protocolVersion][_contract];
    }

    function verifier(uint256 _protocolVersion) external view returns (address) {
        return verifiers[_protocolVersion];
    }

    function facetList(uint256 _protocolVersion) external view returns (CTMContract[] memory) {
        return facets[_protocolVersion];
    }

    function facetSelectors(CTMContract _facet, uint256 _protocolVersion) external view returns (bytes4[] memory) {
        return selectors[_protocolVersion][_facet];
    }

    function facetIsFreezable(CTMContract _facet) external view returns (bool) {
        return freezable[_facet];
    }

    function l2ForceDeployList(uint256) external view returns (L2EcosystemContract[] memory) {
        return deployList;
    }

    function l2ForceDeployment(
        L2EcosystemContract _contract,
        uint256
    ) external view returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        return deployments[_contract];
    }

    function l2BytecodeHash(L2EcosystemContract _contract, uint256) external view returns (bytes32) {
        return l2Hashes[_contract];
    }

    function l2UpgradeDelegate(uint256) external view returns (address, bytes memory) {
        return (delegateToAddress, delegateCalldataBytes);
    }

    function factoryDepHashes(uint256) external view returns (uint256[] memory) {
        return factoryDeps;
    }

    function baseSystemContractHashes(uint256) external view returns (bytes32, bytes32, bytes32) {
        return (bootloaderHash, defaultAccountHash, evmEmulatorHash);
    }

    function fixedForceDeploymentsData(uint256) external view returns (bytes memory) {
        return fixedFDD;
    }

    function genesisParams(uint256) external view returns (address, bytes32, bytes32, uint64) {
        return (genesisUpgradeAddress, genesisBatchHashValue, genesisBatchCommitmentValue, genesisIndexValue);
    }

    function verifyAll() external pure returns (bool) {
        return true;
    }
}
