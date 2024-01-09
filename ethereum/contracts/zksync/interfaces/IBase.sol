// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

interface IBase {
    /// @return Returns facet name.
    function getName() external view returns (string memory);
}
