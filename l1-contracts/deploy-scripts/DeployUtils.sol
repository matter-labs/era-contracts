// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Create2FactoryUtils} from "./Create2FactoryUtils.s.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

// solhint-disable-next-line gas-struct-packing
struct L1NativeTokenVaultAddresses {
    address l1NativeTokenVaultImplementation;
    address l1NativeTokenVaultProxy;
}

abstract contract DeployUtils is Create2FactoryUtils {
    function deployTuppWithContract(
        string memory contractName,
        bool isZKBytecode
    ) internal returns (address implementation, address proxy) {
        (implementation, proxy) = deployTuppWithContractAndProxyAdmin(
            contractName,
            transparentProxyAdmin(),
            isZKBytecode
        );
    }

    function deployTuppWithContractAndProxyAdmin(
        string memory contractName,
        address proxyAdmin,
        bool isZKBytecode
    ) internal returns (address implementation, address proxy) {
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

    function deploySimpleContract(
        string memory contractName,
        bool isZKBytecode
    ) internal returns (address contractAddress) {
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
    ) internal returns (address contractAddress) {
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
