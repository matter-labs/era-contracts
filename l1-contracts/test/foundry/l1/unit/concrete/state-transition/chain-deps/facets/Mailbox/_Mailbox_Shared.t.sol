// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {Utils as UnitUtils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";

import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

contract MailboxTest is MigrationTestBase {
    IMailbox internal mailboxFacet;
    IGetters internal gettersFacet;
    address sender;
    uint256 constant eraChainId = 9;
    address internal testnetVerifier;
    address diamondProxy;
    address bridgehub;
    address chainAssetHandler;
    address interopCenter;
    IEIP7702Checker eip7702Checker;
    L1ChainAssetHandler realChainAssetHandler;

    /// @dev MigrationTestBase.setUp() deploys the full ecosystem.
    /// This override adds Mailbox-specific bindings on top.
    function setUp() public virtual override {
        super.setUp();
        setupDiamondProxy();
    }

    /// @dev Binds Mailbox-specific variables to the deployed integration chain.
    /// Kept as a separate function so child tests that need custom setup can call it.
    function setupDiamondProxy() public {
        mailboxFacet = IMailbox(chainAddress);
        gettersFacet = IGetters(chainAddress);

        sender = makeAddr("sender");
        vm.deal(sender, 100 ether);
        diamondProxy = chainAddress;
        bridgehub = address(addresses.bridgehub);
        chainAssetHandler = address(IBridgehubBase(bridgehub).chainAssetHandler());
        realChainAssetHandler = L1ChainAssetHandler(chainAssetHandler);

        eip7702Checker = IEIP7702Checker(UnitUtils.deployEIP7702Checker());
    }

    /// @notice Deploys an additional ZK chain (for tests that need a second diamond proxy)
    /// Virtual so ProvingL2LogsInclusion can override with bare diamond for proof tests.
    function deployDiamondProxy() internal virtual returns (address proxy) {
        _deployZKChain(ETH_TOKEN_ADDRESS);
        uint256 newChainId = zkChainIds[zkChainIds.length - 1];
        proxy = getZKChainAddress(newChainId);
        _addUtilsFacet(proxy);
    }

    // Exclude from coverage
    function testMailboxShared() internal virtual {}
}
