// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {GasBurnerLib} from "solady/utils/GasBurnerLib.sol";
import {P256} from "solady/utils/P256.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {Delegation} from "../src/Delegation.sol";
import {EntryPoint, MockEntryPoint} from "./utils/mocks/MockEntryPoint.sol";
import {ERC20, MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";

contract GasBurner {
    uint256 public randomness;

    function setRandomness(uint256 r) public {
        randomness = r;
    }

    function burnGas(uint256 x, uint256 r) public {
        if (r & 1 == 0) {
            GasBurnerLib.burnPure(x);
        } else {
            this.burnGas(x, r >> 1);
        }
        randomness = r;
    }
}

contract EntryPointTest is SoladyTest {
    MockEntryPoint ep;
    MockPaymentToken paymentToken;
    address delegation;
    GasBurner gasBurner;

    TargetFunctionPayload[] targetFunctionPayloads;

    struct TargetFunctionPayload {
        address by;
        uint256 value;
        bytes data;
    }

    function setUp() public {
        gasBurner = new GasBurner();
        Delegation tempDelegation = new Delegation();
        ep = MockEntryPoint(payable(tempDelegation.ENTRY_POINT()));
        MockEntryPoint tempMockEntryPoint = new MockEntryPoint();
        vm.etch(tempDelegation.ENTRY_POINT(), address(tempMockEntryPoint).code);
        delegation = LibClone.clone(address(new Delegation()));
        paymentToken = new MockPaymentToken();
    }
    // todo
    // function testCreate2DeployEntryPoint() public {
    //     bytes memory initCode = type(EntryPoint).creationCode;
    //     bytes32 salt = 0x0000000000000000000000000000000000000000bfc06f84bf20de038dba3888;
    //     vm.etch(address(ep), "");
    //     assertEq(address(ep), _nicksCreate2(0, salt, initCode));
    // }

    function targetFunction(bytes memory data) public payable {
        targetFunctionPayloads.push(TargetFunctionPayload(msg.sender, msg.value, data));
    }

    struct _TestFullFlowTemps {
        EntryPoint.UserOp[] userOps;
        TargetFunctionPayload[] targetFunctionPayloads;
        uint256[] privateKeys;
        bytes[] encodedUserOps;
    }

    function testFullFlow(uint256) public {
        _TestFullFlowTemps memory t;

        t.userOps = new EntryPoint.UserOp[](_random() & 3);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.userOps.length);
        t.privateKeys = new uint256[](t.userOps.length);
        t.encodedUserOps = new bytes[](t.userOps.length);

        for (uint256 i; i != t.userOps.length; ++i) {
            EntryPoint.UserOp memory u = t.userOps[i];
            (u.eoa, t.privateKeys[i]) = _randomUniqueSigner();
            vm.etch(u.eoa, delegation.code);
            vm.deal(u.eoa, 2 ** 128 - 1);
            u.executionData = _getExecutionDataForThisTargetFunction(
                t.targetFunctionPayloads[i].value = _bound(_random(), 0, 2 ** 32 - 1),
                t.targetFunctionPayloads[i].data = _truncateBytes(_randomBytes(), 0xff)
            );
            u.nonce = ep.getNonce(u.eoa, 0);
            paymentToken.mint(u.eoa, 2 ** 128 - 1);
            u.paymentToken = address(paymentToken);
            u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
            u.paymentMaxAmount = u.paymentAmount;
            u.combinedGas = 10000000;
            _fillSecp256k1Signature(u, t.privateKeys[i], bytes32(0x00));
            t.encodedUserOps[i] = abi.encode(u);
        }

        bytes4[] memory errors = ep.execute(t.encodedUserOps);
        assertEq(errors.length, t.userOps.length);
        for (uint256 i; i != errors.length; ++i) {
            assertEq(errors[i], 0);
            assertEq(targetFunctionPayloads[i].by, t.userOps[i].eoa);
            assertEq(targetFunctionPayloads[i].value, t.targetFunctionPayloads[i].value);
            assertEq(targetFunctionPayloads[i].data, t.targetFunctionPayloads[i].data);
        }
    }

    function testExecuteWithUnAuthorizedPayer() public {
        uint256 alice = uint256(keccak256("alicePrivateKey"));

        address aliceAddress = vm.addr(alice);
        uint256 bob = uint256(keccak256("bobPrivateKey"));

        address bobAddress = vm.addr(bob);
        // eip-7702 delegation
        vm.signAndAttachDelegation(delegation, alice);

        // eip-7702 delegation
        vm.signAndAttachDelegation(delegation, bob);

        vm.deal(vm.addr(alice), 10 ether);
        vm.deal(vm.addr(bob), 10 ether);

        paymentToken.mint(aliceAddress, 50 ether);

        bytes memory executionData = _getExecutionData(
            address(paymentToken),
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 1 ether)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: aliceAddress,
            nonce: 0,
            executionData: executionData,
            payer: bobAddress,
            paymentToken: address(paymentToken),
            paymentRecipient: address(0x00),
            paymentAmount: 0.1 ether,
            paymentMaxAmount: 0.5 ether,
            paymentPerGas: 100000 wei,
            combinedGas: 10000000,
            signature: "",
            initData: ""
        });

        bytes32 digest = ep.computeDigest(userOp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice, digest);

        userOp.signature = abi.encodePacked(r, s, v);

        bytes4 err = ep.execute(abi.encode(userOp));
        assertEq(EntryPoint.PaymentError.selector, err);
    }

    struct _SimulateExecute2Temps {
        uint256 gasToBurn;
        uint256 randomness;
        uint256 gExecute;
        uint256 gCombined;
        uint256 gUsed;
        bytes executionData;
        bool success;
        bytes result;
    }

    function testSimulateExecute2WithEOAKey(bytes32) public {
        (address randomSigner, uint256 privateKey) = _randomSigner();

        // eip-7702 delegation
        vm.signAndAttachDelegation(delegation, privateKey);

        paymentToken.mint(randomSigner, 500 ether);

        _SimulateExecute2Temps memory t;

        gasBurner.setRandomness(1); // Warm the storage first.

        t.gasToBurn = _bound(_random(), 0, _randomChance(32) ? 15000000 : 300000);
        do {
            t.randomness = _randomUniform();
        } while (t.randomness == 0);
        emit LogUint("gasToBurn", t.gasToBurn);
        t.executionData = _getExecutionData(
            address(gasBurner),
            0,
            abi.encodeWithSignature("burnGas(uint256,uint256)", t.gasToBurn, t.randomness)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: randomSigner,
            nonce: 0,
            executionData: t.executionData,
            payer: address(0x00),
            paymentToken: address(paymentToken),
            paymentRecipient: address(0x00),
            paymentAmount: 0.1 ether,
            paymentMaxAmount: 0.5 ether,
            paymentPerGas: 1e9,
            combinedGas: 0, // This will be ignored during `simulateExecute2`.
            signature: "",
            initData: ""
        });
        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            userOp.signature = abi.encodePacked(r, s, v);
        }

        (t.success, t.result) =
            address(ep).call(abi.encodeWithSignature("simulateExecute2(bytes)", abi.encode(userOp)));

        assertFalse(t.success);
        assertEq(bytes4(LibBytes.load(t.result, 0x00)), EntryPoint.SimulationResult2.selector);

        t.gExecute = uint256(LibBytes.load(t.result, 0x04));
        t.gCombined = uint256(LibBytes.load(t.result, 0x24));
        t.gUsed = uint256(LibBytes.load(t.result, 0x44));
        emit LogUint("gExecute", t.gExecute);
        emit LogUint("gCombined", t.gCombined);
        emit LogUint("gUsed", t.gUsed);
        assertEq(bytes4(LibBytes.load(t.result, 0x64)), 0);

        userOp.combinedGas = t.gCombined;
        userOp.signature = "";
        _fillSecp256k1Signature(userOp, privateKey, 0);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(userOp)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateExecute2WithP256(bytes32) public {
        uint256 privateKey = _randomUniform() & type(uint128).max;
        address payable eoa = payable(vm.addr(privateKey));

        vm.signAndAttachDelegation(delegation, privateKey);
        vm.deal(eoa, 10 ether);

        _activateRIPPRECOMPILE(true);

        (uint256 x, uint256 y) = vm.publicKeyP256(privateKey);

        Delegation.Key memory key = Delegation.Key({
            expiry: 0,
            keyType: Delegation.KeyType.P256,
            isSuperAdmin: true,
            publicKey: abi.encode(x, y)
        });

        paymentToken.mint(eoa, 50 ether);

        vm.prank(eoa);
        bytes32 keyHash = Delegation(eoa).authorize(key);

        _SimulateExecute2Temps memory t;

        t.gasToBurn = _bound(_random(), 0, _randomChance(32) ? 15000000 : 300000);
        do {
            t.randomness = _randomUniform();
        } while (t.randomness == 0);
        emit LogUint("gasToBurn", t.gasToBurn);
        t.executionData = _getExecutionData(
            address(gasBurner),
            0,
            abi.encodeWithSignature("burnGas(uint256,uint256)", t.gasToBurn, t.randomness)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: eoa,
            nonce: 0,
            executionData: t.executionData,
            payer: address(0x00),
            paymentToken: address(paymentToken),
            paymentRecipient: address(0x00),
            paymentAmount: 0.1 ether,
            paymentMaxAmount: 0.5 ether,
            paymentPerGas: 1e9,
            combinedGas: 0,
            signature: "",
            initData: ""
        });
        // Just fill with some non-zero junk P256 signature that contains the `keyHash`,
        // so that the `simulateExecute2` knows that
        // it needs to add the variance for non-precompile P256 verification.
        // We need the `keyHash` in the signature so that the simulation is able
        // to hit all the gas for the GuardedExecutor stuff for the `keyHash`.
        userOp.signature = abi.encodePacked(keccak256("a"), keccak256("b"), keyHash, uint8(0));

        (t.success, t.result) =
            address(ep).call(abi.encodeWithSignature("simulateExecute2(bytes)", abi.encode(userOp)));

        assertFalse(t.success);
        assertEq(bytes4(LibBytes.load(t.result, 0x00)), EntryPoint.SimulationResult2.selector);

        t.gExecute = uint256(LibBytes.load(t.result, 0x04));
        t.gCombined = uint256(LibBytes.load(t.result, 0x24));
        t.gUsed = uint256(LibBytes.load(t.result, 0x44));
        emit LogUint("gExecute", t.gExecute);
        emit LogUint("gCombined", t.gCombined);
        emit LogUint("gUsed", t.gUsed);
        assertEq(bytes4(LibBytes.load(t.result, 0x64)), 0);

        userOp.combinedGas = t.gCombined;
        userOp.signature = "";
        _fillSecp256r1Signature(userOp, privateKey, keyHash);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(userOp)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testExecuteWithP256Signature() public {
        uint256 alice = uint256(keccak256("alicePrivateKey"));

        address payable aliceAddress = payable(vm.addr(alice));

        vm.signAndAttachDelegation(delegation, alice);
        vm.deal(aliceAddress, 10 ether);

        _activateRIPPRECOMPILE(true);

        (uint256 x, uint256 y) = vm.publicKeyP256(alice);

        Delegation.Key memory key = Delegation.Key({
            expiry: 0,
            keyType: Delegation.KeyType.P256,
            isSuperAdmin: true,
            publicKey: abi.encode(x, y)
        });

        paymentToken.mint(aliceAddress, 50 ether);

        vm.prank(aliceAddress);
        bytes32 keyHash = Delegation(aliceAddress).authorize(key);

        bytes memory executionData = _getExecutionData(
            address(paymentToken),
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 1 ether)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: aliceAddress,
            nonce: 0,
            executionData: executionData,
            payer: address(0x00),
            paymentToken: address(paymentToken),
            paymentRecipient: address(0x00),
            paymentAmount: 0.1 ether,
            paymentMaxAmount: 0.5 ether,
            paymentPerGas: 1e9,
            combinedGas: 1000000,
            signature: "",
            initData: ""
        });

        _fillSecp256r1Signature(userOp, alice, keyHash);

        bytes memory op = abi.encode(userOp);

        (, bytes memory rD) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", op));

        uint256 gUsed;

        assembly ("memory-safe") {
            gUsed := mload(add(rD, 0x24))
        }

        bytes4 err = ep.execute(op);
        assertEq(err, bytes4(0x0000000));
        uint256 actualAmount = (gUsed + 50000) * 1e9;
        assertEq(paymentToken.balanceOf(address(ep)), actualAmount);
        // extra goes back to alice
        assertEq(paymentToken.balanceOf(aliceAddress), 50 ether - actualAmount - 1 ether);
    }

    function testExecuteWith256K1Signature() public {
        uint256 alice = uint256(keccak256("alicePrivateKey"));

        uint256 alice2 = uint256(keccak256("alicePrivateKey2"));

        address payable aliceAddress = payable(vm.addr(alice));

        address alice2Address = payable(vm.addr(alice2));

        vm.signAndAttachDelegation(delegation, alice);
        vm.deal(aliceAddress, 10 ether);

        _activateRIPPRECOMPILE(true);

        Delegation.Key memory key = Delegation.Key({
            expiry: 0,
            keyType: Delegation.KeyType.Secp256k1,
            isSuperAdmin: true,
            publicKey: abi.encode(alice2Address)
        });

        paymentToken.mint(aliceAddress, 50 ether);

        vm.prank(aliceAddress);
        bytes32 keyHash = Delegation(aliceAddress).authorize(key);

        bytes memory executionData = _getExecutionData(
            address(paymentToken),
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 1 ether)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: aliceAddress,
            nonce: 0,
            executionData: executionData,
            payer: address(0x00),
            paymentToken: address(paymentToken),
            paymentRecipient: address(0x00),
            paymentAmount: 0.1 ether,
            paymentMaxAmount: 0.5 ether,
            paymentPerGas: 1e9,
            combinedGas: 1000000,
            signature: "",
            initData: ""
        });

        _fillSecp256k1Signature(userOp, alice2, keyHash);

        bytes memory op = abi.encode(userOp);

        (, bytes memory rD) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", op));

        uint256 gUsed;

        assembly ("memory-safe") {
            gUsed := mload(add(rD, 0x24))
        }

        bytes4 err = ep.execute(op);
        assertEq(err, bytes4(0x0000000));
        uint256 actualAmount = (gUsed + 50000) * 1e9;
        assertEq(paymentToken.balanceOf(address(ep)), actualAmount);
        // extra goes back to alice
        assertEq(paymentToken.balanceOf(aliceAddress), 50 ether - actualAmount - 1 ether);
    }

    function _testExecuteRevertWhenRunOutOfGas() internal {
        uint256 alice = uint256(keccak256("alicePrivateKey"));

        address aliceAddress = vm.addr(alice);
        vm.signAndAttachDelegation(delegation, alice);
        vm.deal(aliceAddress, 10 ether);

        paymentToken.mint(aliceAddress, 50 ether);

        bytes memory executionData = _getExecutionData(
            address(paymentToken),
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 1 ether)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: aliceAddress,
            nonce: 0,
            executionData: executionData,
            payer: address(0x00),
            paymentToken: address(0x00),
            paymentRecipient: address(0xbcde),
            paymentAmount: 0.1 ether,
            paymentMaxAmount: 0.5 ether,
            paymentPerGas: 1 wei,
            combinedGas: 20000,
            signature: "",
            initData: ""
        });

        _fillSecp256k1Signature(userOp, alice, bytes32(0x00));

        /// Run out of gas at verification time
        bytes memory data = abi.encodeWithSignature("execute(bytes)", abi.encode(userOp));
        address _ep = address(ep);
        bytes4 err;
        uint256 startBalance = address(0xbcde).balance;

        uint256 g = gasleft();
        assembly ("memory-safe") {
            pop(call(gas(), _ep, 0, add(data, 0x20), mload(data), 0x00, 0x20))
            g := sub(g, gas())
            err := mload(0)
        }

        // paymentReceipt get paid enough pays for reverted tx
        assertGt((address(0xbcde).balance - startBalance), g / 2);
        assertEq(EntryPoint.VerifiedCallError.selector, err);
        (, err) = ep.nonceStatus(aliceAddress, userOp.nonce);
        assertEq(EntryPoint.VerifiedCallError.selector, err);

        startBalance = address(0xbcde).balance;

        // Run out of gas at _call time
        userOp.nonce++;
        userOp.executionData = _getExecutionData(
            address(paymentToken),
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0x11111), 1 ether)
        );
        userOp.combinedGas = 25000;
        _fillSecp256k1Signature(userOp, alice, bytes32(0x00));
        data = abi.encodeWithSignature("execute(bytes)", abi.encode(userOp));

        g = gasleft();
        assembly ("memory-safe") {
            pop(call(gas(), _ep, 0, add(data, 0x20), mload(data), 0x00, 0x20))
            g := sub(g, gas())
            err := mload(0)
        }
        // paymentReceipt get paid enough pays for reverted tx
        assertGt((address(0xbcde).balance - startBalance), g / 2);
        assertEq(EntryPoint.CallError.selector, err);
        (, err) = ep.nonceStatus(aliceAddress, userOp.nonce);
        assertEq(EntryPoint.CallError.selector, err);

        ep.getNonce(aliceAddress, 0);
    }

    function testExecuteWithPayingERC20TokensWithRefund(bytes32) public {
        (address randomSigner, uint256 privateKey) = _randomSigner();

        // eip-7702 delegation
        vm.signAndAttachDelegation(delegation, privateKey);

        paymentToken.mint(randomSigner, 500 ether);

        bytes memory executionData = _getExecutionData(
            address(paymentToken),
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 1 ether)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: randomSigner,
            nonce: 0,
            executionData: executionData,
            payer: randomSigner,
            paymentToken: address(paymentToken),
            paymentRecipient: address(this),
            paymentAmount: 10 ether,
            paymentMaxAmount: 15 ether,
            paymentPerGas: 1e9,
            combinedGas: 10000000,
            signature: "",
            initData: ""
        });

        bytes32 digest = ep.computeDigest(userOp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        userOp.signature = abi.encodePacked(r, s, v);

        bytes memory op = abi.encode(userOp);

        (, bytes memory rD) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", op));

        uint256 gUsed;

        assembly ("memory-safe") {
            gUsed := mload(add(rD, 0x24))
        }
        bytes4 err = ep.execute(op);
        assertEq(err, bytes4(0x0000000));
        uint256 actualAmount = (gUsed + 50000) * 1e9;
        assertEq(paymentToken.balanceOf(address(this)), actualAmount);
        // extra goes back to signer
        assertEq(paymentToken.balanceOf(randomSigner), 500 ether - actualAmount - 1 ether);
        assertEq(ep.getNonce(randomSigner, 0), 1);
    }

    function testExecuteBatchCalls(uint256 n) public {
        n = _bound(n, 0, _randomChance(64) ? 16 : 3);
        bytes[] memory encodeUserOps = new bytes[](n);

        address[] memory signer = new address[](n);
        uint256[] memory privateKeys = new uint256[](n);
        uint256[] memory gasUsed = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            (signer[i], privateKeys[i]) = _randomUniqueSigner();
            paymentToken.mint(signer[i], 1 ether);
            vm.signAndAttachDelegation(delegation, privateKeys[i]);
            bytes memory executionData = _getExecutionData(
                address(paymentToken),
                0,
                abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 0.5 ether)
            );

            EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
                eoa: signer[i],
                nonce: 0,
                executionData: executionData,
                payer: signer[i],
                paymentToken: address(paymentToken),
                paymentRecipient: address(0xbcde),
                paymentAmount: 0.5 ether,
                paymentMaxAmount: 0.5 ether,
                paymentPerGas: 1e9,
                combinedGas: 10000000,
                signature: "",
                initData: ""
            });

            _fillSecp256k1Signature(userOp, privateKeys[i], bytes32(0x00));
            encodeUserOps[i] = abi.encode(userOp);
            (, bytes memory rD) = address(ep).call(
                abi.encodeWithSignature("simulateExecute(bytes)", encodeUserOps[i])
            );
            uint256 gUsed;

            assembly ("memory-safe") {
                gUsed := mload(add(rD, 0x24))
            }

            gasUsed[i] = gUsed;
        }

        bytes4[] memory errs = ep.execute(encodeUserOps);

        for (uint256 i; i < n; ++i) {
            assertEq(errs[i], bytes4(0x0000000));
            assertEq(ep.getNonce(signer[i], 0), 1);
        }
        assertEq(paymentToken.balanceOf(address(0xabcd)), n * 0.5 ether);
    }

    function testExecuteUserBatchCalls(uint256 n) public {
        n = _bound(n, 0, _randomChance(64) ? 16 : 3);
        (address signer, uint256 privateKey) = _randomUniqueSigner();

        vm.signAndAttachDelegation(delegation, privateKey);

        paymentToken.mint(signer, 100 ether);

        address[] memory target = new address[](n);
        uint256[] memory value = new uint256[](n);
        bytes[] memory data = new bytes[](n);

        for (uint256 i; i < n; ++i) {
            target[i] = address(paymentToken);
            data[i] =
                abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 0.5 ether);
        }

        bytes memory executionData = _getBatchExecutionData(target, value, data);

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: signer,
            nonce: 0,
            executionData: executionData,
            payer: signer,
            paymentToken: address(paymentToken),
            paymentRecipient: address(0xbcde),
            paymentAmount: 10 ether,
            paymentMaxAmount: 10 ether,
            paymentPerGas: 1e9,
            combinedGas: 10000000,
            signature: "",
            initData: ""
        });

        _fillSecp256k1Signature(userOp, privateKey, bytes32(0x00));

        bytes memory encodeUserOps = abi.encode(userOp);
        (, bytes memory rD) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", encodeUserOps));
        uint256 gUsed;

        assembly ("memory-safe") {
            gUsed := mload(add(rD, 0x24))
        }

        bytes4 err = ep.execute(encodeUserOps);

        assertEq(err, bytes4(0x0000000));
        assertEq(paymentToken.balanceOf(address(0xabcd)), 0.5 ether * n);
        assertEq(
            paymentToken.balanceOf(signer), 100 ether - (0.5 ether * n + (gUsed + 50000) * 1e9)
        );
        assertEq(ep.getNonce(signer, 0), 1);
    }

    function testExceuteRevertWithIfPayAmountIsLittle() public {
        (address randomSigner, uint256 privateKey) = _randomSigner();

        // eip-7702 delegation
        vm.signAndAttachDelegation(delegation, privateKey);

        paymentToken.mint(randomSigner, 500 ether);

        bytes memory executionData = _getExecutionData(
            address(paymentToken),
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 1 ether)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: randomSigner,
            nonce: 0,
            executionData: executionData,
            payer: randomSigner,
            paymentToken: address(paymentToken),
            paymentRecipient: address(0x00),
            paymentAmount: 20 ether,
            paymentMaxAmount: 15 ether,
            paymentPerGas: 1e9,
            combinedGas: 10000000,
            signature: "",
            initData: ""
        });

        bytes32 digest = ep.computeDigest(userOp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        userOp.signature = abi.encodePacked(r, s, v);

        bytes memory op = abi.encode(userOp);

        (, bytes memory rD) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", op));

        bytes4 err;
        uint256 gUsed;

        assembly ("memory-safe") {
            err := shl(224, and(mload(add(rD, 0x28)), 0xffffffff))
            gUsed := mload(add(rD, 0x24))
        }

        assertEq(err, EntryPoint.PaymentError.selector);
    }

    struct _TestFillTemps {
        EntryPoint.UserOp userOp;
        bytes32 orderId;
        TargetFunctionPayload targetFunctionPayload;
        uint256 privateKey;
        address fundingToken;
        uint256 fundingAmount;
        bytes originData;
    }

    function testFill(bytes32) public {
        _TestFillTemps memory t;
        t.orderId = bytes32(_random());
        {
            EntryPoint.UserOp memory u = t.userOp;
            (u.eoa, t.privateKey) = _randomSigner();
            vm.etch(u.eoa, delegation.code);
            vm.deal(u.eoa, 2 ** 128 - 1);
            u.executionData = _getExecutionDataForThisTargetFunction(
                t.targetFunctionPayload.value = _bound(_random(), 0, 2 ** 32 - 1),
                t.targetFunctionPayload.data = _truncateBytes(_randomBytes(), 0xff)
            );
            u.nonce = ep.getNonce(u.eoa, 0);
            paymentToken.mint(address(this), 2 ** 128 - 1);
            paymentToken.approve(address(ep), 2 ** 128 - 1);
            t.fundingToken = address(paymentToken);
            t.fundingAmount = _bound(_random(), 0, 2 ** 32 - 1);
            u.paymentToken = address(paymentToken);
            u.paymentAmount = t.fundingAmount;
            u.paymentMaxAmount = u.paymentAmount;
            u.combinedGas = 10000000;
            _fillSecp256k1Signature(u, t.privateKey, bytes32(0x00));
            t.originData = abi.encode(abi.encode(u), t.fundingToken, t.fundingAmount);
        }
        assertEq(ep.fill(t.orderId, t.originData, ""), 0);
        assertEq(ep.orderIdIsFilled(t.orderId), t.orderId != bytes32(0x00));
    }

    function testWithdrawTokens() public {
        vm.startPrank(ep.owner());
        vm.deal(address(ep), 1 ether);
        paymentToken.mint(address(ep), 10 ether);
        ep.withdrawTokens(address(0), address(0xabcd), 1 ether);
        ep.withdrawTokens(address(paymentToken), address(0xabcd), 10 ether);
        vm.stopPrank();
    }

    function _fillSecp256k1Signature(
        EntryPoint.UserOp memory userOp,
        uint256 privateKey,
        bytes32 keyHash
    ) internal view {
        bytes32 digest = ep.computeDigest(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        if (keyHash == bytes32(0x00)) {
            userOp.signature = abi.encodePacked(r, s, v);
        } else {
            userOp.signature = abi.encodePacked(abi.encodePacked(r, s, v), keyHash, uint8(0));
        }
    }

    function _fillSecp256r1Signature(
        EntryPoint.UserOp memory userOp,
        uint256 privateKey,
        bytes32 keyHash
    ) internal view {
        bytes32 digest = ep.computeDigest(userOp);
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, digest);
        assembly ("memory-safe") {
            let n := 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
            if lt(shr(1, n), s) { s := sub(n, s) }
        }
        userOp.signature = abi.encodePacked(abi.encode(r, s), keyHash, uint8(0));
    }

    function _activateRIPPRECOMPILE(bool active) internal {
        bytes memory _VERIFIER_BYTECODE =
            hex"3d604052610216565b60008060006ffffffffeffffffffffffffffffffffff60601b19808687098188890982838389096004098384858485093d510985868b8c096003090891508384828308850385848509089650838485858609600809850385868a880385088509089550505050808188880960020991505093509350939050565b81513d83015160408401516ffffffffeffffffffffffffffffffffff60601b19808384098183840982838388096004098384858485093d510985868a8b096003090896508384828308850385898a09089150610102848587890960020985868787880960080987038788878a0387088c0908848b523d8b015260408a0152565b505050505050505050565b81513d830151604084015185513d87015160408801518361013d578287523d870182905260408701819052610102565b80610157578587523d870185905260408701849052610102565b6ffffffffeffffffffffffffffffffffff60601b19808586098183840982818a099850828385830989099750508188830383838809089450818783038384898509870908935050826101be57836101be576101b28a89610082565b50505050505050505050565b808485098181860982828a09985082838a8b0884038483860386898a09080891506102088384868a0988098485848c09860386878789038f088a0908848d523d8d015260408c0152565b505050505050505050505050565b6020357fffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc6325513d6040357f7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a88111156102695782035b60206108005260206108205260206108405280610860526002830361088052826108a0526ffffffffeffffffffffffffffffffffff60601b198060031860205260603560803560203d60c061080060055afa60203d1416837f5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b8585873d5189898a09080908848384091484831085851016888710871510898b108b151016609f3611161616166103195760206080f35b60809182523d820152600160c08190527f6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2966102009081527f4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f53d909101526102405261038992509050610100610082565b610397610200610400610082565b6103a7610100608061018061010d565b6103b7610200608061028061010d565b6103c861020061010061030061010d565b6103d961020061018061038061010d565b6103e9610400608061048061010d565b6103fa61040061010061050061010d565b61040b61040061018061058061010d565b61041c61040061020061060061010d565b61042c610600608061068061010d565b61043d61060061010061070061010d565b61044e61060061018061078061010d565b81815182350982825185098283846ffffffffeffffffffffffffffffffffff60601b193d515b82156105245781858609828485098384838809600409848586848509860986878a8b096003090885868384088703878384090886878887880960080988038889848b03870885090887888a8d096002098882830996508881820995508889888509600409945088898a8889098a098a8b86870960030908935088898687088a038a868709089a5088898284096002099950505050858687868709600809870387888b8a0386088409089850505050505b61018086891b60f71c16610600888a1b60f51c16176040810151801585151715610564578061055357506105fe565b81513d8301519750955093506105fe565b83858609848283098581890986878584098b0991508681880388858851090887838903898a8c88093d8a015109089350836105b957806105b9576105a9898c8c610008565b9a509b50995050505050506105fe565b8781820988818309898285099350898a8586088b038b838d038d8a8b0908089b50898a8287098b038b8c8f8e0388088909089c5050508788868b098209985050505050505b5082156106af5781858609828485098384838809600409848586848509860986878a8b096003090885868384088703878384090886878887880960080988038889848b03870885090887888a8d096002098882830996508881820995508889888509600409945088898a8889098a098a8b86870960030908935088898687088a038a868709089a5088898284096002099950505050858687868709600809870387888b8a0386088409089850505050505b61018086891b60f51c16610600888a1b60f31c161760408101518015851517156106ef57806106de5750610789565b81513d830151975095509350610789565b83858609848283098581890986878584098b0991508681880388858851090887838903898a8c88093d8a01510908935083610744578061074457610734898c8c610008565b9a509b5099505050505050610789565b8781820988818309898285099350898a8586088b038b838d038d8a8b0908089b50898a8287098b038b8c8f8e0388088909089c5050508788868b098209985050505050505b50600488019760fb19016104745750816107a2573d6040f35b81610860526002810361088052806108a0523d3d60c061080060055afa898983843d513d510987090614163d525050505050505050503d3df3fea264697066735822122063ce32ec0e56e7893a1f6101795ce2e38aca14dd12adb703c71fe3bee27da71e64736f6c634300081a0033";

        if (active) {
            vm.etch(address(0x100), _VERIFIER_BYTECODE);
        } else {
            vm.etch(address(0x100), "");
        }
    }

    function _getExecutionDataForThisTargetFunction(uint256 value, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        return _getExecutionData(
            address(this), value, abi.encodeWithSignature("targetFunction(bytes)", data)
        );
    }

    function _getExecutionData(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        EntryPoint.Call[] memory calls = new EntryPoint.Call[](1);
        calls[0].target = target;
        calls[0].value = value;
        calls[0].data = data;
        return abi.encode(calls);
    }

    function testExceuteGasUsed() public {
        uint256 n = 7;
        bytes[] memory encodeUserOps = new bytes[](n);

        address[] memory signer = new address[](n);
        uint256[] memory privateKeys = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            (signer[i], privateKeys[i]) = _randomUniqueSigner();
            paymentToken.mint(signer[i], 1 ether);
            vm.deal(signer[i], 1 ether);
            vm.signAndAttachDelegation(delegation, privateKeys[i]);
            bytes memory executionData = _getExecutionData(
                address(paymentToken),
                0,
                abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 1 ether)
            );

            EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
                eoa: signer[i],
                nonce: 0,
                executionData: executionData,
                payer: address(0x00),
                paymentToken: address(0x00),
                paymentRecipient: address(0xbcde),
                paymentAmount: 0.5 ether,
                paymentMaxAmount: 0.5 ether,
                paymentPerGas: 1,
                combinedGas: 10000000,
                signature: "",
                initData: ""
            });

            _fillSecp256k1Signature(userOp, privateKeys[i], bytes32(0x00));
            encodeUserOps[i] = abi.encode(userOp);
        }

        bytes memory data = abi.encodeWithSignature("execute(bytes[])", encodeUserOps);
        address _ep = address(ep);
        uint256 g;
        assembly ("memory-safe") {
            g := gas()
            pop(call(gas(), _ep, 0, add(data, 0x20), mload(data), codesize(), 0x00))
            g := sub(g, gas())
        }

        assertGt(address(0xbcde).balance, g);
    }

    function _getBatchExecutionData(
        address[] memory target,
        uint256[] memory value,
        bytes[] memory data
    ) internal pure returns (bytes memory) {
        require(target.length == value.length && value.length == data.length);
        EntryPoint.Call[] memory calls = new EntryPoint.Call[](target.length);
        for (uint256 i; i < target.length; ++i) {
            calls[i].target = target[i];
            calls[i].value = value[i];
            calls[i].data = data[i];
        }
        return abi.encode(calls);
    }

    function testKeySlots() public {
        Delegation eoa = Delegation(payable(0xc2de75891512241015C26dA8fe953Aea05985DE3));
        vm.etch(address(eoa), delegation.code);

        Delegation.Key memory key;
        key.expiry = 0;
        key.keyType = Delegation.KeyType.Secp256k1;
        key.publicKey = abi.encode(address(0x45a2428367e115E9a8B0898dFB194a4Bdcd09a23));
        key.isSuperAdmin = true;

        vm.prank(address(eoa));
        eoa.authorize(key);
        vm.stopPrank();

        EntryPoint.UserOp memory op;
        op.eoa = address(eoa);
        op.executionData = _getExecutionData(address(0), 0, bytes(""));
        op.nonce = 0x2;
        op.paymentToken = address(0x238c8CD93ee9F8c7Edf395548eF60c0d2e46665E);
        op.paymentAmount = 0;
        op.paymentMaxAmount = 0;
        op.combinedGas = 20000000;
        bytes32 digest = ep.computeDigest(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            uint256(0x8ef24acf2c7974d38d2f2c4e1bb63515c57c48707df9831794bac28dbe4aa835), digest
        );
        op.signature = abi.encodePacked(abi.encodePacked(r, s, v), eoa.hash(key), bytes32(0x00));

        ep.execute(abi.encode(op));
    }

    function testInvalidateNonce(uint96 seqKey, uint64 seq, uint64 seq2) public {
        uint256 nonce = (uint256(seqKey) << 64) | uint256(seq);
        EntryPoint.UserOp memory u;
        uint256 privateKey;
        (u.eoa, privateKey) = _randomSigner();
        vm.etch(u.eoa, delegation.code);

        vm.startPrank(u.eoa);
        if (seq == type(uint64).max) {
            ep.invalidateNonce(nonce);
            assertEq(ep.getNonce(u.eoa, seqKey), nonce);
            return;
        }

        ep.invalidateNonce(nonce);
        assertEq(ep.getNonce(u.eoa, seqKey), nonce + 1);

        if (_randomChance(2)) {
            uint256 nonce2 = (uint256(seqKey) << 64) | uint256(seq2);
            if (seq2 < uint64(ep.getNonce(u.eoa, seqKey))) {
                vm.expectRevert(EntryPoint.NewSequenceMustBeLarger.selector);
                ep.invalidateNonce(nonce2);
            } else {
                ep.invalidateNonce(nonce2);
                assertEq(
                    uint64(ep.getNonce(u.eoa, seqKey)), Math.min(uint256(seq2) + 1, 2 ** 64 - 1)
                );
            }
            if (uint64(ep.getNonce(u.eoa, seqKey)) == type(uint64).max) return;
            seq = seq2;
        }

        vm.deal(u.eoa, 2 ** 128 - 1);
        u.executionData = _getExecutionDataForThisTargetFunction(
            _bound(_random(), 0, 2 ** 32 - 1), _truncateBytes(_randomBytes(), 0xff)
        );
        u.nonce = ep.getNonce(u.eoa, seqKey);
        paymentToken.mint(u.eoa, 2 ** 128 - 1);
        u.paymentToken = address(paymentToken);
        u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
        u.paymentMaxAmount = u.paymentAmount;
        u.combinedGas = 10000000;
        _fillSecp256k1Signature(u, privateKey, bytes32(0x00));

        bytes4 err = ep.execute(abi.encode(u));

        if (seq > type(uint64).max - 2) {
            assertEq(err, EntryPoint.InvalidNonce.selector);
        } else {
            assertEq(err, 0);
        }
    }
}
