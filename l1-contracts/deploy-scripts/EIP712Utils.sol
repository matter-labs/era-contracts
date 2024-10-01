// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

library EIP712Utils {
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function buildDomainHash(
        address _verifyingContract,
        string memory _name,
        string memory _version
    ) internal view returns (bytes32) {
        return
            keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encode(
                    TYPE_HASH,
                    keccak256(bytes(_name)),
                    keccak256(bytes(_version)),
                    block.chainid,
                    _verifyingContract
                )
            );
    }

    function buildDigest(bytes32 _domainHash, bytes32 _message) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainHash, _message));
    }
}
