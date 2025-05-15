// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;
import {CA} from "@automata-network/on-chain-pccs/Common.sol";

import {
    EnclaveIdentityJsonObj,
    EnclaveIdentityHelper,
    IdentityObj
} from "@automata-network/on-chain-pccs/helpers/EnclaveIdentityHelper.sol";
import {TcbInfoJsonObj, FmspcTcbHelper} from "@automata-network/on-chain-pccs/helpers/FmspcTcbHelper.sol";

import {PCCSRouter} from "automata-network/dcap-attestation/evm/contracts/PCCSRouter.sol";
import {AttestationEntrypointBase} from "automata-network/dcap-attestation/evm/contracts/AttestationEntrypointBase.sol";
import {HEADER_LENGTH, SGX_TEE, TDX_TEE} from "automata-network/dcap-attestation/evm/contracts/types/Constants.sol";
import {BELE} from "automata-network/dcap-attestation/evm/contracts/utils/BELE.sol";

import {ECDSA} from "solady/utils/ECDSA.sol";

import "./interfaces/IHashValidator.sol";
import "./DCAPAttestationHelpers.sol";
import "./DCAPAttestationDAOs.sol";

error InvalidP256Verifier();
error InvalidHashValidator();
error IncorrectVersion(uint256 version);
error InvalidSigner(address recoveredSigner);
error InvalidMrEnclave(bytes32 mrEnclave);
error InvalidTD10ReportBodyMrHash(bytes32 tD10ReportBodyMrHash);
error VerificationFailed(bytes output);

/**
 * @title MatterLabs DCAP Attestation
 * @dev Contract for handling attestation and verification using DCAP
 */
contract MatterLabsDCAPAttestation is AttestationEntrypointBase {
    using ECDSA for bytes32;
    
    uint256 constant MR_ENCLAVE_OFFSET = HEADER_LENGTH + 64;
    uint256 constant ENCLAVE_REPORT_DATA_OFFSET = HEADER_LENGTH + 320;
    uint256 constant TD10_MRTD_OFFSET = HEADER_LENGTH + 136;
    uint256 constant TD10_RTMR0_OFFSET = HEADER_LENGTH + 328;
    uint256 constant TD10_RTMR1_OFFSET = TD10_RTMR0_OFFSET + 48;
    uint256 constant TD10_RTMR2_OFFSET = TD10_RTMR1_OFFSET + 48;
    uint256 constant TD10_RTMR3_OFFSET = TD10_RTMR2_OFFSET + 48;
    uint256 constant TD10_REPORT_DATA_OFFSET = HEADER_LENGTH + 520;

    address P256_VERIFIER;
    DCAPAttestationHelpers public helpers;
    DCAPAttestationDAOs public daos;
    IHashValidator public hashValidator;

    /**
     * @dev Initializes the contract with the P256 verifier, Helpers, DAOs, and Enclave Hash Validator.
     * @param _P256_Verifier Address of the P256 Verifier contract.
     * @param _hashValidator Address of the Enclave Hash Validator contract.
     * @param _helpers Address of the DCAPAttestationHelpers contract.
     * @param _daos Address of the DCAPAttestationDAOs contract.
     */
    constructor(
        address _P256_Verifier,
        address _hashValidator,
        address _helpers,
        address _daos
    ) {
        require(_P256_Verifier.code.length > 0, InvalidP256Verifier());
        P256_VERIFIER = _P256_Verifier;

        require(_hashValidator.code.length > 0, InvalidHashValidator());
        hashValidator = IHashValidator(_hashValidator);
        
        helpers = DCAPAttestationHelpers(_helpers);
        daos = DCAPAttestationDAOs(_daos);
    }

    function verifyAndAttestOnChain(bytes calldata rawQuote, bytes32 digest, bytes calldata signature) external {
        uint16 quoteVersion = uint16(BELE.leBytesToBeUint(rawQuote[0:2]));
        bytes4 teeType = bytes4(uint32(BELE.leBytesToBeUint(rawQuote[4:8])));
        if (quoteVersion == 3 || (quoteVersion == 4 && teeType == SGX_TEE)) {
            _checkMrEnclave(rawQuote);
            uint256 reportDataOffset = ENCLAVE_REPORT_DATA_OFFSET;
            _checkSigner(rawQuote, digest, signature, reportDataOffset);
        }
        else if(quoteVersion == 4 && teeType == TDX_TEE) {
            _checkTD10Mr(rawQuote);
            uint256 reportDataOffset = TD10_REPORT_DATA_OFFSET;
            _checkSigner(rawQuote, digest, signature, reportDataOffset);
        }

        (bool success, bytes memory output) = _verifyAndAttestOnChain(rawQuote);        
        require(success, VerificationFailed(output));
    }

    function _checkMrEnclave(bytes calldata rawQuote) internal view {
        bytes32 mrEnclave = bytes32(rawQuote[MR_ENCLAVE_OFFSET: MR_ENCLAVE_OFFSET + 32]);
        require(hashValidator.isValidEnclaveHash(mrEnclave), InvalidMrEnclave(mrEnclave));
    }

    function _checkTD10Mr(bytes calldata rawQuote) internal view {
        bytes32 tD10ReportBodyMrHash = keccak256(
            abi.encodePacked(
                rawQuote[TD10_MRTD_OFFSET : TD10_MRTD_OFFSET + 48],     //mrTD
                rawQuote[TD10_RTMR0_OFFSET : TD10_RTMR3_OFFSET + 48]    //rtMr0, rtMr1, rtMr2, rtMr3
            )
        );
        require(hashValidator.isValidTD10ReportBodyMrHash(tD10ReportBodyMrHash), InvalidTD10ReportBodyMrHash(tD10ReportBodyMrHash));
    }

    function _checkSigner(bytes calldata rawQuote, bytes32 digest, bytes calldata signature, uint256 reportDataOffset) internal view {
        address signer = address(bytes20(rawQuote[reportDataOffset: reportDataOffset + 32]));
        uint256 version = uint256(bytes32(rawQuote[reportDataOffset + 32: reportDataOffset + 64]));
        require(version == 1, IncorrectVersion(version)); 
        address recovered = digest.recover(signature);
        require(recovered == signer, InvalidSigner(recovered));   
    }

    function updateP256Verifier(address _P256_VERIFIER) external onlyOwner {
        require(_P256_VERIFIER.code.length > 0, InvalidP256Verifier());
        P256_VERIFIER = _P256_VERIFIER;
    }

    function updateHashValidator(address _hashValidator) external onlyOwner {
        require(_hashValidator.code.length > 0, InvalidHashValidator());
        hashValidator = IHashValidator(_hashValidator);
    }

    // Delegated functions to the DAOs contract
    function upsertPcsCertificates(CA[] calldata ca, bytes[] calldata certs) external returns (bytes32[] memory) {
        return daos.upsertPcsCertificates(ca, certs);
    }

    function upsertRootCACrl(bytes calldata rootcacrl) external returns (bytes32) {
        return daos.upsertRootCACrl(rootcacrl);
    }

    function upsertPckCrl(CA ca, bytes calldata crl) external returns (bytes32) {
        return daos.upsertPckCrl(ca, crl);
    }
    
    function upsertEnclaveIdentity(uint256 id, uint256 quoteVersion, EnclaveIdentityJsonObj calldata identityJson) external {
        daos.upsertEnclaveIdentity(id, quoteVersion, identityJson);
    }

    function upsertFmspcTcb(TcbInfoJsonObj calldata tcbInfoJson) external {
        daos.upsertFmspcTcb(tcbInfoJson);
    }
    
    // ============Resolver Config Functions============
    function setResolverCallerAuthorization(address caller, bool authorized) external onlyOwner {
        daos.setResolverCallerAuthorization(caller, authorized);
    }

    function pauseResolverCallerRestriction() external onlyOwner {
        daos.pauseResolverCallerRestriction();
    }

    function unpauseResolverCallerRestriction() external onlyOwner {
        daos.unpauseResolverCallerRestriction();
    }

    function updateResolverDao(address _pcsDao, address _pckDao, address _fmspcTcbDao, address _enclaveIdDao)
        external
        onlyOwner
    {
        daos.updateResolverDao(_pcsDao, _pckDao, _fmspcTcbDao, _enclaveIdDao);
    }

    function revokeResolverDao(address revoked) external onlyOwner {
        daos.revokeResolverDao(revoked);
    }

    // ============Router Config Functions============
    function setRouterAuthorization(address caller, bool authorized) external onlyOwner {
        daos.setRouterAuthorization(caller, authorized);
    }

    function enableRouterCallerRestriction() external onlyOwner {
        daos.enableRouterCallerRestriction();
    }

    function disableRouterCallerRestriction() external onlyOwner {
        daos.disableRouterCallerRestriction();
    }

    function setRouterConfig(
        address _qeid, 
        address _fmspcTcb, 
        address _pcs, 
        address _pck,
        address _x509,
        address _x509Crl,
        address _tcbHelper
    ) external onlyOwner {
        daos.setRouterConfig(_qeid, _fmspcTcb, _pcs, _pck, _x509, _x509Crl, _tcbHelper);
    }
    
    // Access PCCSRouter for compatibility with existing tests and functions
    function pccsRouter() external view returns (PCCSRouter) {
        return daos.getPCCSRouter();
    }
}