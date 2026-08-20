// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Create2FactoryUtils} from "./Create2FactoryUtils.s.sol";
import {ContractsBytecodesLib} from "../bytecode/ContractsBytecodesLib.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

abstract contract DeployUtils is Create2FactoryUtils {
    function deployTuppWithContract(string memory contractName) public returns (address implementation, address proxy) {
        (implementation, proxy) = deployTuppWithContractAndProxyAdmin(contractName, transparentProxyAdmin());
    }

    function deployTuppWithContractAndProxyAdmin(
        string memory contractName,
        address proxyAdmin
    ) public returns (address implementation, address proxy) {
        implementation = deployViaCreate2AndNotify(
            getCreationCode(contractName),
            getCreationCalldata(contractName),
            contractName,
            string.concat(contractName, " Implementation")
        );

        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, proxyAdmin, getInitializeCalldata(contractName)),
            "TransparentUpgradeableProxy",
            string.concat(contractName, " Proxy")
        );
        return (implementation, proxy);
    }

    /// @notice Creation code for `contractName`, read from `l1-contracts/out/`. Deployers that
    /// read from elsewhere (e.g. the Gateway upgrade, which resolves GW artifacts) override this.
    function getCreationCode(string memory contractName) internal view virtual returns (bytes memory) {
        return ContractsBytecodesLib.getCreationCodeEVM(contractName);
    }

    function getCreationCalldata(string memory contractName) internal view virtual returns (bytes memory);

    function getInitializeCalldata(string memory contractName) internal virtual returns (bytes memory);

    function transparentProxyAdmin() internal virtual returns (address);

    function deploySimpleContract(string memory contractName) public returns (address contractAddress) {
        contractAddress = deployViaCreate2AndNotify(
            getCreationCode(contractName),
            getCreationCalldata(contractName),
            contractName
        );
    }

    function deployWithCreate2AndOwner(
        string memory contractName,
        address owner
    ) public returns (address contractAddress) {
        contractAddress = deployWithOwnerAndNotify(
            getCreationCode(contractName),
            getCreationCalldata(contractName),
            owner,
            contractName,
            string.concat(contractName, " Implementation")
        );
    }
}
