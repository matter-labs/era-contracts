// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console2 as console} from "forge-std/Script.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Call} from "contracts/governance/Common.sol";
import {Utils, ChainInfoFromBridgehub} from "./Utils.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";

import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {IBridgehub, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";

bytes32 constant SET_TOKEN_MULTIPLIER_SETTER_ROLE = keccak256("SET_TOKEN_MULTIPLIER_SETTER_ROLE");

contract AdminFunctions is Script {
    using stdToml for string;

    struct Config {
        address admin;
        address governor;
    }

    Config internal config;

    function initConfig() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-admin-functionsons.toml");
        string memory toml = vm.readFile(path);
        config.admin = toml.readAddress("$.target_addr");
        config.governor = toml.readAddress("$.governor");
    }

    // This function should be called by the owner to accept the admin role
    function governanceAcceptOwner(address governor, address target) public {
        Ownable2Step adminContract = Ownable2Step(target);
        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: target,
            _data: abi.encodeCall(adminContract.acceptOwnership, ()),
            _value: 0,
            _delay: 0
        });
    }

    // This function should be called by the owner to accept the admin role
    function governanceAcceptAdmin(address governor, address target) public {
        IZKChain adminContract = IZKChain(target);
        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: target,
            _data: abi.encodeCall(adminContract.acceptAdmin, ()),
            _value: 0,
            _delay: 0
        });
    }

    // This function should be called by the owner to accept the admin role
    function chainAdminAcceptAdmin(ChainAdmin chainAdmin, address target) public {
        IZKChain adminContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: abi.encodeCall(adminContract.acceptAdmin, ())});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    // This function should be called by the owner to update token multiplier setter role
    function chainSetTokenMultiplierSetter(
        address chainAdmin,
        address accessControlRestriction,
        address diamondProxyAddress,
        address setter
    ) public {
        if (accessControlRestriction == address(0)) {
            _chainSetTokenMultiplierSetterOwnable(chainAdmin, setter);
        } else {
            _chainSetTokenMultiplierSetterLatestChainAdmin(accessControlRestriction, diamondProxyAddress, setter);
        }
    }

    function _chainSetTokenMultiplierSetterOwnable(address chainAdmin, address setter) internal {
        IChainAdminOwnable admin = IChainAdminOwnable(chainAdmin);

        vm.startBroadcast();
        admin.setTokenMultiplierSetter(setter);
        vm.stopBroadcast();
    }

    function _chainSetTokenMultiplierSetterLatestChainAdmin(
        address accessControlRestriction,
        address diamondProxyAddress,
        address setter
    ) internal {
        AccessControlRestriction restriction = AccessControlRestriction(accessControlRestriction);

        if (
            restriction.requiredRoles(diamondProxyAddress, IAdmin.setTokenMultiplier.selector) !=
            SET_TOKEN_MULTIPLIER_SETTER_ROLE
        ) {
            vm.startBroadcast();
            restriction.setRequiredRoleForCall(
                diamondProxyAddress,
                IAdmin.setTokenMultiplier.selector,
                SET_TOKEN_MULTIPLIER_SETTER_ROLE
            );
            vm.stopBroadcast();
        }

        if (!restriction.hasRole(SET_TOKEN_MULTIPLIER_SETTER_ROLE, setter)) {
            vm.startBroadcast();
            restriction.grantRole(SET_TOKEN_MULTIPLIER_SETTER_ROLE, setter);
            vm.stopBroadcast();
        }
    }

    function governanceExecuteCalls(bytes memory callsToExecute, address governanceAddr) public {
        Call[] memory calls = abi.decode(callsToExecute, (Call[]));
        Utils.executeCalls(governanceAddr, bytes32(0), 0, calls);
    }

    function adminEncodeMulticall(bytes memory callsToExecute) external {
        Call[] memory calls = abi.decode(callsToExecute, (Call[]));

        bytes memory result = abi.encodeCall(ChainAdmin.multicall, (calls, true));
        console.logBytes(result);
    }

    function adminExecuteUpgrade(
        bytes memory diamondCut,
        address adminAddr,
        address accessControlRestriction,
        address chainDiamondProxy
    ) public {
        uint256 oldProtocolVersion = IZKChain(chainDiamondProxy).getProtocolVersion();
        Diamond.DiamondCutData memory upgradeCutData = abi.decode(diamondCut, (Diamond.DiamondCutData));

        Utils.adminExecute(
            adminAddr,
            accessControlRestriction,
            chainDiamondProxy,
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (oldProtocolVersion, upgradeCutData)),
            0
        );
    }

    function adminScheduleUpgrade(
        address adminAddr,
        address accessControlRestriction,
        uint256 newProtocolVersion,
        uint256 timestamp
    ) public {
        Utils.adminExecute(
            adminAddr,
            accessControlRestriction,
            adminAddr,
            // We do instant upgrades, but obviously it should be different in prod
            abi.encodeCall(ChainAdmin.setUpgradeTimestamp, (newProtocolVersion, timestamp)),
            0
        );
    }

    function setDAValidatorPair(
        ChainAdmin chainAdmin,
        address target,
        address l1DaValidator,
        address l2DaValidator
    ) public {
        IZKChain adminContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: target,
            value: 0,
            data: abi.encodeCall(adminContract.setDAValidatorPair, (l1DaValidator, l2DaValidator))
        });

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    function makePermanentRollup(ChainAdmin chainAdmin, address target) public {
        IZKChain adminContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: abi.encodeCall(adminContract.makePermanentRollup, ())});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    function updateValidator(
        address adminAddr,
        address accessControlRestriction,
        address validatorTimelock,
        uint256 chainId,
        address validatorAddress,
        bool addValidator
    ) public {
        bytes memory data;
        // The interface should be compatible with both the new and the old ValidatorTimelock
        if (addValidator) {
            data = abi.encodeCall(ValidatorTimelock.addValidator, (chainId, validatorAddress));
        } else {
            data = abi.encodeCall(ValidatorTimelock.removeValidator, (chainId, validatorAddress));
        }

        Utils.adminExecute(adminAddr, accessControlRestriction, validatorTimelock, data, 0);
    }

    /// @notice Adds L2WrappedBaseToken of a chain to the store.
    /// @param storeAddress THe address of the `L2WrappedBaseTokenStore`.
    /// @param ecosystemAdmin The address of the ecosystem admin contract.
    /// @param chainId The chain id of the chain.
    /// @param l2WBaseToken The address of the L2WrappedBaseToken.
    function addL2WethToStore(
        address storeAddress,
        ChainAdmin ecosystemAdmin,
        uint256 chainId,
        address l2WBaseToken
    ) public {
        L2WrappedBaseTokenStore l2WrappedBaseTokenStore = L2WrappedBaseTokenStore(storeAddress);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: storeAddress,
            value: 0,
            data: abi.encodeCall(l2WrappedBaseTokenStore.initializeChain, (chainId, l2WBaseToken))
        });

        vm.startBroadcast();
        ecosystemAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    /// @notice Change pubdata pricing mode. Need to be called by chain admin.
    /// @param chainAdmin The chain admin
    /// @param target The zk chain contract.
    /// @param pricingMode The new pricing mode.
    function setPubdataPricingMode(ChainAdmin chainAdmin, address target, PubdataPricingMode pricingMode) public {
        IZKChain zkChainContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: target,
            value: 0,
            data: abi.encodeCall(zkChainContract.setPubdataPricingMode, (pricingMode))
        });

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    struct Output {
        address admin;
        bytes encodedData;
    }

    function notifyServerMigrationToGateway(address _bridgehub, uint256 _chainId, bool _shouldSend) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.serverNotifier,
            value: 0,
            data: abi.encodeCall(ServerNotifier.migrateToGateway, (_chainId))
        });

        saveAndSendAdminTx(chainInfo.admin, calls, _shouldSend);
    }

    function notifyServerMigrationFromGateway(address _bridgehub, uint256 _chainId, bool _shouldSend) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.serverNotifier,
            value: 0,
            data: abi.encodeCall(ServerNotifier.migrateFromGateway, (_chainId))
        });

        saveAndSendAdminTx(chainInfo.admin, calls, _shouldSend);
    }

    function grantGatewayWhitelist(
        address _bridgehub,
        uint256 _chainId,
        address[] calldata _grantees,
        bool _shouldSend
    ) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        address transactionFilterer = IGetters(chainInfo.diamondProxy).getTransactionFilterer();
        require(transactionFilterer != address(0), "Chain does not have a transaction filterer");

        Call[] memory calls = new Call[](_grantees.length);
        for (uint256 i = 0; i < _grantees.length; i++) {
            calls[i] = Call({
                target: transactionFilterer,
                value: 0,
                data: abi.encodeCall(GatewayTransactionFilterer.grantWhitelist, (_grantees[i]))
            });
        }

        saveAndSendAdminTx(chainInfo.admin, calls, _shouldSend);
    }

    function revokeGatewayWhitelist(address _bridgehub, uint256 _chainId, address _address, bool _shouldSend) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        address transactionFilterer = IGetters(chainInfo.diamondProxy).getTransactionFilterer();
        require(transactionFilterer != address(0), "Chain does not have a transaction filterer");

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: transactionFilterer,
            value: 0,
            data: abi.encodeCall(GatewayTransactionFilterer.revokeWhitelist, (_address))
        });

        saveAndSendAdminTx(chainInfo.admin, calls, _shouldSend);
    }

    /// We use explicit `_shouldSend` instead of the standard `--broadcast` to ensure stable output
    /// for the calldata
    function setTransactionFilterer(
        address _bridgehub,
        uint256 _chainId,
        address _transactionFiltererAddress,
        bool _shouldSend
    ) external {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.diamondProxy,
            value: 0,
            data: abi.encodeCall(IAdmin.setTransactionFilterer, (_transactionFiltererAddress))
        });

        saveAndSendAdminTx(chainInfo.admin, calls, _shouldSend);
    }
    struct MigrateChainToGatewayParams {
        address bridgehub;
        uint256 l1GasPrice;
        uint256 l2ChainId;
        uint256 gatewayChainId;
        bytes _gatewayDiamondCutData;
        address refundRecipient;
        bool _shouldSend;
    }

    // Using struct for input to avoid stack too deep errors
    // The outer function does not expect it as input rightaway for easier encoding in zkstack Rust.
    function _migrateChainToGatewayInner(MigrateChainToGatewayParams memory data) private {
        Call[] memory calls;

        ChainInfoFromBridgehub memory gatewayChainInfo = Utils.chainInfoFromBridgehubAndChainId(
            data.bridgehub,
            data.gatewayChainId
        );
        ChainInfoFromBridgehub memory l2ChainInfo = Utils.chainInfoFromBridgehubAndChainId(
            data.bridgehub,
            data.l2ChainId
        );

        bytes memory secondBridgeData;
        {
            bytes32 chainAssetId = Bridgehub(data.bridgehub).ctmAssetIdFromChainId(data.l2ChainId);

            uint256 currentSettlementLayer = Bridgehub(data.bridgehub).settlementLayer(data.l2ChainId);
            if (currentSettlementLayer == data.gatewayChainId) {
                console.log("Chain already using gateway as its settlement layer");
                saveOutput(Output({admin: l2ChainInfo.admin, encodedData: hex""}));
                return;
            }

            bytes memory bridgehubData = abi.encode(
                BridgehubBurnCTMAssetData({
                    chainId: data.l2ChainId,
                    ctmData: abi.encode(
                        AddressAliasHelper.applyL1ToL2Alias(l2ChainInfo.admin),
                        data._gatewayDiamondCutData
                    ),
                    chainData: abi.encode(
                        IZKChain(Bridgehub(data.bridgehub).getZKChain(data.l2ChainId)).getProtocolVersion()
                    )
                })
            );

            // TODO: use constant for the 0x01
            secondBridgeData = abi.encodePacked(bytes1(0x01), abi.encode(chainAssetId, bridgehubData));
        }

        calls = Utils.prepareAdminL1L2TwoBridgesTransaction(
            data.l1GasPrice,
            Utils.MAX_PRIORITY_TX_GAS,
            data.gatewayChainId,
            data.bridgehub,
            gatewayChainInfo.l1AssetRouterProxy,
            gatewayChainInfo.l1AssetRouterProxy,
            0,
            secondBridgeData,
            data.refundRecipient
        );

        saveAndSendAdminTx(l2ChainInfo.admin, calls, data._shouldSend);
    }

    function migrateChainToGateway(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 l2ChainId,
        uint256 gatewayChainId,
        bytes calldata _gatewayDiamondCutData,
        address refundRecipient,
        bool _shouldSend
    ) public {
        _migrateChainToGatewayInner(
            MigrateChainToGatewayParams({
                bridgehub: bridgehub,
                l1GasPrice: l1GasPrice,
                l2ChainId: l2ChainId,
                gatewayChainId: gatewayChainId,
                _gatewayDiamondCutData: _gatewayDiamondCutData,
                refundRecipient: refundRecipient,
                _shouldSend: _shouldSend
            })
        );
    }

    struct SetDAValidatorPairWithGatewayParams {
        address bridgehub;
        uint256 l1GasPrice;
        uint256 l2ChainId;
        uint256 gatewayChainId;
        address l1DAValidator;
        address l2DAValidator;
        address chainDiamondProxyOnGateway;
        address refundRecipient;
        bool _shouldSend;
    }

    // Using struct for input to avoid stack too deep errors
    // The outer function does not expect it as input rightaway for easier encoding in zkstack Rust.
    function _setDAValidatorPairWithGatewayInner(SetDAValidatorPairWithGatewayParams memory data) private {
        ChainInfoFromBridgehub memory l2ChainInfo = Utils.chainInfoFromBridgehubAndChainId(
            data.bridgehub,
            data.l2ChainId
        );
        bytes memory callData = abi.encodeCall(IAdmin.setDAValidatorPair, (data.l1DAValidator, data.l2DAValidator));
        Call[] memory calls = Utils.prepareAdminL1L2DirectTransaction(
            data.l1GasPrice,
            callData,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            data.chainDiamondProxyOnGateway,
            0,
            data.gatewayChainId,
            data.bridgehub,
            l2ChainInfo.l1AssetRouterProxy,
            data.refundRecipient
        );

        saveAndSendAdminTx(l2ChainInfo.admin, calls, data._shouldSend);
    }

    function setDAValidatorPairWithGateway(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 l2ChainId,
        uint256 gatewayChainId,
        address l1DAValidator,
        address l2DAValidator,
        address chainDiamondProxyOnGateway,
        address refundRecipient,
        bool _shouldSend
    ) public {
        _setDAValidatorPairWithGatewayInner(
            SetDAValidatorPairWithGatewayParams({
                bridgehub: bridgehub,
                l1GasPrice: l1GasPrice,
                l2ChainId: l2ChainId,
                gatewayChainId: gatewayChainId,
                l1DAValidator: l1DAValidator,
                l2DAValidator: l2DAValidator,
                chainDiamondProxyOnGateway: chainDiamondProxyOnGateway,
                refundRecipient: refundRecipient,
                _shouldSend: _shouldSend
            })
        );
    }

    struct EnableValidatorViaGatewayParams {
        address bridgehub;
        uint256 l1GasPrice;
        uint256 l2ChainId;
        uint256 gatewayChainId;
        address validatorAddress;
        address gatewayValidatorTimelock;
        address refundRecipient;
        bool _shouldSend;
    }

    // Using struct for input to avoid stack too deep errors
    // The outer function does not expect it as input rightaway for easier encoding in zkstack Rust.
    function _enableValidatorViaGatewayInner(EnableValidatorViaGatewayParams memory data) private {
        ChainInfoFromBridgehub memory l2ChainInfo = Utils.chainInfoFromBridgehubAndChainId(
            data.bridgehub,
            data.l2ChainId
        );
        bytes memory callData = abi.encodeCall(ValidatorTimelock.addValidator, (data.l2ChainId, data.validatorAddress));
        Call[] memory calls = Utils.prepareAdminL1L2DirectTransaction(
            data.l1GasPrice,
            callData,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            data.gatewayValidatorTimelock,
            0,
            data.gatewayChainId,
            data.bridgehub,
            l2ChainInfo.l1AssetRouterProxy,
            data.refundRecipient
        );

        saveAndSendAdminTx(l2ChainInfo.admin, calls, data._shouldSend);
    }

    function enableValidatorViaGateway(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 l2ChainId,
        uint256 gatewayChainId,
        address validatorAddress,
        address gatewayValidatorTimelock,
        address refundRecipient,
        bool _shouldSend
    ) public {
        _enableValidatorViaGatewayInner(
            EnableValidatorViaGatewayParams({
                bridgehub: bridgehub,
                l1GasPrice: l1GasPrice,
                l2ChainId: l2ChainId,
                gatewayChainId: gatewayChainId,
                validatorAddress: validatorAddress,
                gatewayValidatorTimelock: gatewayValidatorTimelock,
                refundRecipient: refundRecipient,
                _shouldSend: _shouldSend
            })
        );
    }

    struct StartMigrateChainFromGatewayParams {
        address bridgehub;
        uint256 l1GasPrice;
        uint256 l2ChainId;
        uint256 gatewayChainId;
        bytes l1DiamondCutData;
        address refundRecipient;
        bool shouldSend;
    }

    // Using struct for input to avoid stack too deep errors
    // The outer function does not expect it as input rightaway for easier encoding in zkstack Rust.
    function _startMigrateChainFromGateway(StartMigrateChainFromGatewayParams memory data) internal {
        ChainInfoFromBridgehub memory l2ChainInfo = Utils.chainInfoFromBridgehubAndChainId(
            data.bridgehub,
            data.l2ChainId
        );

        {
            uint256 currentSettlementLayer = Bridgehub(data.bridgehub).settlementLayer(data.l2ChainId);
            if (currentSettlementLayer != data.gatewayChainId) {
                console.log("Chain does not settle on Gateway");
                saveOutput(Output({admin: l2ChainInfo.admin, encodedData: hex""}));
                return;
            }
        }

        bytes memory bridgehubBurnData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: data.l2ChainId,
                ctmData: abi.encode(l2ChainInfo.admin, data.l1DiamondCutData),
                chainData: abi.encode(ChainTypeManager(l2ChainInfo.ctm).getProtocolVersion(data.l2ChainId))
            })
        );

        bytes32 ctmAssetId = IBridgehub(data.bridgehub).ctmAssetIdFromChainId(data.l2ChainId);
        bytes memory l2Calldata = abi.encodeCall(IL2AssetRouter.withdraw, (ctmAssetId, bridgehubBurnData));

        Call[] memory calls = Utils.prepareAdminL1L2DirectTransaction(
            data.l1GasPrice,
            l2Calldata,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            L2_ASSET_ROUTER_ADDR,
            0,
            data.gatewayChainId,
            data.bridgehub,
            l2ChainInfo.l1AssetRouterProxy,
            data.refundRecipient
        );

        saveAndSendAdminTx(l2ChainInfo.admin, calls, data.shouldSend);
    }

    // The public function preserves the original interface
    // and simply wraps the input into the struct before calling the inner function.
    function startMigrateChainFromGateway(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 l2ChainId,
        uint256 gatewayChainId,
        bytes memory l1DiamondCutData,
        address refundRecipient,
        bool _shouldSend
    ) public {
        StartMigrateChainFromGatewayParams memory params = StartMigrateChainFromGatewayParams({
            bridgehub: bridgehub,
            l1GasPrice: l1GasPrice,
            l2ChainId: l2ChainId,
            gatewayChainId: gatewayChainId,
            l1DiamondCutData: l1DiamondCutData,
            refundRecipient: refundRecipient,
            shouldSend: _shouldSend
        });

        _startMigrateChainFromGateway(params);
    }

    struct AdminL1L2TxParams {
        address bridgehub;
        uint256 l1GasPrice;
        uint256 chainId;
        address to;
        uint256 value;
        bytes data;
        address refundRecipient;
        bool _shouldSend;
    }

    // Using struct for input to avoid stack too deep errors.
    // The outer function does not expect it as input rightaway for easier encoding in zkstack Rust.
    function _adminL1L2TxInner(AdminL1L2TxParams memory params) private {
        ChainInfoFromBridgehub memory l2ChainInfo = Utils.chainInfoFromBridgehubAndChainId(
            params.bridgehub,
            params.chainId
        );
        Call[] memory calls = Utils.prepareAdminL1L2DirectTransaction(
            params.l1GasPrice,
            params.data,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            params.to,
            params.value,
            params.chainId,
            params.bridgehub,
            l2ChainInfo.l1AssetRouterProxy,
            params.refundRecipient
        );

        saveAndSendAdminTx(l2ChainInfo.admin, calls, params._shouldSend);
    }

    function adminL1L2Tx(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 chainId,
        address to,
        uint256 value,
        bytes memory data,
        address refundRecipient,
        bool _shouldSend
    ) public {
        _adminL1L2TxInner(
            AdminL1L2TxParams({
                bridgehub: bridgehub,
                l1GasPrice: l1GasPrice,
                chainId: chainId,
                to: to,
                value: value,
                data: data,
                refundRecipient: refundRecipient,
                _shouldSend: _shouldSend
            })
        );
    }

    function saveAndSendAdminTx(address _admin, Call[] memory _calls, bool _shouldSend) internal {
        bytes memory data = abi.encode(_calls);

        if (_shouldSend) {
            Utils.adminExecuteCalls(_admin, address(0), _calls);
        }

        saveOutput(Output({admin: _admin, encodedData: data}));
    }

    function saveOutput(Output memory output) internal {
        vm.serializeAddress("root", "admin_address", output.admin);
        string memory toml = vm.serializeBytes("root", "encoded_data", output.encodedData);
        string memory path = string.concat(vm.projectRoot(), "/script-out/output-admin-functions.toml");
        vm.writeToml(toml, path);
    }
}
