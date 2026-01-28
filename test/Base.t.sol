// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {GasBurnerLib} from "solady/utils/GasBurnerLib.sol";
import {P256} from "solady/utils/P256.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {IthacaAccount, MockAccount} from "./utils/mocks/MockAccount.sol";
import {Orchestrator, MockOrchestrator} from "./utils/mocks/MockOrchestrator.sol";
import {ERC20, MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";
import {GuardedExecutor} from "../src/IthacaAccount.sol";

import {IOrchestrator} from "../src/interfaces/IOrchestrator.sol";
import {Simulator} from "../src/Simulator.sol";
import {ICommon} from "../src/interfaces/ICommon.sol";

contract BaseTest is SoladyTest {
    using LibRLP for LibRLP.List;

    MockOrchestrator oc;
    MockPaymentToken paymentToken;
    address accountImplementation;
    MockAccount account;
    EIP7702Proxy eip7702Proxy;
    TargetFunctionPayload[] targetFunctionPayloads;
    Simulator simulator;

    struct TargetFunctionPayload {
        address by;
        uint256 value;
        bytes data;
    }

    bytes32 internal constant _ANY_KEYHASH =
        0x3232323232323232323232323232323232323232323232323232323232323232;

    address internal constant _ANY_TARGET = 0x3232323232323232323232323232323232323232;

    bytes4 internal constant _ANY_FN_SEL = 0x32323232;

    bytes4 internal constant _EMPTY_CALLDATA_FN_SEL = 0xe0e0e0e0;

    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant _ERC7821_BATCH_EXECUTION_MODE =
        0x0100000000007821000100000000000000000000000000000000000000000000;

    bytes32 internal constant _ERC7579_DELEGATE_CALL_MODE =
        0xff00000000000000000000000000000000000000000000000000000000000000;

    address internal constant _ORIGIN_ADDRESS = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    struct PassKey {
        IthacaAccount.Key k;
        uint256 privateKey;
        bytes32 keyHash;
    }

    struct MultiSigKey {
        IthacaAccount.Key k;
        uint256 threshold;
        PassKey[] owners;
    }

    struct DelegatedEOA {
        address eoa;
        uint256 privateKey;
        MockAccount d;
    }

    function setUp() public virtual {
        oc = new MockOrchestrator();
        paymentToken = new MockPaymentToken();
        accountImplementation = address(new MockAccount(address(oc)));
        eip7702Proxy =
            EIP7702Proxy(payable(LibEIP7702.deployProxy(accountImplementation, address(this))));
        account = MockAccount(payable(eip7702Proxy));
        simulator = new Simulator();

        _etchP256Verifier();
    }

    function targetFunction(bytes memory data) public payable {
        targetFunctionPayloads.push(TargetFunctionPayload(msg.sender, msg.value, data));
    }

    function _setEIP7702Delegation(address eoa) internal {
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(account)));
    }

    function _randomEIP7702DelegatedEOA() internal returns (DelegatedEOA memory d) {
        (d.eoa, d.privateKey) = _randomUniqueSigner();
        _setEIP7702Delegation(d.eoa);
        d.d = MockAccount(payable(d.eoa));
    }

    function _hash(IthacaAccount.Key memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint8(k.keyType), keccak256(k.publicKey)));
    }

    function _randomPassKey() internal returns (PassKey memory) {
        if (_randomChance(2)) return _randomSecp256r1PassKey();
        return _randomSecp256k1PassKey();
    }

    function _randomSecp256r1PassKey() internal returns (PassKey memory k) {
        k.k.keyType = IthacaAccount.KeyType.P256;
        k.privateKey = _randomUniform() & type(uint192).max;
        (uint256 x, uint256 y) = vm.publicKeyP256(k.privateKey);
        k.k.publicKey = abi.encode(x, y);
        k.keyHash = _hash(k.k);
    }

    function _randomSecp256k1PassKey() internal returns (PassKey memory k) {
        k.k.keyType = IthacaAccount.KeyType.Secp256k1;
        address addr;
        (addr, k.privateKey) = _randomUniqueSigner();
        k.k.publicKey = abi.encode(addr);
        k.keyHash = _hash(k.k);
    }

    function _sig(DelegatedEOA memory d, Orchestrator.Intent memory i)
        internal
        view
        returns (bytes memory)
    {
        return _eoaSig(d.privateKey, i);
    }

    function _sig(DelegatedEOA memory d, bytes32 digest) internal pure returns (bytes memory) {
        return _eoaSig(d.privateKey, digest);
    }

    function _eoaSig(uint256 privateKey, Orchestrator.Intent memory i)
        internal
        view
        returns (bytes memory)
    {
        return _eoaSig(privateKey, oc.computeDigest(i));
    }

    function _eoaSig(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sig(PassKey memory k, Orchestrator.Intent memory i)
        internal
        view
        returns (bytes memory)
    {
        return _sig(k, false, oc.computeDigest(i));
    }

    function _sig(PassKey memory k, bytes32 digest) internal pure returns (bytes memory) {
        return _sig(k, false, digest);
    }

    function _sig(PassKey memory k, bool prehash, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        if (k.k.keyType == IthacaAccount.KeyType.P256) {
            return _secp256r1Sig(k.privateKey, k.keyHash, prehash, digest);
        }
        if (k.k.keyType == IthacaAccount.KeyType.Secp256k1) {
            return _secp256k1Sig(k.privateKey, k.keyHash, prehash, digest);
        }
        revert("Unsupported");
    }

    function _sig(MultiSigKey memory k, bytes32 digest) internal pure returns (bytes memory) {
        return _multiSig(k, _hash(k.k), false, digest);
    }

    function _sig(MultiSigKey memory k, Orchestrator.Intent memory u)
        internal
        view
        returns (bytes memory)
    {
        return _multiSig(k, _hash(k.k), false, oc.computeDigest(u));
    }

    function _sig(MultiSigKey memory k, bool prehash, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        return _multiSig(k, _hash(k.k), prehash, digest);
    }

    function _secp256r1Sig(uint256 privateKey, bytes32 keyHash, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        return _secp256r1Sig(privateKey, keyHash, false, digest);
    }

    function _secp256r1Sig(uint256 privateKey, bytes32 keyHash, bool prehash, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, digest);
        s = P256.normalized(s);
        return abi.encodePacked(abi.encode(r, s), keyHash, uint8(prehash ? 1 : 0));
    }

    function _secp256k1Sig(uint256 privateKey, bytes32 keyHash, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        return _secp256k1Sig(privateKey, keyHash, false, digest);
    }

    function _secp256k1Sig(uint256 privateKey, bytes32 keyHash, bool prehash, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(abi.encodePacked(r, s, v), keyHash, uint8(prehash ? 1 : 0));
    }

    function _multiSig(MultiSigKey memory k, bytes32 keyHash, bool preHash, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory signatures = new bytes[](k.threshold);
        for (uint256 i; i < k.threshold; ++i) {
            signatures[i] = _sig(k.owners[i], digest);
        }

        return abi.encodePacked(abi.encode(signatures), keyHash, uint8(preHash ? 1 : 0));
    }

    function _estimateGasForEOAKey(Orchestrator.Intent memory i)
        internal
        returns (uint256 gExecute, uint256 gCombined, uint256 gUsed)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
        i.signature = abi.encodePacked(r, s, v);
        return _estimateGas(i);
    }

    function _estimateGas(PassKey memory k, Orchestrator.Intent memory i)
        internal
        returns (uint256 gExecute, uint256 gCombined, uint256 gUsed)
    {
        if (k.k.keyType == IthacaAccount.KeyType.P256) {
            return _estimateGasForSecp256r1Key(k.keyHash, i);
        }
        if (k.k.keyType == IthacaAccount.KeyType.Secp256k1) {
            return _estimateGasForSecp256k1Key(k.keyHash, i);
        }
        revert("Unsupported");
    }

    function _estimateGasForSecp256k1Key(bytes32 keyHash, Orchestrator.Intent memory i)
        internal
        returns (uint256 gExecute, uint256 gCombined, uint256 gUsed)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
        i.signature = abi.encodePacked(abi.encodePacked(r, s, v), keyHash, uint8(0));
        return _estimateGas(i);
    }

    function _estimateGasForSecp256r1Key(bytes32 keyHash, Orchestrator.Intent memory i)
        internal
        returns (uint256 gExecute, uint256 gCombined, uint256 gUsed)
    {
        i.signature = abi.encodePacked(keccak256("a"), keccak256("b"), keyHash, uint8(0));

        return _estimateGas(i);
    }

    function _estimateGasForMultiSigKey(MultiSigKey memory k, Orchestrator.Intent memory u)
        internal
        returns (uint256 gExecute, uint256 gCombined, uint256 gUsed)
    {
        return _estimateGas(
            _EstimateGasParams({
                u: u,
                paymentPerGasPrecision: 0,
                paymentPerGas: 1,
                combinedGasIncrement: 110_000,
                combinedGasVerificationOffset: 10_000 * k.threshold
            })
        );
    }

    function _estimateGas(Orchestrator.Intent memory i)
        internal
        returns (uint256 gExecute, uint256 gCombined, uint256 gUsed)
    {
        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (gUsed, gCombined) =
            simulator.simulateV1Logs(address(oc), 0, 1, 11_000, 10_000, abi.encode(i));

        // gExecute > (100k + combinedGas) * 64/63
        gExecute = Math.mulDiv(gCombined + 110_000, 64, 63);

        vm.revertToStateAndDelete(snapshot);

        gExecute = Math.mulDiv(gCombined + 110_000, 64, 63) + 30_000;
    }

    struct _EstimateGasParams {
        Orchestrator.Intent u;
        uint8 paymentPerGasPrecision;
        uint256 paymentPerGas;
        uint256 combinedGasIncrement;
        uint256 combinedGasVerificationOffset;
    }

    function _estimateGas(_EstimateGasParams memory p)
        internal
        returns (uint256 gExecute, uint256 gCombined, uint256 gUsed)
    {
        {
            uint256 snapshot = vm.snapshotState();

            // Set the simulator to have max balance, so that it can run in state override mode.
            // This is meant to mimic an offchain state override.
            vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

            (gUsed, gCombined) = simulator.simulateV1Logs(
                address(oc),
                p.paymentPerGasPrecision,
                p.paymentPerGas,
                p.combinedGasIncrement,
                p.combinedGasVerificationOffset,
                abi.encode(p.u)
            );
            vm.revertToStateAndDelete(snapshot);
        }

        // gExecute > (100k + combinedGas) * 64/63
        gExecute = Math.mulDiv(gCombined + 110_000, 64, 63) + 30_000;
    }

    function _mint(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            vm.deal(to, amount);
        } else {
            MockPaymentToken(token).mint(to, amount);
        }
    }

    function _balanceOf(address token, address owner) internal view returns (uint256) {
        if (token == address(0)) {
            return address(owner).balance;
        } else {
            return MockPaymentToken(token).balanceOf(owner);
        }
    }

    function _transferCall(address token, address to, uint256 amount)
        internal
        pure
        returns (ERC7821.Call memory c)
    {
        if (token == address(0)) {
            c.to = to;
            c.value = amount;
        } else {
            c.to = token;
            c.data = abi.encodeWithSignature("transfer(address,uint256)", to, amount);
        }
    }

    function _setSpendLimitCall(
        PassKey memory k,
        address token,
        GuardedExecutor.SpendPeriod period,
        uint256 amount
    ) internal pure returns (ERC7821.Call memory c) {
        c.data = abi.encodeWithSelector(
            GuardedExecutor.setSpendLimit.selector, k.keyHash, token, period, amount
        );
    }

    function _removeSpendLimitCall(
        PassKey memory k,
        address token,
        GuardedExecutor.SpendPeriod period
    ) internal pure returns (ERC7821.Call memory c) {
        c.data = abi.encodeWithSelector(
            GuardedExecutor.removeSpendLimit.selector, k.keyHash, token, period
        );
    }

    function _transferExecutionData(address token, address to, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        return _encode(_transferCall(token, to, amount));
    }

    function _thisTargetFunctionCall(uint256 value, bytes memory data)
        internal
        view
        returns (ERC7821.Call memory c)
    {
        c.to = address(this);
        c.value = value;
        c.data = abi.encodeWithSignature("targetFunction(bytes)", data);
    }

    function _thisTargetFunctionExecutionData(uint256 value, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        return _encode(_thisTargetFunctionCall(value, data));
    }

    function _encode(ERC7821.Call memory c) internal pure returns (bytes memory) {
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = c;
        return abi.encode(calls);
    }

    function _executionData(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        ERC7821.Call memory c;
        c.to = target;
        c.value = value;
        c.data = data;
        return _encode(c);
    }

    function _executionData(address target, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        return _executionData(target, 0, data);
    }

    function _randomTarget() internal returns (address) {
        if (_randomChance(32)) return _ANY_TARGET;
        return address(uint160(_randomUniform()));
    }

    function _randomFnSel() internal returns (bytes4) {
        if (_randomChance(32)) return _ANY_FN_SEL;
        return bytes4(bytes32(_randomUniform()));
    }

    function _hasP256Verifier() internal view returns (bool result) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x532eaabd9574880dbf76b9b8cc00832c20a6ec113d682299550d7a6e0f345e25) // `hash`.
            mstore(add(m, 0x20), 0x5) // `r`.
            mstore(add(m, 0x40), 0x1) // `s`.
            mstore(add(m, 0x60), 0x4a03ef9f92eb268cafa601072489a56380fa0dc43171d7712813b3a19a1eb5e5) // `x`.
            mstore(add(m, 0x80), 0x3e213e28a608ce9a2f4a17fd830c6654018a79b3e0263d91a8ba90622df6f2f0) // `y`.
            mstore(0x00, 0)
            pop(staticcall(gas(), 0x100, m, 0xa0, 0x00, 0x20))
            result := eq(1, mload(0x00))
        }
    }

    function _etchP256Verifier() internal {
        if (_hasP256Verifier()) return;
        bytes memory verifierBytecode =
            hex"3d604052610216565b60008060006ffffffffeffffffffffffffffffffffff60601b19808687098188890982838389096004098384858485093d510985868b8c096003090891508384828308850385848509089650838485858609600809850385868a880385088509089550505050808188880960020991505093509350939050565b81513d83015160408401516ffffffffeffffffffffffffffffffffff60601b19808384098183840982838388096004098384858485093d510985868a8b096003090896508384828308850385898a09089150610102848587890960020985868787880960080987038788878a0387088c0908848b523d8b015260408a0152565b505050505050505050565b81513d830151604084015185513d87015160408801518361013d578287523d870182905260408701819052610102565b80610157578587523d870185905260408701849052610102565b6ffffffffeffffffffffffffffffffffff60601b19808586098183840982818a099850828385830989099750508188830383838809089450818783038384898509870908935050826101be57836101be576101b28a89610082565b50505050505050505050565b808485098181860982828a09985082838a8b0884038483860386898a09080891506102088384868a0988098485848c09860386878789038f088a0908848d523d8d015260408c0152565b505050505050505050505050565b6020357fffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc6325513d6040357f7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a88111156102695782035b60206108005260206108205260206108405280610860526002830361088052826108a0526ffffffffeffffffffffffffffffffffff60601b198060031860205260603560803560203d60c061080060055afa60203d1416837f5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b8585873d5189898a09080908848384091484831085851016888710871510898b108b151016609f3611161616166103195760206080f35b60809182523d820152600160c08190527f6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2966102009081527f4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f53d909101526102405261038992509050610100610082565b610397610200610400610082565b6103a7610100608061018061010d565b6103b7610200608061028061010d565b6103c861020061010061030061010d565b6103d961020061018061038061010d565b6103e9610400608061048061010d565b6103fa61040061010061050061010d565b61040b61040061018061058061010d565b61041c61040061020061060061010d565b61042c610600608061068061010d565b61043d61060061010061070061010d565b61044e61060061018061078061010d565b81815182350982825185098283846ffffffffeffffffffffffffffffffffff60601b193d515b82156105245781858609828485098384838809600409848586848509860986878a8b096003090885868384088703878384090886878887880960080988038889848b03870885090887888a8d096002098882830996508881820995508889888509600409945088898a8889098a098a8b86870960030908935088898687088a038a868709089a5088898284096002099950505050858687868709600809870387888b8a0386088409089850505050505b61018086891b60f71c16610600888a1b60f51c16176040810151801585151715610564578061055357506105fe565b81513d8301519750955093506105fe565b83858609848283098581890986878584098b0991508681880388858851090887838903898a8c88093d8a015109089350836105b957806105b9576105a9898c8c610008565b9a509b50995050505050506105fe565b8781820988818309898285099350898a8586088b038b838d038d8a8b0908089b50898a8287098b038b8c8f8e0388088909089c5050508788868b098209985050505050505b5082156106af5781858609828485098384838809600409848586848509860986878a8b096003090885868384088703878384090886878887880960080988038889848b03870885090887888a8d096002098882830996508881820995508889888509600409945088898a8889098a098a8b86870960030908935088898687088a038a868709089a5088898284096002099950505050858687868709600809870387888b8a0386088409089850505050505b61018086891b60f51c16610600888a1b60f31c161760408101518015851517156106ef57806106de5750610789565b81513d830151975095509350610789565b83858609848283098581890986878584098b0991508681880388858851090887838903898a8c88093d8a01510908935083610744578061074457610734898c8c610008565b9a509b5099505050505050610789565b8781820988818309898285099350898a8586088b038b838d038d8a8b0908089b50898a8287098b038b8c8f8e0388088909089c5050508788868b098209985050505050505b50600488019760fb19016104745750816107a2573d6040f35b81610860526002810361088052806108a0523d3d60c061080060055afa898983843d513d510987090614163d525050505050505050503d3df3fea264697066735822122063ce32ec0e56e7893a1f6101795ce2e38aca14dd12adb703c71fe3bee27da71e64736f6c634300081a0033";
        vm.etch(address(0x100), verifierBytecode);
    }
}
