// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Create2FactoryUtils} from "./Create2FactoryUtils.s.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

abstract contract DeployUtils is Create2FactoryUtils {
    // FIXME: isZKBytecode is never true except for tests where it ends up being ignored anyway.
    function deployTuppWithContract(
        string memory contractName,
        bool isZKBytecode
    ) public returns (address implementation, address proxy) {
        (implementation, proxy) = deployTuppWithContractAndProxyAdmin(
            contractName,
            transparentProxyAdmin(),
            isZKBytecode
        );
    }

    // FIXME: isZKBytecode is never true except for tests where it ends up being ignored anyway.
    function deployTuppWithContractAndProxyAdmin(
        string memory contractName,
        address proxyAdmin,
        bool isZKBytecode
    ) public returns (address implementation, address proxy) {
        implementation = deployViaCreate2AndNotify(
            getCreationCode(contractName, false),
            getCreationCalldata(contractName, false),
            contractName,
            string.concat(contractName, " Implementation"),
            isZKBytecode
        );

        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, proxyAdmin, getInitializeCalldata(contractName, false)),
            contractName,
            string.concat(contractName, " Proxy"),
            isZKBytecode
        );
        return (implementation, proxy);
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual returns (bytes memory);

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual returns (bytes memory);

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual returns (bytes memory);

    function transparentProxyAdmin() internal virtual returns (address);

    // FIXME: isZKBytecode is never true except for tests where it ends up being ignored anyway.
    function deploySimpleContract(
        string memory contractName,
        bool isZKBytecode
    ) public returns (address contractAddress) {
        contractAddress = deployViaCreate2AndNotify(
            getCreationCode(contractName, false),
            getCreationCalldata(contractName, false),
            contractName,
            isZKBytecode
        );
    }

    function deployWithCreate2AndOwner(
        string memory contractName,
        address owner,
        bool isZKBytecode
    ) public returns (address contractAddress) {
        contractAddress = deployWithOwnerAndNotify(
            getCreationCode(contractName, false),
            getCreationCalldata(contractName, false),
            owner,
            contractName,
            string.concat(contractName, " Implementation"),
            isZKBytecode
        );
    }
}
