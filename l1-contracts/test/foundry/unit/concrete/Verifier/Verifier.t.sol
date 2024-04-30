// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Verifier} from "contracts/state-transition/Verifier.sol";
import {VerifierTest} from "contracts/dev-contracts/test/VerifierTest.sol";

contract VerifierTestTest is Test {
    uint256 Q_MOD = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 R_MOD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    uint256[] public publicInputs;
    uint256[] public serializedProof;
    uint256[] public recursiveAggregationInput;

    Verifier public verifier;

    function setUp() public virtual {
        publicInputs.push(17257057577815541751225964212897374444694342989384539141520877492729);

        serializedProof.push(10032255692304426541958487424837706541667730769782503366592797609781788557424);
        serializedProof.push(11856023086316274558845067687080284266010851703055534566998849536424959073766);
        serializedProof.push(1946976494418613232642071265529572704802622739887191787991738703483400525159);
        serializedProof.push(1328106069458824013351862477593422369726189688844441245167676630500797673929);
        serializedProof.push(15488976127650523079605218040232167291115155239002840072043251018873550258833);
        serializedProof.push(4352460820258659596860226525221943504756149602617718032378962471842121872064);
        serializedProof.push(10499239305859992443759785453270906003243074359959242371675950941500942473773);
        serializedProof.push(21347231097799123231227724221565041889687686131480556177475242020711996173235);
        serializedProof.push(21448274562455512652922184359722637546669181231038098300951155169465175447933);
        serializedProof.push(5224615512030263722410009061780530125927659699046094954022444377569738464640);
        serializedProof.push(457781538876079938778845275495204146302569607395268192839148474821758081582);
        serializedProof.push(18861735728246155975127314860333796285284072325207684293054713266899263027595);
        serializedProof.push(16303944945368742900183889655415585360236645961122617249176044814801835577336);
        serializedProof.push(13035945439947210396602249585896632733250124877036427100939804737514358838409);
        serializedProof.push(5344210729159253547334947774998425118220137275601995670629358314205854915831);
        serializedProof.push(5798533246034358556434877465898581616792677631188370022078168611592512620805);
        serializedProof.push(17389657286129893116489015409587246992530648956814855147744210777822507444908);
        serializedProof.push(2287244647342394712608648573347732257083870498255199596324312699868511383792);
        serializedProof.push(4008043766112513713076111464601725311991199944328610186851424132679188418647);
        serializedProof.push(1192776719848445147414966176395169615865534126881763324071908049917030138759);
        serializedProof.push(21297794452895123333253856666749932934399762330444876027734824957603009458926);
        serializedProof.push(17125994169200693606182326100834606153690416627082476471630567824088261322122);
        serializedProof.push(13696978282153979214307382954559709118587582183649354744253374201589715565327);
        serializedProof.push(19885518441500677676836488338931187143852666523909650686513498826535451677070);
        serializedProof.push(1205434280320863211046275554464591162919269140938371417889032165323835178587);
        serializedProof.push(17633172995805911347980792921300006225132501482343225088847242025756974009163);
        serializedProof.push(16438080406761371143473961144300947125022788905488819913014533292593141026205);
        serializedProof.push(5069081552536259237104332491140391551180511112980430307676595350165020188468);
        serializedProof.push(21217317205917200275887696442048162383709998732382676029165079037795626916156);
        serializedProof.push(19474466610515117278975027596198570980840609656738255347763182823792179771539);
        serializedProof.push(9744176601826774967534277982058590459006781888895542911226406188087317156914);
        serializedProof.push(13171230402193025939763214267878900142876558410430734782028402821166810894141);
        serializedProof.push(11775403006142607980192261369108550982244126464568678337528680604943636677964);
        serializedProof.push(6903612341636669639883555213872265187697278660090786759295896380793937349335);
        serializedProof.push(10197105415769290664169006387603164525075746474380469980600306405504981186043);
        serializedProof.push(10143152486514437388737642096964118742712576889537781270260677795662183637771);
        serializedProof.push(7662095231333811948165764727904932118187491073896301295018543320499906824310);
        serializedProof.push(929422796511992741418500336817719055655694499787310043166783539202506987065);
        serializedProof.push(13837024938095280064325737989251964639823205065380219552242839155123572433059);
        serializedProof.push(11738888513780631372636453609299803548810759208935038785934252961078387526204);
        serializedProof.push(16528875312985292109940444015943812939751717229020635856725059316776921546668);
        serializedProof.push(17525167117689648878398809303253004706004801107861280044640132822626802938868);
        serializedProof.push(7419167499813234488108910149511390953153207250610705609008080038658070088540);
        serializedProof.push(11628425014048216611195735618191126626331446742771562481735017471681943914146);

        verifier = new VerifierTest();
    }

    function testShouldVerify() public view {
        bool success = verifier.verify(publicInputs, serializedProof, recursiveAggregationInput);
        assert(success);
    }

    function testShouldVerifyWithDirtyBits() public view {
        uint256[] memory newPublicInputs = publicInputs;
        newPublicInputs[0] += uint256(bytes32(0xe000000000000000000000000000000000000000000000000000000000000000));

        bool success = verifier.verify(newPublicInputs, serializedProof, recursiveAggregationInput);
        assert(success);
    }

    function testEllipticCurvePointsOverModulo() public view {
        uint256[] memory newSerializedProof = serializedProof;
        newSerializedProof[0] += Q_MOD;
        newSerializedProof[1] += Q_MOD;
        newSerializedProof[1] += Q_MOD;

        bool success = verifier.verify(publicInputs, newSerializedProof, recursiveAggregationInput);
        assert(success);
    }

    function testFrOverModulo() public view {
        uint256[] memory newSerializedProof = serializedProof;
        newSerializedProof[22] += R_MOD;

        bool success = verifier.verify(publicInputs, newSerializedProof, recursiveAggregationInput);
        assert(success);
    }

    function testMoreThanOnePublicInput_shouldRevert() public {
        uint256[] memory newPublicInputs = new uint256[](2);
        newPublicInputs[0] = publicInputs[0];
        newPublicInputs[1] = publicInputs[0];

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(newPublicInputs, serializedProof, recursiveAggregationInput);
    }

    function testEmptyPublicInput_shouldRevert() public {
        uint256[] memory newPublicInputs;

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(newPublicInputs, serializedProof, recursiveAggregationInput);
    }

    function testMoreThan44WordsProof_shouldRevert() public {
        uint256[] memory newSerializedProof = new uint256[](serializedProof.length + 1);

        for (uint256 i = 0; i < serializedProof.length; i++) {
            newSerializedProof[i] = serializedProof[i];
        }
        newSerializedProof[newSerializedProof.length - 1] = serializedProof[serializedProof.length - 1];

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(publicInputs, newSerializedProof, recursiveAggregationInput);
    }

    function testEmptyProof_shouldRevert() public {
        uint256[] memory newSerializedProof;

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(publicInputs, newSerializedProof, recursiveAggregationInput);
    }

    function testNotEmptyRecursiveAggregationInput_shouldRevert() public {
        uint256[] memory newRecursiveAggregationInput = publicInputs;

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(publicInputs, serializedProof, newRecursiveAggregationInput);
    }

    function testEllipticCurvePointAtInfinity_shouldRevert() public {
        uint256[] memory newSerializedProof = serializedProof;
        newSerializedProof[0] = 0;
        newSerializedProof[1] = 0;

        vm.expectRevert(bytes("loadProof: Proof is invalid"));
        verifier.verify(publicInputs, newSerializedProof, recursiveAggregationInput);
    }

    function testInvalidPublicInput_shouldRevert() public {
        uint256[] memory newPublicInputs = publicInputs;
        newPublicInputs[0] = 0;

        vm.expectRevert(bytes("invalid quotient evaluation"));
        verifier.verify(newPublicInputs, serializedProof, recursiveAggregationInput);
    }

    function testVerificationKeyHash() public virtual {
        bytes32 verificationKeyHash = verifier.verificationKeyHash();
        assertEq(verificationKeyHash, 0x6625fa96781746787b58306d414b1e25bd706d37d883a9b3acf57b2bd5e0de52);
    }
}
