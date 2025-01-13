// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// 0x86bb51b8
error AddressHasNoCode(address);
// 0x07637bd8
error MintFailed();
// 0xbd13da86
error ProxyAdminIncorrect(address expectedProxyAdmin, address proxyAdmin);
// 0x565fae63
error ProxyAdminIncorrectOwner(address proxyAdmin, address governance);

enum ZksyncContract {
    Create2Factory,
    DiamondProxy,
    BaseToken
}
