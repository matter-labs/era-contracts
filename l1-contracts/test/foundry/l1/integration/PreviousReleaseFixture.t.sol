// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {ChainCreationParamsLib} from "deploy-scripts/ctm/ChainCreationParamsLib.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";
import {ANVIL_FIXTURE_DEPLOYER} from "../../TestConstants.sol";
import {PreviousReleaseFixture} from "./utils/PreviousReleaseFixture.sol";
import {V0_34_ZKSYNC_OS_GENESIS_ROOT} from "../../TestConstants.sol";

/// @notice The fixture the release-to-release upgrade tests start from: the previous release's frozen L1 state,
///         loaded and settled through the chains' own flow.
contract PreviousReleaseFixtureTest is PreviousReleaseFixture {
    uint256 internal constant L1_SETTLED_CHAIN_ID = 10;

    function test_loadsThePreviousReleasesEcosystem() public {
        PreviousRelease memory release = _loadPreviousRelease();

        assertEq(release.stateVersion, "v0.34.0", "upgrade source rotated: update the source genesis root");
        assertEq(
            IBridgehubBase(release.bridgehub).chainTypeManager(L1_SETTLED_CHAIN_ID),
            release.chainTypeManager,
            "chain not under the fixture's CTM"
        );
        (, uint32 ctmMinor, ) = SemVer.unpackSemVer(
            uint96(IChainTypeManager(release.chainTypeManager).protocolVersion())
        );
        (, uint32 genesisMinor, ) = SemVer.unpackSemVer(
            uint96(ChainCreationParamsLib.getChainCreationParams(Utils.genesisConfigPath()).latestProtocolVersion)
        );
        assertEq(ctmMinor + 1, genesisMinor, "fixture CTM is not on the previous release");
    }

    function test_settlingClearsTheGenesisUpgradeAndExecutesEveryCommittedBatch() public {
        _loadPreviousRelease();
        FixtureChain memory chain = _fixtureChain(L1_SETTLED_CHAIN_ID, V0_34_ZKSYNC_OS_GENESIS_ROOT);
        IGetters getters = IGetters(chain.diamondProxy);
        assertTrue(getters.getL2SystemContractsUpgradeTxHash() != bytes32(0), "fixture chain has no pending upgrade");

        _prepareSettlement(chain);
        _settleBatch(chain);

        assertEq(getters.getTotalBatchesCommitted(), 1, "committed");
        assertEq(getters.getTotalBatchesVerified(), 1, "proven");
        assertEq(getters.getTotalBatchesExecuted(), 1, "executed");
        assertEq(getters.getL2SystemContractsUpgradeTxHash(), bytes32(0), "genesis upgrade still pending");
        assertEq(keccak256(abi.encode(chain.lastBatch)), getters.storedBatchHash(1), "tracked batch mismatch");
    }

    function test_settlesConsecutiveBatches() public {
        _loadPreviousRelease();
        FixtureChain memory chain = _fixtureChain(L1_SETTLED_CHAIN_ID, V0_34_ZKSYNC_OS_GENESIS_ROOT);
        _prepareSettlement(chain);
        _settleBatch(chain);
        _settleBatch(chain);

        assertEq(IGetters(chain.diamondProxy).getTotalBatchesExecuted(), 2, "second batch not executed");
    }

    function test_handsTheEcosystemToGovernanceAndTheChainToAChainAdmin() public {
        PreviousRelease memory release = _loadPreviousRelease();
        FixtureChain memory chain = _fixtureChain(L1_SETTLED_CHAIN_ID, V0_34_ZKSYNC_OS_GENESIS_ROOT);

        address chainAdmin = _installChainAdmin(chain);
        _handAuthorityToGovernance(release);

        assertEq(IGetters(chain.diamondProxy).getAdmin(), chainAdmin, "chain not under its ChainAdmin");
        assertEq(IGetters(chain.diamondProxy).getPendingAdmin(), address(0), "chain admin left pending");
        assertEq(IOwnable(chainAdmin).owner(), ANVIL_FIXTURE_DEPLOYER, "ChainAdmin not the operator's");
        address[5] memory governed = [
            release.bridgehub,
            release.sharedBridge,
            release.nativeTokenVault,
            release.nullifier,
            release.chainTypeManager
        ];
        for (uint256 i = 0; i < governed.length; ++i) {
            assertEq(IOwnable(governed[i]).owner(), release.governance, "not owned by governance");
            assertEq(IOwnable(governed[i]).pendingOwner(), address(0), "ownership left pending");
        }
        assertEq(
            IOwnable(Utils.getProxyAdminAddress(release.chainTypeManager)).owner(),
            release.governance,
            "CTM ProxyAdmin not owned by governance"
        );
        address notifier = IChainTypeManager(release.chainTypeManager).serverNotifierAddress();
        assertEq(IOwnable(notifier).owner(), release.ctmChainAdmin, "notifier not owned by the CTM's ChainAdmin");
        assertEq(IOwnable(notifier).pendingOwner(), address(0), "notifier ownership left pending");
    }

    function test_RevertWhen_GenesisRootIsNotTheChainsBatchZero() public {
        _loadPreviousRelease();
        vm.expectRevert(bytes("batch zero does not match the chain's stored genesis batch"));
        this.fixtureChainExternal(L1_SETTLED_CHAIN_ID, keccak256("not the genesis root"));
    }

    function fixtureChainExternal(uint256 _chainId, bytes32 _genesisRoot) external view returns (uint64) {
        return _fixtureChain(_chainId, _genesisRoot).lastBatch.batchNumber;
    }
}
