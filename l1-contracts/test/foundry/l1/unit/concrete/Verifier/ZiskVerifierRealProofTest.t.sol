// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ZISK_SNARK_PROOF_LENGTH} from "contracts/common/Config.sol";
import {IZiskSnarkVerifier} from "contracts/state-transition/chain-interfaces/IZiskSnarkVerifier.sol";
import {PilfflonkVerifier} from "contracts/state-transition/verifiers/PilfflonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";

/// @notice Real-crypto anchor for the ZiSK verifier stack.
/// @dev A fixture holds a 2,208-byte BN254 pilfflonk SNARK plus the 576-byte
///      public values `programVK(32) || guest publics(512) || rootCVadcopFinal(32)`,
///      whose single public signal is `sha256(publicValues) % r`. The
///      guest-publics section is 64 little-endian u64 slots, one per guest
///      public; a guest public holds a 32-bit value, so each slot carries four
///      significant bytes and four zero pad bytes.
///
///      The BATCH fixture is the inner state-transition proof of batch 1, so
///      its wire bytes [0..32] hold the INNER programVK and its first eight
///      guest-public slots, bytes [32..96], the raw batch commitment. The
///      AGGREGATED fixture proves the whole range, so its wire bytes [0..32]
///      hold the AGGREGATOR programVK and its first eight slots the binding
///      digest `keccak256(innerProgramVK || rootCVadcopFinal || chainedPI)`.
///
///      `ZiskVerifier.verify` rebuilds exactly those 576 aggregated bytes from
///      its own pins and the batch public inputs, so the aggregated fixture
///      drives the production path end to end: the reconstruction AND the real
///      pairing, through the vendored `PilfflonkVerifier`.
///      MultiProofRangeVectorTest pins the same vector against a signal
///      stand-in, which is what lets it name the exact expected signal.
/// @dev Fixtures: the zksync-os-zisk ZiSK 1.4.0-alpha pins, guest ELFs
///      reproduced from the pins in GPU run
///      https://github.com/matter-labs/zksync-os-zisk/actions/runs/41671348755.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 2,208-byte BN254 pilfflonk SNARK of batch 1 (inner guest).
    bytes internal constant BATCH_PROOF =
        hex"3039f69a37d6604911379f0448b1f04801e36c2294db8ee1c22bc3550b4c79160611fdb061c4de9427e524449dae841ca89408122cedb1a51448b1addfc8b6c90e08efab667d91b2524491b3e9961c177fcdceab4910f79744bf91d9470be0d92e9829ee5b08c213dc25e8ae9e08413710486f7a720e8fe9b165830647178a312159090f6cc185a56d56e55e109069697103d19dc39302ef5b741e2b40b40eda0d7c2138d0adfbf7e28478a1a4b30e9c3c30ba06e7c398f57dbf661111b24bdc178f8e721571710bfaa60311e4c2bf49000f6653e575e8007e36898be454aeed28c1369ed25e6387fd487f1b3d593c749355d1f7862c62c5165b45ba6dfb93362377ed07ef96cd44a85e73c9434a0548cc72e25c4a24c4626db63935a4a3d4cf0e885ceac5fc19daa868e1d070b4ef7cd6163a13bf203e655750f7229cf129e91f2850f278097cb9b98df8c008e45fb0eb68c27a25b85377c72ad57d0dbd865a19a59166ef757ac95a3e15231115f568a6a3285a16de24c53ce774eb1ccf129c1c0a1e004e22a5318a3fe08f5d5a591971dcccc87edfb65ae900825b797ac64b1e1b07a71a2e37bca53652cea15b640c749ce7c97a09c5331ec1c18715932829184c14bf5e50a364776f0a9c9ef3d2a379c87892978adbf654f6d84bc97af0f81f12f605a0f45274d12fa83183e0a16552e374b5d4ca93187684db89f319a5d318f0c2d1bbd8c61de466e4155230e4c19f46bd155e318e239a3c7df9a3e52c5a021175dfb6e11154dcf011a174f2e09e0a0683b3ff567bdf7ad55ff2e00ff9a420592a395680e497306bab0bc1c34d98c620b3cf47f614bb578ff1562bbd5cc424f337e723d24fb16023b1383c6603c46a1b6c00deeab5bd5ddb17c51eb7eb791a8ad26a2d496671312411cd312e863223f196946f939084bdd0544ee9cebcb607f181ed9a7b4376d69e8ae25b82f6ba830ac7ab83b86e8a928cd3b00c2d57570305ebaade2a1f30226d4e7c4e9114ec5cca706754fdcea2fd6af2f418b11bcb08ab8d6ba126ff7db885b2adc9d5c0c2e49e1ba296d175b24e09dcf84a5b59ad17ba9bf532136407cc79fd9f1429accdd148c601ff057137ad2e98c0536267931da3256e1457f32400b3fba7393f2f763908a28d3291140f6567d3284066795c030d8cb51dc4d1caf290bf693bfc375687214a4344c040e919181ec7dba6b01216b7a37eb245a3364523c559a0fd5f186661b695f0b36cac98812abf9ab0da4c11c4b0cccd8963d9548a6a68c8e8a68d7ad04f3d00dde9fbea0e2cb1c550e0d90a08313f0097fcc8399e2f35ca73262db509745130b26005e21ed6aa3d0c10911008ab12757feb97497c8c77fbff8911f53cc9503c95fad8d712f699c45a17ee1311d35350ee4f66a35519904c88b62173644e5bf42f95f4f31b35bbd10baa3d1951a917a84b5ee0c5f6cb0c5ebaebf60ca21c1aeb0cf210063733823ecba55c1b46e1ec79f6189f891008ed5843cfea3d0764b7f09f1a14a8281d6ab9910a7c09d0819744476b628b41b334f544bacfd14ec101fa0d998abf217fb69985e9d71625da552ba0d2bda095f59c3f3b0df3029515fdb24535b94a68daa345dd1f111d3f1f3004233fe77cfcc083ec6a8537841a72df758b9732fde5268d3ee8efa6131c3d836910c2cf54b4fa0f4c1e8091e7c367a904672acdfd49807e3d0fa1731cbbf38651c57dcba9efac88a781ff653a022f679f7a62ffde597b6eac21f60c150656b7dafe93c30de049ce198ae3b5eed7ccddbedb278148dd15b50437b17f2944ceff990be04b8f7c47b47035cc3070a616bb658c8b706c847c2d0944e3ce0860c072b1c50f20be4bdf5a39cb95efe14b57f47e38ef10cbcf05011e7df0431b49a94d8818f293780775ddab870f98986654249b7cb36dac2f67c99e834c3608e7d72ba7bc334add9882836cec9e92bea2c344808eff44041ecf25217599a2064ca4ee79f2f5c6ea9f727b8dd68de86b8ff942cdf63007aa3ebc15739f41020c19e082e0ece7f6f81bcd1023f4aad2329331377e8cc2b898bb2e98e26ac2b5154801de6055e3a293618687601ac3128e3d277fe5f6dfc4997ff1da7db19b39267d6799e3acf88f3e2efe201ce583d97d91973a4385e8171311f53715d5cfcb22177ecb059f29b083e39e8bdfb5d3767cbc49b8f0bae1d70210d2c129a66a98000b583d949c919d2f443588eb882dd558fe3c9055b3760d41ab5cbebe0400fc096a9733084e2ea6ce16950a3d22770984d016f30b8b3ab53ddead0390bc08772b3e13071b2f82760419667430204b40586c1bfb34a845f18b92bdc28364cf2d06f11e15e68ac70dc1894100c3320c4d4e188efc46491e1da41f9744b26dde091bdd8d8184e375c866839a42f1f82e1dabe6e1e9d419fbf7bf915c30e09e0fee059db7c04b2c130465fbd243dc250d0dcf6d70c898d9500966c77eb5de32a92d16865d3f5b37f78baaa9cf848dcd1cd7036acf8c63a29e7c6a460d73549be900110c0a93098de83a180c52407a122ace6b3ea1337365119d8667001bc1808051291612ccf443a202146c65ee5de30ee40cd6d1122425568ad21d82989a97932927e9e6ce4174e99b0536b10860b67063284a3ba36a59830d2343c75e83b3216405ea345ff1d02f00aec7f6f14042ddcb11fafedfd60f2645f2e8dd5cba0678380cc34b498de7aec612557f0a3092dd1017d8a59cdbaf03752bb796cbba74233211bc828969821ab2308699c09b6d11ba83f06ec4cecae96970cbf0cb3a0cc0d323a792a63f2128906f485a3f6b5b11037ab29c1c39bb188c3eb3c1fa7b26e90006b7d5b3bed7c71a687c31f8ef2fd40b6fe078ad896e74fbe5b7f72c1cc5a77b14f593d7ec65c7dafa284c8895820d6db4db5295023bb57303678847cff720f91d768fe3f30c7af047edde89bc86ae808c64cc2521521b0ce273da76e56f92e90d189b2a0f724540ac05eb21e35582db1e7e1136b4d3f9cf6ea9878a9c8d301623ebc0de008335be1b00c71febad1794303d0f119372e63d62fa265a0d7b4dd50046b062b1d57aa8fa484c576fb8cd6165f16fb0d98d582473ff0810351eb8c3";

    /// @dev The batch-1 proof's public values. Bytes [32..96] carry that
    ///      batch's raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"747be84de38d60d9b5816ddad433d41c9771825b630bddbc90cb1585dda69a6c63c7606f00000000aee0ee9e00000000ff230fec00000000391e64c000000000c82a027700000000947973ce000000007f6f1c900000000088c821dd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e9414e134bb6945a148a79d44c8e850e5ef582a2b0e8dbfb2428ff0a515a6e66";

    /// @dev Real 2,208-byte BN254 pilfflonk SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"103d30e1d74422b3ac12177605d1e5a981fbf689d84d1931bfc2a696155ffa711982a0cb50e65878ae15b3d9b95f095bb7d8bdf11113e5418df2b50cddcca4471079a32244946b5c80456aa3d4c8aed7885495c0577a2b0cde8bcbd318bef2de124fef6eb8677a1b9b568e4b5516f1c76ff2e55eae2a0477790510eb71023e6407a1a71fc0dc6b897984aca5d2e149b50840752580e3ee40fc12f1cb92a982d10a21abd178646da01d39ed224171b01f14c39788840a3dc503b3b5e81eb017671d56e5e78bfc42ac192135e355315958f4397510b3d49408849da52eb2744b072ab121d9073425a29930d924810be4c3d74b42afc148ed6578da4492217b96be06c91caf02f142b73c87c3e0eb7d7390db3c6f7c07cd517d8bc3d76c5f77a51225cb971bc78f85e286bd6c97e98d9eb65359a76f86c706bb2ae6a691e30a31b218f8b150586a62d5e9c2d3dc43a8097eefd681325c6a3b27812ab51f68d61b7211cffc2dbacd261c6907b753f060e220cccf082fa96730ed647e03edaef231a3161b484e704fe669b682bd415ff5accdc73804731a0811834a007917967401e10f38a9d6d1b70add4640284643c032786f7a0a43337877db930e23fa19ea4a551f9d4e456bd9a822c205bd0c234095043dc2b666887666bae172ae7fa552c4f928fbe78af547162dd928f281135f3a98f0d5aed27c400d198cbcfb4720491c37249b7bab2abcadcc94617a6a5d416597879fa0a4ca350a72dac82f10991c0f4d2e8757d75475ef71c6eff57ae0fd383d217f4cd136a5925baf1cdca041371ec902588675019f1536db6d696baa9d09822d16bd7dab134227e47e6cbbcf1e44c32d6cb4f5d7fe7c8038c8624f6c2b18bd0d77c10f5cd6cca58dbbaa694eba774e2774c24698d7db3f054292f6d02ac18a54ff00f0d3cf326e739370fdd974317d08e2d2412446a68a692396cc547584bd81321fe4da1027e65ae79160f68e8d0c25797db4dfa1fd38fb4d566fb38041c0bcd1bb06de9978ddef17d4e7547f86de20da79852d8883236c6933fd2133f1b74d24c773223cdb2b42d714d88f9c8a4b05c3813315a90c1f7008b5a3df7f637e69b861650128f6cb89148d6bbf3ba6e32af3b630e68c0319a68c1490a24049350d04f0300d08d1984fbc87d552d1eea81c7da7df3d12d5bbc32719b0432623a12e76db37f75325f184639507dfa6b40416fda8afba941d99bb6ea2fea162ab2673e117e5734f7caea3f317547c1a9bd808d3f487287bf05e39f79540e2a30a18c648ea1020d666abe626dd727a423cb61c061f91fb7718b979895acacc0cb55c71f3c2c86faabdaa1614b7f9bfb9947705575d509d714495647a4f8a1d861acd197e4e0a315d712d7e4a87ce5fb8700c0b1600c7180fe35ef88d05e4abd7347cc7b3a23edfbd7efeaef7c890699c208903f667b94872ca37872ba58722599930e0e2406e18219d6d31ef006fc30471801517bc69685e8c8a95bc025fcd4bc5a8796b19dd645748ad7a19acb1c433d978269f72e81c4eb109ed94802c89e7462cdd06873194eca852ca85cfb86189f78025f0ee1a3bcfe3d539ea119efb9f35a8ad4924b1816b1c67547766462c51868b0c796b7d617ff400b137b0755f388782dc47522bfa043726f95ce78ab85d8eb415e3326b9cef33192ece6f5490771e61522bf174a63604541059009a64c3693a208d2b411d0bc57caa8937955af6656a9d4b0a0fa01ed95724556c9938a28bdd00235c3c19f7f76e0c9e5a5be2fc38b6960f99c00507496817dcc8a2ad53162f1999c27aa16c4bc6ed49477b31a75bf6d01d0582bc4ae60926133266b6b665ed29d110f5698cf6292502c22223860e67991f2458c93d97833d83103d88f84f5d20507e73fd1ebaaf7b92e8140b50dde484316547ce7654c72d672b98fa9555c92b3afc38dd239414ff129a607cfbe2681f767280c1df5dee220dea43bc7aba6d19a0faf36c8274fc2ba1c06da519e55b0ed3b438899459f8360a06c405afb95f16468e7ff8b12cd1c3a93f9d6e28628f1c52f3d04acb9e7609efdf72ba924df1300e93c86821eb2153c78b544693f5b9cb3a5bcb6322b857571208dcc2f56c3b213e927621aa5f31cdd00aa7932342cc54839bd3b2cc9f437fdba374cd0790770b7eacf13fe79f77287b77aa1e4d34c1163df95b7174b7348396adb746862283138617636dc0161724736d6d2b26bf745dc49f5dd43aa0cde42fcafcb1c1359d0726af6f1bf38ab2247634cbfaf839bd6f797e076eea19640eae3b53db7b1370062758be407b4f047ca3230a8a61a161fc19a76aecc0075462a4cdaceaad7b3f2540e03c6491deb72c0df486acff3b502a13df0d72c70d6f3bc77737e21ee08c0632da390a0fde9dfa0386560c35b7c46d7494cd6a85851681648eae57cc2f281775dfa25963fdb0ae39494794026047932c5d14f94142825f1cff29aaef44de2a196059649cfae4cc122e6cc43ce5195e91e34918efc1bca9eb767e6e758fd61ec715b1bead568f4b2ad195b5ef03155b3831c94db7f3ecd5334ccc5d65cc55104697f971c7ee20c984d30fec7c21e0dfc45eac9799e342dc6485db4263e8d31accb866bebf5ae4942b26839d0e35f36ff41992e0042a547fe2083774cc0a7d26db227cd53b46ef232837c0bae1f12a9302c4ca4d84f0d400840627b0b27a061e5e0aa97e4eece970da30f13a05cdc8ae7e522fb43c0058f76292cbfe6067280bd62370c13e2e41fc0d0691287521b19a2866865f914c51f6cd0c6aad905672277244330a1b0b9055139207371ebe1e17bb1353f80a55e269456077c127bc78075fd84ae8087bb8b4e8e944e4db31b5f563861125f726829045cba9e8beb3450271fab742f79898d0b3c01f69f9577a272ec38934c676ce38c8153b7dc530830c684dbe0329b30d8d426daf09792a9a0aab60d81eb2e9171efdad5d0a23b72f19ad8bc23ae72ce0e996ed9d98dad52dc256f46c5b7f8a9a80d3d64e125dff190ff7d69db16a2425b4a5ff0d62476c3e85aafe0ea5abe7d3578630e5c76c8c530287b4b1fcbd216e07b6e28868648f9e220c7a1e7f0757978acfde9e0c905298";

    /// @dev The aggregated proof's public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"e7f72bf4c1825a6f852e65fc872c810320218c63ed41cf9bb4345737a4ac31ec5afe2e8900000000a27ddd84000000001b343cff000000007fb3a9f300000000c0dc18b000000000d6bc7d68000000005fbfa55a00000000f59c9bd00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e9414e134bb6945a148a79d44c8e850e5ef582a2b0e8dbfb2428ff0a515a6e66";

    /// @dev The four batch commitments the aggregated proof ingested, in batch
    ///      order. MultiProofRangeVectorTest pins the same vector.
    bytes32 internal constant COMMITMENT_1 = 0x63c7606faee0ee9eff230fec391e64c0c82a0277947973ce7f6f1c9088c821dd;
    bytes32 internal constant COMMITMENT_2 = 0x7d6a5ed6ffda210164c11dd6f6fccbd35c4ff70632e845a5bf256e3ec48940b9;
    bytes32 internal constant COMMITMENT_3 = 0xd5a7b4485d1aece18348655132e73c86b23fa0f251adb173f80123d05a914f15;
    bytes32 internal constant COMMITMENT_4 = 0xc5ed165443011bac65df4d0f4240de3429c033996e9fce630a631e117537cd61;

    /// @dev BN254 scalar field modulus (must equal ZiskVerifier._RFIELD).
    uint256 internal constant RFIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev Byte length of the ZiSK public-values preimage.
    uint256 internal constant PUBLIC_VALUES_BYTES = 576;
    /// @dev Word index of `rootCVadcopFinal`, public-values bytes [544..576].
    uint256 internal constant ROOT_C_WORD = 17;
    /// @dev Word index of the first all-zero guest-public slot, bytes [96..544].
    uint256 internal constant FIRST_ZERO_WORD = 3;
    /// @dev Proof word of the first opening evaluation. The words before it
    ///      are the eight G1 commitments.
    uint256 internal constant FIRST_EVALUATION_WORD = 16;

    ZiskVerifier internal ziskVerifier;

    function setUp() public {
        ziskVerifier = new ZiskVerifier(IZiskSnarkVerifier(address(new PilfflonkVerifier())));
    }

    /// @dev Load a 2,208-byte SNARK as the 69 words the SNARK verifier takes.
    function _proof69(bytes memory _proof) internal pure returns (bytes32[ZISK_SNARK_PROOF_LENGTH] memory words) {
        require(_proof.length == ZISK_SNARK_PROOF_LENGTH * 32, "proof length");
        for (uint256 i = 0; i < ZISK_SNARK_PROOF_LENGTH; i++) {
            bytes32 word;
            assembly {
                word := mload(add(add(_proof, 32), mul(i, 32)))
            }
            words[i] = word;
        }
    }

    /// @dev The same 69 words as the dynamic array `ZiskVerifier.verify` takes.
    function _proofWords(bytes memory _proof) internal pure returns (uint256[] memory words) {
        bytes32[ZISK_SNARK_PROOF_LENGTH] memory fixedWords = _proof69(_proof);
        words = new uint256[](ZISK_SNARK_PROOF_LENGTH);
        for (uint256 i = 0; i < ZISK_SNARK_PROOF_LENGTH; i++) {
            words[i] = uint256(fixedWords[i]);
        }
    }

    /// @dev Word `_index` of a public-values fixture.
    function _word(bytes memory _publicValues, uint256 _index) internal pure returns (bytes32 word) {
        assembly {
            word := mload(add(_publicValues, add(32, mul(_index, 32))))
        }
    }

    /// @dev A fixture's own single public signal.
    function _signal(bytes memory _publicValues) internal pure returns (uint256) {
        return uint256(sha256(_publicValues)) % RFIELD;
    }

    /// @dev The range's per-batch public inputs as the ZKsync OS lane passes
    ///      them: the untruncated batch commitments. `PUBLIC_INPUT_SHIFT`
    ///      applies once, inside the fold.
    function _rangePublicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](4);
        pis[0] = uint256(COMMITMENT_1);
        pis[1] = uint256(COMMITMENT_2);
        pis[2] = uint256(COMMITMENT_3);
        pis[3] = uint256(COMMITMENT_4);
    }

    /// @dev The exposed wire-form pins are exactly the fixtures' public-values
    ///      bytes [0..32] and [544..576]; the pad bytes and the zero region the
    ///      reconstruction assumes are present in a real aggregated output; and
    ///      the VK hash commits to all three pins.
    function test_pinnedWireForms_and_layout() public view {
        assertEq(BATCH_PUBLIC_VALUES.length, PUBLIC_VALUES_BYTES, "batch fixture length");
        assertEq(AGGREGATED_PUBLIC_VALUES.length, PUBLIC_VALUES_BYTES, "aggregated fixture length");

        // The batch fixture is an inner state-transition proof, so its wire
        // [0..32] holds the inner pin; the aggregated proof attests to the
        // aggregator ELF, so its wire [0..32] holds the aggregator pin.
        assertEq(ziskVerifier.innerProgramVK(), _word(BATCH_PUBLIC_VALUES, 0), "innerProgramVK");
        assertEq(ziskVerifier.aggregatorProgramVK(), _word(AGGREGATED_PUBLIC_VALUES, 0), "aggregatorProgramVK");

        // One cargo-zisk setup produces both proofs, so both wires end with
        // the same vadcop-final root.
        assertEq(ziskVerifier.rootCVadcopFinal(), _word(BATCH_PUBLIC_VALUES, ROOT_C_WORD), "batch rootCVadcopFinal");
        assertEq(
            ziskVerifier.rootCVadcopFinal(),
            _word(AGGREGATED_PUBLIC_VALUES, ROOT_C_WORD),
            "aggregated rootCVadcopFinal"
        );

        // A guest public holds a 32-bit value, so the last four bytes of each
        // of the eight slots the digest occupies are pad.
        for (uint256 slot = 0; slot < 8; slot++) {
            for (uint256 offset = 4; offset < 8; offset++) {
                assertEq(AGGREGATED_PUBLIC_VALUES[32 + slot * 8 + offset], bytes1(0), "digest slot pad");
            }
        }

        // Reconstruction leaves bytes [96..544] zero; the aggregated fixture
        // confirms that region is zero in a real output.
        for (uint256 i = FIRST_ZERO_WORD; i < ROOT_C_WORD; i++) {
            assertEq(_word(AGGREGATED_PUBLIC_VALUES, i), bytes32(0), "zero region");
        }

        assertEq(
            keccak256(
                abi.encodePacked(
                    ziskVerifier.innerProgramVK(),
                    ziskVerifier.aggregatorProgramVK(),
                    ziskVerifier.rootCVadcopFinal()
                )
            ),
            ziskVerifier.verificationKeyHash(),
            "vk hash"
        );
    }

    /// @dev The production path over a real aggregated proof: ZiskVerifier
    ///      reconstructs the 576 public values from its pins and the range's
    ///      batch public inputs, then the vendored pilfflonk verifier checks the
    ///      pairing. Nothing here is mocked.
    function test_realAggregatedProof_reconstructedAndVerified() public view {
        assertTrue(
            ziskVerifier.verify(_rangePublicInputs(), _proofWords(AGGREGATED_PROOF)),
            "aggregated fixture must match the pins and the reconstruction"
        );
    }

    /// @dev A range that differs in one batch reconstructs a different digest,
    ///      hence a different signal, and the real pairing rejects it. This is
    ///      the cross-proof binding enforced by real crypto.
    function test_realAggregatedProof_tamperedRange_rejected() public view {
        uint256[] memory pis = _rangePublicInputs();
        pis[2] ^= 1;
        assertFalse(ziskVerifier.verify(pis, _proofWords(AGGREGATED_PROOF)));
    }

    /// @dev The vendored pilfflonk verifier accepts a real inner proof for its
    ///      own signal — anchoring the pairing, the sha256 field-reduction and
    ///      the preimage byte order on the per-batch side too.
    function test_realProof_fixtureSignal_accepts() public view {
        assertTrue(
            ziskVerifier.SNARK_VERIFIER().verifyProof(_proof69(BATCH_PROOF), [_signal(BATCH_PUBLIC_VALUES)]),
            "batch fixture must match the pilfflonk verification key"
        );
    }

    /// @dev Corrupting a proof scalar (an opening evaluation, still a valid
    ///      field element) makes the pairing fail.
    function test_realProof_tamperedSnark_rejected() public view {
        bytes32[ZISK_SNARK_PROOF_LENGTH] memory words = _proof69(BATCH_PROOF);
        words[FIRST_EVALUATION_WORD] ^= bytes32(uint256(1));
        assertFalse(ziskVerifier.SNARK_VERIFIER().verifyProof(words, [_signal(BATCH_PUBLIC_VALUES)]));
    }

    /// @dev Changing the public values changes the signal, so the proof is no
    ///      longer valid for it — the sha256 binding is sound.
    function test_realProof_tamperedPublicValues_rejected() public view {
        bytes memory tampered = BATCH_PUBLIC_VALUES;
        tampered[32] ^= 0x01; // flip a bit of word 1 (the commitment)
        assertFalse(ziskVerifier.SNARK_VERIFIER().verifyProof(_proof69(BATCH_PROOF), [_signal(tampered)]));
    }
}
