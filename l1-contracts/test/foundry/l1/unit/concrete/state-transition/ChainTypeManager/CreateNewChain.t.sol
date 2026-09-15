// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL1GenesisUpgrade} from "contracts/upgrades/IL1GenesisUpgrade.sol";
import {PreviousUpgradeNotFinalized} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    IL2GenesisUpgrade,
    ZKChainSpecificForceDeploymentsData
} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract createNewChainTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    // Note: the old `HashMismatch`-on-passed-cut test is gone: from v32 the CTM builds the genesis
    // cut itself from its registry, so `createNewChain` no longer accepts (or validates) a cut.

    function test_RevertWhen_CalledNotByBridgehub() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governor));
        chainContractAddress.createNewChain({_chainId: chainId, _admin: admin});
    }

    function test_SuccessfulCreationOfNewChain() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));

        address admin = IZKChain(newChainAddress).getAdmin();

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));
    }

    function test_SuccessfulCreationOfNewChainAndReturnChainId() public {
        createNewChain(getDiamondCutData(diamondInit));

        uint256[] memory mockData = new uint256[](1);
        mockData[0] = chainId;

        vm.mockCall(address(bridgehub), abi.encodeCall(IBridgehubBase.getAllZKChainChainIDs, ()), abi.encode(mockData));
        uint256[] memory chainIds = _getAllZKChainIDs();

        assertEq(chainIds.length, 1);
        assertEq(chainIds[0], chainId);
    }

    /// @notice The whole creation path end to end: the CTM deploys the diamond, `DiamondInit`
    ///         installs the release's chain state, and the genesis upgrade commits the L2
    ///         transaction the release composes for THIS chain — the same one its own composition
    ///         view serves.
    function test_createNewChain_reachesTheGenesisStateOfItsRelease() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));

        bytes32 expectedHash = keccak256(abi.encode(_expectedGenesisTx()));
        assertEq(IZKChain(newChainAddress).getChainId(), chainId, "the chain knows its own id");
        assertEq(IZKChain(newChainAddress).getAdmin(), newChainAdmin, "the requested admin is installed");
        assertEq(IZKChain(newChainAddress).getProtocolVersion(), 0, "the chain starts at the CTM's version");
        assertEq(IZKChain(newChainAddress).getVerifier(), testnetVerifier, "the verifier comes off the release");
        assertEq(
            IZKChain(newChainAddress).getL2SystemContractsUpgradeTxHash(),
            expectedHash,
            "the chain commits the genesis transaction its release composes"
        );
    }

    /// @notice The genesis transaction is not a fabricated payload: it carries the release's own
    ///         force-deployments blob and the chain's base-token registration, routed through the
    ///         `L2ComplexUpgrader` into the L2 genesis upgrade.
    function test_createNewChain_commitsTheGenesisCallOfItsRelease() public {
        createNewChain(getDiamondCutData(diamondInit));

        (address delegateTo, bytes memory genesisCalldata) = this.decodeComplexUpgraderUpgrade(
            _expectedGenesisTx().data
        );
        assertEq(delegateTo, L2_GENESIS_UPGRADE_ADDR, "genesis delegates to the L2 genesis upgrade");
        (uint256 composedChainId, , , bytes memory perChainData) = this.decodeGenesisUpgrade(genesisCalldata);
        assertEq(composedChainId, chainId, "the genesis call names this chain");

        ZKChainSpecificForceDeploymentsData memory data = abi.decode(
            perChainData,
            (ZKChainSpecificForceDeploymentsData)
        );
        assertEq(data.baseTokenL1Address, baseToken, "the chain's base token is recorded");
        assertEq(data.baseTokenMetadata.name, "TestToken", "the base token metadata is read from the token");
        assertEq(data.baseTokenMetadata.symbol, "TT");
        assertEq(data.baseTokenBridgingData.assetId, baseTokenAssetId, "the base token asset id is the chain's");
    }

    /// @notice Genesis runs once. Replaying it while the first genesis transaction is still
    ///         outstanding would overwrite it and let the chain skip the upgrade it encodes.
    function test_revertWhen_genesisUpgradeIsReplayedWhileItsTransactionIsPending() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));
        bytes32 pendingHash = IZKChain(newChainAddress).getL2SystemContractsUpgradeTxHash();
        assertTrue(pendingHash != bytes32(0), "the first genesis must have set a transaction");

        vm.prank(address(chainContractAddress));
        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotFinalized.selector, pendingHash));
        IAdmin(newChainAddress).genesisUpgrade();
    }

    /// @dev The composition view of the release's pinned genesis engine, called with the context
    ///      `DiamondInit` installs on the chain. It is the same construction the engine runs under
    ///      delegatecall, so equality with the committed hash is a real check of the flow.
    function _expectedGenesisTx() internal view returns (L2CanonicalTransaction memory) {
        return
            IL1GenesisUpgrade(address(genesisUpgradeContract)).genesisUpgradeTx({
                _release: Utils.TEST_GENESIS_REGISTRY,
                _bridgehub: address(bridgehub),
                _chainId: chainId,
                _protocolVersion: 0
            });
    }

    /// @dev Decodes an `IComplexUpgrader.upgrade` payload; external so the selector can be sliced.
    function decodeComplexUpgraderUpgrade(
        bytes calldata _data
    ) external pure returns (address delegateTo, bytes memory delegateCalldata) {
        require(bytes4(_data[:4]) == IComplexUpgrader.upgrade.selector, "not a ComplexUpgrader.upgrade payload");
        return abi.decode(_data[4:], (address, bytes));
    }

    /// @dev Decodes an `IL2GenesisUpgrade.genesisUpgrade` call into its arguments.
    function decodeGenesisUpgrade(
        bytes calldata _data
    ) external pure returns (uint256 chainId_, address ctmDeployer, bytes memory fixedData, bytes memory perChainData) {
        require(bytes4(_data[:4]) == IL2GenesisUpgrade.genesisUpgrade.selector, "not a genesisUpgrade call");
        return abi.decode(_data[4:], (uint256, address, bytes, bytes));
    }
}
