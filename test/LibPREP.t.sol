// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {Delegation} from "../src/Delegation.sol";
import {LibPREP} from "../src/LibPREP.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {GasBurnerLib} from "solady/utils/GasBurnerLib.sol";
import {P256} from "solady/utils/P256.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {Delegation} from "../src/Delegation.sol";
import {EntryPoint, MockEntryPoint} from "./utils/mocks/MockEntryPoint.sol";
import {ERC20, MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";

contract SampleTarget {
    uint256 public x;

    function setX(uint256 newX) public {
        x = newX;
    }
}

contract LibPREPTest is SoladyTest {
    using LibRLP for LibRLP.List;

    MockEntryPoint ep;
    MockPaymentToken paymentToken;
    address delegation;
    SampleTarget sampleTarget;

    function setUp() public {
        sampleTarget = new SampleTarget();
        Delegation tempDelegation = new Delegation();
        ep = MockEntryPoint(payable(tempDelegation.ENTRY_POINT()));
        MockEntryPoint tempMockEntryPoint = new MockEntryPoint();
        vm.etch(tempDelegation.ENTRY_POINT(), address(tempMockEntryPoint).code);
        delegation = address(new Delegation());
        paymentToken = new MockPaymentToken();
        _etchP256Verifier();
    }

    struct _TestTemps {
        bytes32 digest;
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint256 x;
        uint256 privateKey;
        bytes32 keyHash;
        bytes32 saltAndDelegation;
    }

    function testPREP() public {
        _TestTemps memory t;
        EntryPoint.UserOp memory u;

        Delegation d = Delegation(payable(delegation));

        {
            Delegation.Key memory k;
            k.keyType = Delegation.KeyType.P256;
            t.privateKey = _randomUniform() & type(uint192).max;
            (uint256 x, uint256 y) = vm.publicKeyP256(t.privateKey);
            k.publicKey = abi.encode(x, y);
            k.isSuperAdmin = true;
            t.keyHash = d.hash(k);

            Delegation.Call[] memory initCalls = new Delegation.Call[](1);
            initCalls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, k);

            (t.saltAndDelegation, u.eoa) = _mine(_computePREPDigest(initCalls));
            u.initData = abi.encode(initCalls, abi.encodePacked(t.saltAndDelegation));
        }

        t.x = _randomUniform();
        Delegation.Call[] memory calls = new Delegation.Call[](1);
        calls[0].target = address(sampleTarget);
        calls[0].data = abi.encodeWithSelector(SampleTarget.setX.selector, t.x);

        u.nonce = 0xc1d0 << 240;
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 1 ether;
        u.paymentMaxAmount = type(uint128).max;
        u.combinedGas = 10000000;
        u.executionData = abi.encode(calls);
        u.signature = _secp256r1Sig(t.privateKey, t.keyHash, u);

        paymentToken.mint(u.eoa, type(uint128).max);

        vm.etch(u.eoa, abi.encodePacked(hex"ef0100", delegation));
        assertEq(ep.execute(abi.encode(u)), 0);

        assertEq(sampleTarget.x(), t.x);

        assertTrue(LibPREP.isPREP(u.eoa, Delegation(payable(u.eoa)).rPREP()));
    }

    function _secp256r1Sig(uint256 privateKey, bytes32 keyHash, EntryPoint.UserOp memory u)
        internal
        view
        returns (bytes memory)
    {
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, ep.computeDigest(u));
        s = P256.normalized(s);
        return abi.encodePacked(abi.encode(r, s), keyHash, uint8(0));
    }

    function _computePREPDigest(Delegation.Call[] memory calls) internal pure returns (bytes32) {
        bytes32[] memory a = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            a[i] = keccak256(
                abi.encode(
                    keccak256("Call(address target,uint256 value,bytes data)"),
                    bytes32(uint256(uint160(calls[i].target))),
                    bytes32(calls[i].value),
                    keccak256(calls[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(a));
    }

    function _mine(bytes32 digest) internal returns (bytes32 saltAndDelegation, address eoa) {
        bytes32 saltRandomnessSeed = bytes32(_randomUniform());
        bytes32 h = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(delegation).p(0).encode()));
        uint96 salt;
        while (true) {
            salt = uint96(uint256(saltRandomnessSeed));
            bytes32 r =
                EfficientHashLib.hash(uint256(digest), salt) & bytes32(uint256(2 ** 160 - 1));
            bytes32 s = EfficientHashLib.hash(r);
            eoa = ecrecover(h, 27, r, s);
            if (eoa != address(0)) break;
            saltRandomnessSeed = EfficientHashLib.hash(saltRandomnessSeed);
        }
        saltAndDelegation = bytes32((uint256(salt) << 160) | uint160(delegation));
    }

    function _etchP256Verifier() internal {
        bytes memory verifierBytecode =
            hex"3d604052610216565b60008060006ffffffffeffffffffffffffffffffffff60601b19808687098188890982838389096004098384858485093d510985868b8c096003090891508384828308850385848509089650838485858609600809850385868a880385088509089550505050808188880960020991505093509350939050565b81513d83015160408401516ffffffffeffffffffffffffffffffffff60601b19808384098183840982838388096004098384858485093d510985868a8b096003090896508384828308850385898a09089150610102848587890960020985868787880960080987038788878a0387088c0908848b523d8b015260408a0152565b505050505050505050565b81513d830151604084015185513d87015160408801518361013d578287523d870182905260408701819052610102565b80610157578587523d870185905260408701849052610102565b6ffffffffeffffffffffffffffffffffff60601b19808586098183840982818a099850828385830989099750508188830383838809089450818783038384898509870908935050826101be57836101be576101b28a89610082565b50505050505050505050565b808485098181860982828a09985082838a8b0884038483860386898a09080891506102088384868a0988098485848c09860386878789038f088a0908848d523d8d015260408c0152565b505050505050505050505050565b6020357fffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc6325513d6040357f7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a88111156102695782035b60206108005260206108205260206108405280610860526002830361088052826108a0526ffffffffeffffffffffffffffffffffff60601b198060031860205260603560803560203d60c061080060055afa60203d1416837f5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b8585873d5189898a09080908848384091484831085851016888710871510898b108b151016609f3611161616166103195760206080f35b60809182523d820152600160c08190527f6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2966102009081527f4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f53d909101526102405261038992509050610100610082565b610397610200610400610082565b6103a7610100608061018061010d565b6103b7610200608061028061010d565b6103c861020061010061030061010d565b6103d961020061018061038061010d565b6103e9610400608061048061010d565b6103fa61040061010061050061010d565b61040b61040061018061058061010d565b61041c61040061020061060061010d565b61042c610600608061068061010d565b61043d61060061010061070061010d565b61044e61060061018061078061010d565b81815182350982825185098283846ffffffffeffffffffffffffffffffffff60601b193d515b82156105245781858609828485098384838809600409848586848509860986878a8b096003090885868384088703878384090886878887880960080988038889848b03870885090887888a8d096002098882830996508881820995508889888509600409945088898a8889098a098a8b86870960030908935088898687088a038a868709089a5088898284096002099950505050858687868709600809870387888b8a0386088409089850505050505b61018086891b60f71c16610600888a1b60f51c16176040810151801585151715610564578061055357506105fe565b81513d8301519750955093506105fe565b83858609848283098581890986878584098b0991508681880388858851090887838903898a8c88093d8a015109089350836105b957806105b9576105a9898c8c610008565b9a509b50995050505050506105fe565b8781820988818309898285099350898a8586088b038b838d038d8a8b0908089b50898a8287098b038b8c8f8e0388088909089c5050508788868b098209985050505050505b5082156106af5781858609828485098384838809600409848586848509860986878a8b096003090885868384088703878384090886878887880960080988038889848b03870885090887888a8d096002098882830996508881820995508889888509600409945088898a8889098a098a8b86870960030908935088898687088a038a868709089a5088898284096002099950505050858687868709600809870387888b8a0386088409089850505050505b61018086891b60f51c16610600888a1b60f31c161760408101518015851517156106ef57806106de5750610789565b81513d830151975095509350610789565b83858609848283098581890986878584098b0991508681880388858851090887838903898a8c88093d8a01510908935083610744578061074457610734898c8c610008565b9a509b5099505050505050610789565b8781820988818309898285099350898a8586088b038b838d038d8a8b0908089b50898a8287098b038b8c8f8e0388088909089c5050508788868b098209985050505050505b50600488019760fb19016104745750816107a2573d6040f35b81610860526002810361088052806108a0523d3d60c061080060055afa898983843d513d510987090614163d525050505050505050503d3df3fea264697066735822122063ce32ec0e56e7893a1f6101795ce2e38aca14dd12adb703c71fe3bee27da71e64736f6c634300081a0033";
        vm.etch(address(0x100), verifierBytecode);
    }

    function testEIP7702StructHash(address dele) public pure {
        bytes32 expected = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(dele).p(0).encode()));
        bytes32 result;
        assembly ("memory-safe") {
            mstore(0x20, 0x80)
            mstore(0x1f, dele)
            mstore(0x0b, 0x05d78094)
            result := keccak256(0x27, 0x19)
        }
        assertEq(result, expected);
    }
}
