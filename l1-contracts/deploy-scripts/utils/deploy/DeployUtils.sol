// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Create2FactoryUtils} from "./Create2FactoryUtils.s.sol";
import {ContractsBytecodesLib} from "../bytecode/ContractsBytecodesLib.sol";
import {MemberDeployment, MemberDeploymentsRecord} from "../MemberDeploymentsRecord.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

abstract contract DeployUtils is Create2FactoryUtils {
    /// @notice Every contract this run deployed (or found already deployed) through
    ///         {deploySimpleContract} or as a {deployTuppWithContractAndProxyAdmin} implementation, in
    ///         order: what an upgrade prepare records as `[member_deployments]` (see
    ///         {MemberDeploymentsRecord}).
    MemberDeployment[] internal memberDeployments;

    /// @dev Whether {memberDeployments} already holds an address.
    mapping(address deployed => bool recorded) internal memberDeploymentRecorded;

    function deployTuppWithContract(string memory contractName) public returns (address implementation, address proxy) {
        (implementation, proxy) = deployTuppWithContractAndProxyAdmin(contractName, transparentProxyAdmin());
    }

    function deployTuppWithContractAndProxyAdmin(
        string memory contractName,
        address proxyAdmin
    ) public returns (address implementation, address proxy) {
        bytes memory constructorArgs = getCreationCalldata(contractName);
        implementation = deployViaCreate2AndNotify(
            getCreationCode(contractName),
            constructorArgs,
            contractName,
            string.concat(contractName, " Implementation")
        );
        _recordMemberDeployment(implementation, contractName, constructorArgs);

        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, proxyAdmin, getInitializeCalldata(contractName)),
            "TransparentUpgradeableProxy",
            string.concat(contractName, " Proxy")
        );
        return (implementation, proxy);
    }

    /// @notice Creation code for `contractName`, read from `l1-contracts/out/`. Deployers that
    /// read from elsewhere override this.
    function getCreationCode(string memory contractName) internal view virtual returns (bytes memory) {
        return ContractsBytecodesLib.getCreationCodeEVM(contractName);
    }

    function getCreationCalldata(string memory contractName) internal view virtual returns (bytes memory);

    function getInitializeCalldata(string memory contractName) internal virtual returns (bytes memory);

    function transparentProxyAdmin() internal virtual returns (address);

    function deploySimpleContract(string memory contractName) public returns (address contractAddress) {
        bytes memory constructorArgs = getCreationCalldata(contractName);
        contractAddress = deployViaCreate2AndNotify(getCreationCode(contractName), constructorArgs, contractName);
        _recordMemberDeployment(contractAddress, contractName, constructorArgs);
    }

    /// @notice Sets the `root` serialization object's `member_deployments` to {memberDeployments}.
    /// @dev Called before every write of an upgrade prepare's output: `root` is as process-global as
    ///      the record's own object (see {MemberDeploymentsRecord.serialize}).
    function serializeMemberDeployments() internal {
        vm.serializeString(
            "root",
            MemberDeploymentsRecord.RECORD_KEY,
            MemberDeploymentsRecord.serialize(memberDeployments)
        );
    }

    /// @notice Adds a CREATE2 deployment of the run to {memberDeployments}, once per address.
    /// @param _deployed Where it landed.
    /// @param _contractName The artifact contract name its creation code was read from.
    /// @param _constructorArgs The bytes appended to its creation code.
    function _recordMemberDeployment(
        address _deployed,
        string memory _contractName,
        bytes memory _constructorArgs
    ) internal {
        if (memberDeploymentRecorded[_deployed]) {
            return;
        }
        memberDeploymentRecorded[_deployed] = true;
        (address factory, bytes32 salt) = getCreate2FactoryParams();
        memberDeployments.push(
            MemberDeployment({
                deployed: _deployed,
                contractName: _contractName,
                create2Factory: factory,
                create2Salt: salt,
                constructorArgs: _constructorArgs
            })
        );
    }

    /// @notice {deployWithCreate2AndOwner} under a domain-separated salt (see
    ///         {create2WithDeterministicOwner}).
    /// @param contractName The contract to deploy.
    /// @param owner Its owner.
    /// @param _saltDomain The domain separating it from same-code, same-owner deployments of the run.
    /// @return contractAddress The deployed contract address.
    function deployWithCreate2AndOwner(
        string memory contractName,
        address owner,
        bytes32 _saltDomain
    ) public returns (address contractAddress) {
        bytes memory constructorParams = getCreationCalldata(contractName);
        contractAddress = create2WithDeterministicOwner(
            abi.encodePacked(getCreationCode(contractName), constructorParams),
            owner,
            _saltDomain
        );
        notifyAboutDeployment(contractAddress, contractName, constructorParams, contractName);
    }

    function deployWithCreate2AndOwner(
        string memory contractName,
        address owner
    ) public returns (address contractAddress) {
        contractAddress = deployWithOwnerAndNotify({
            initCode: getCreationCode(contractName),
            constructorParams: getCreationCalldata(contractName),
            owner: owner,
            contractName: contractName,
            displayName: string.concat(contractName, " Implementation")
        });
    }
}
