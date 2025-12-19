// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MailboxFacet} from "./facets/Mailbox.sol";
import {ExecutorFacet} from "./facets/Executor.sol";
import {GettersFacet} from "./facets/Getters.sol";
import {AdminFacet} from "./facets/Admin.sol";
import {Multicall3} from "../../dev-contracts/Multicall3.sol";

import {RollupDAManager} from "../data-availability/RollupDAManager.sol";
import {RelayedSLDAValidator} from "../data-availability/RelayedSLDAValidator.sol";
import {ValidiumL1DAValidator} from "../data-availability/ValidiumL1DAValidator.sol";

import {EraDualVerifier} from "../verifiers/EraDualVerifier.sol";
import {ZKsyncOSDualVerifier} from "../verifiers/ZKsyncOSDualVerifier.sol";
import {EraVerifierFflonk} from "contracts/state-transition/verifiers/EraVerifierFflonk.sol";
import {EraVerifierPlonk} from "contracts/state-transition/verifiers/EraVerifierPlonk.sol";
import {ZKsyncOSVerifierFflonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierFflonk.sol";
import {ZKsyncOSVerifierPlonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierPlonk.sol";

import {IVerifier, VerifierParams} from "../chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {EraTestnetVerifier} from "../verifiers/EraTestnetVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "../verifiers/ZKsyncOSTestnetVerifier.sol";

import {ValidatorTimelock} from "../ValidatorTimelock.sol";
import {FeeParams} from "../chain-deps/ZKChainStorage.sol";

import {DiamondInit} from "./DiamondInit.sol";
import {L1GenesisUpgrade} from "../../upgrades/L1GenesisUpgrade.sol";
import {Diamond} from "../libraries/Diamond.sol";

import {ZKsyncOSChainTypeManager} from "../ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "../EraChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {ROLLUP_L2_DA_COMMITMENT_SCHEME} from "../../common/Config.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "../chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "../IChainTypeManager.sol";
import {ServerNotifier} from "../../governance/ServerNotifier.sol";

/// @notice Copied from your original contract (kept identical for easy wiring).
// solhint-disable-next-line gas-struct-packing
struct GatewayCTMDeployerConfig {
    address aliasedGovernanceAddress;
    bytes32 salt;
    uint256 eraChainId;
    uint256 l1ChainId;
    bool testnetVerifier;
    bytes4[] adminSelectors;
    bytes4[] executorSelectors;
    bytes4[] mailboxSelectors;
    bytes4[] gettersSelectors;
    VerifierParams verifierParams;
    FeeParams feeParams;
    bytes32 bootloaderHash;
    bytes32 defaultAccountHash;
    bytes32 evmEmulatorHash;
    uint256 priorityTxMaxGasLimit;
    bytes32 genesisRoot;
    uint256 genesisRollupLeafIndex;
    bytes32 genesisBatchCommitment;
    bytes forceDeploymentsData;
    uint256 protocolVersion;
    bool isZKsyncOS;
}

/// @dev Step 0: Multicall3 (standalone, no special init/ownership).
contract GatewayStep0_Multicall3 {
    address public immutable multicall3;
    constructor(bytes32 innerSalt) {
        multicall3 = address(new Multicall3{salt: innerSalt}());
    }
}

/// @dev Step 1: DA suite: RollupDAManager + DA validators + configure + transfer ownership to governance.
contract GatewayStep1_DA {
    address public immutable rollupDAManager;
    address public immutable relayedSLDAValidator;
    address public immutable validiumDAValidator;

    constructor(bytes32 innerSalt, address aliasedGovernanceAddress) {
        RollupDAManager mgr = new RollupDAManager{salt: innerSalt}();
        ValidiumL1DAValidator validium = new ValidiumL1DAValidator{salt: innerSalt}();
        RelayedSLDAValidator relayed = new RelayedSLDAValidator{salt: innerSalt}();

        mgr.updateDAPair(address(relayed), ROLLUP_L2_DA_COMMITMENT_SCHEME, true);
        mgr.transferOwnership(aliasedGovernanceAddress);

        rollupDAManager = address(mgr);
        relayedSLDAValidator = address(relayed);
        validiumDAValidator = address(validium);
    }
}

/// @dev Step 2: Facets + init + upgrade contracts (no ownership transfers here).
contract GatewayStep2_FacetsAndUpgrades {
    address public immutable adminFacet;
    address public immutable mailboxFacet;
    address public immutable executorFacet;
    address public immutable gettersFacet;
    address public immutable diamondInit;
    address public immutable genesisUpgrade;

    constructor(
        bytes32 innerSalt,
        uint256 eraChainId,
        uint256 l1ChainId,
        address rollupDAManager,
        bool isZKsyncOS
    ) {
        mailboxFacet = address(new MailboxFacet{salt: innerSalt}(eraChainId, l1ChainId));
        executorFacet = address(new ExecutorFacet{salt: innerSalt}(l1ChainId));
        gettersFacet = address(new GettersFacet{salt: innerSalt}());

        adminFacet = address(new AdminFacet{salt: innerSalt}(l1ChainId, RollupDAManager(rollupDAManager)));

        diamondInit = address(new DiamondInit{salt: innerSalt}(isZKsyncOS));
        genesisUpgrade = address(new L1GenesisUpgrade{salt: innerSalt}());
    }
}

/// @dev Step 3: Verifiers (constructor sets owners where needed, no post-transfer required).
contract GatewayStep3_Verifiers {
    address public immutable verifier;        // dual/testnet wrapper
    address public immutable verifierPlonk;
    address public immutable verifierFflonk;

    constructor(
        bytes32 innerSalt,
        bool testnetVerifier,
        bool isZKsyncOS,
        address verifierOwner
    ) {
        address fflonk;
        address plonk;

        if (isZKsyncOS) {
            fflonk = address(new ZKsyncOSVerifierFflonk{salt: innerSalt}());
            plonk = address(new ZKsyncOSVerifierPlonk{salt: innerSalt}());
        } else {
            fflonk = address(new EraVerifierFflonk{salt: innerSalt}());
            plonk = address(new EraVerifierPlonk{salt: innerSalt}());
        }

        verifierFflonk = fflonk;
        verifierPlonk = plonk;

        if (testnetVerifier) {
            if (isZKsyncOS) {
                verifier = address(
                    new ZKsyncOSTestnetVerifier{salt: innerSalt}(
                        IVerifierV2(fflonk),
                        IVerifier(plonk),
                        verifierOwner
                    )
                );
            } else {
                verifier = address(
                    new EraTestnetVerifier{salt: innerSalt}(IVerifierV2(fflonk), IVerifier(plonk))
                );
            }
        } else {
            if (isZKsyncOS) {
                verifier = address(
                    new ZKsyncOSDualVerifier{salt: innerSalt}(
                        IVerifierV2(fflonk),
                        IVerifier(plonk),
                        verifierOwner
                    )
                );
            } else {
                verifier = address(
                    new EraDualVerifier{salt: innerSalt}(IVerifierV2(fflonk), IVerifier(plonk))
                );
            }
        }
    }
}

/// @dev Step 5: ValidatorTimelock impl + proxy; proxy initializes owner = governance in same tx.
contract GatewayStep5_ValidatorTimelock {
    address public immutable validatorTimelockImplementation;
    address public immutable validatorTimelockProxy;

    constructor(bytes32 innerSalt, address proxyAdmin, address aliasedGovernanceAddress) {
        address impl = address(new ValidatorTimelock{salt: innerSalt}(L2_BRIDGEHUB_ADDR));
        validatorTimelockImplementation = impl;

        validatorTimelockProxy = address(
            new TransparentUpgradeableProxy{salt: innerSalt}(
                impl,
                proxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (aliasedGovernanceAddress, 0))
            )
        );
    }
}

/// @dev Step 6: ServerNotifier (temporary owner = this step) + CTM impl+proxy + set CTM into notifier + transfer notifier ownership to governance.
contract GatewayStep6_CTMAndServerNotifier {
    address public immutable serverNotifierImplementation;
    address public immutable serverNotifierProxy;

    address public immutable chainTypeManagerImplementation;
    address public immutable chainTypeManagerProxy;

    /// @notice Helpful to persist for offchain consumption/debugging.
    bytes public diamondCutData;

    constructor(
        bytes32 innerSalt,
        GatewayCTMDeployerConfig memory cfg,
        address proxyAdmin,
        bytes memory ctmInitCalldata
    ) {
        // 1) ServerNotifier (owned by this step contract temporarily, so it can be configured safely)
        address snImpl = address(new ServerNotifier{salt: innerSalt}());
        serverNotifierImplementation = snImpl;

        address snProxy = address(
            new TransparentUpgradeableProxy{salt: innerSalt}(
                snImpl,
                proxyAdmin,
                abi.encodeCall(ServerNotifier.initialize, (address(this)))
            )
        );
        serverNotifierProxy = snProxy;

        // 2) CTM implementation
        if (cfg.isZKsyncOS) {
            chainTypeManagerImplementation = address(new ZKsyncOSChainTypeManager{salt: innerSalt}(L2_BRIDGEHUB_ADDR));
        } else {
            chainTypeManagerImplementation = address(new EraChainTypeManager{salt: innerSalt}(L2_BRIDGEHUB_ADDR));
        }

        // 3) Diamond cut data

        // 4) CTM proxy
        address ctmProxy = address(
            new TransparentUpgradeableProxy{salt: innerSalt}(
                chainTypeManagerImplementation,
                proxyAdmin,
                ctmInitCalldata
            )
        );
        chainTypeManagerProxy = ctmProxy;

        // 5) Wire notifier -> CTM, then hand ownership to governance
        ServerNotifier(snProxy).setChainTypeManager(IChainTypeManager(ctmProxy));
        ServerNotifier(snProxy).transferOwnership(cfg.aliasedGovernanceAddress);
    }
}
