// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {Delegation} from "../src/Delegation.sol";
import {EntryPoint, MockEntryPoint} from "./utils/mocks/MockEntryPoint.sol";
import {ERC20, MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";

contract EntryPointTest is SoladyTest {
    MockEntryPoint ep;
    MockPaymentToken paymentToken;
    address delegation;

    TargetFunctionPayload[] targetFunctionPayloads;

    struct TargetFunctionPayload {
        address by;
        uint256 value;
        bytes data;
    }

    function setUp() public {
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

    function testFullFlow(bytes32) public {
        _TestFullFlowTemps memory t;

        t.userOps = new EntryPoint.UserOp[](_random() & 3);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.userOps.length);
        t.privateKeys = new uint256[](t.userOps.length);
        t.encodedUserOps = new bytes[](t.userOps.length);

        for (uint256 i; i != t.userOps.length; ++i) {
            EntryPoint.UserOp memory u = t.userOps[i];
            (u.eoa, t.privateKeys[i]) = _randomSigner();
            vm.etch(u.eoa, delegation.code);
            vm.deal(u.eoa, 2 ** 128 - 1);
            u.executionData = _getExecutionDataForThisTargetFunction(
                t.targetFunctionPayloads[i].value = _bound(_random(), 0, 2 ** 32 - 1),
                t.targetFunctionPayloads[i].data = _truncateBytes(_randomBytes(), 0xff)
            );
            u.nonce = _randomUnique() << 1;
            paymentToken.mint(u.eoa, 2 ** 128 - 1);
            u.paymentToken = address(paymentToken);
            u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
            u.paymentMaxAmount = u.paymentAmount;
            u.combinedGas = 10000000;
            _fillSecp256k1Signature(u, t.privateKeys[i]);
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
            signature: ""
        });

        bytes32 digest = ep.computeDigest(userOp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice, digest);

        userOp.signature = abi.encodePacked(r, s, v);

        bytes4 err = ep.execute(abi.encode(userOp));
        assertEq(EntryPoint.PaymentError.selector, err);
    }

    function testExecuteRevertWhenRunOutOfGas() public {
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
            combinedGas: 15000,
            signature: ""
        });

        _fillSecp256k1Signature(userOp, alice);

        /// Run out of gas at verification time
        bytes memory data = abi.encodeWithSignature("execute(bytes)", abi.encode(userOp));
        address _ep = address(ep);
        bytes4 err;
        uint256 g = gasleft();
        assembly {
            pop(call(gas(), _ep, 0, add(data, 0x20), mload(data), 0x00, 0x20))
            g := sub(g, gas())
            err := mload(0)
        }

        uint256 startBalance = address(0xbcde).balance;

        data = abi.encodeWithSignature("execute(bytes)", abi.encode(userOp));
        g = gasleft();
        assembly {
            pop(call(gas(), _ep, 0, add(data, 0x20), mload(data), 0x00, 0x20))
            g := sub(g, gas())
            err := mload(0)
        }

        // paymentReceipt get paid enough pays for reverted tx
        assertGt((address(0xbcde).balance - startBalance), g);
        assertEq(EntryPoint.VerifiedCallError.selector, err);

        startBalance = address(0xbcde).balance;

        // Run out of gas at _call time
        userOp.combinedGas = 40000;
        _fillSecp256k1Signature(userOp, alice);
        data = abi.encodeWithSignature("execute(bytes)", abi.encode(userOp));

        g = gasleft();
        assembly {
            pop(call(gas(), _ep, 0, add(data, 0x20), mload(data), 0x00, 0x20))
            g := sub(g, gas())
            err := mload(0)
        }
        // paymentReceipt get paid enough pays for reverted tx
        assertGt((address(0xbcde).balance - startBalance), g);
        assertEq(EntryPoint.CallError.selector, err);
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
            signature: ""
        });

        bytes32 digest = ep.computeDigest(userOp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        userOp.signature = abi.encodePacked(r, s, v);

        bytes memory op = abi.encode(userOp);

        (, bytes memory rD) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", op));

        uint256 gUsed;

        assembly {
            gUsed := mload(add(rD, 0x24))
        }
        bytes4 err = ep.execute(op);
        assertEq(err, bytes4(0x0000000));
        uint256 actualAmount = (gUsed + 50000) * 1e9;
        assertEq(paymentToken.balanceOf(address(this)), actualAmount);
        // extra goes back to signer
        assertEq(paymentToken.balanceOf(randomSigner), 500 ether - actualAmount - 1 ether);
    }

    function testExecuteBatchCalls(uint256 n) public {
        n = n & 15; // random % 16
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
                signature: ""
            });

            _fillSecp256k1Signature(userOp, privateKeys[i]);
            encodeUserOps[i] = abi.encode(userOp);
            (, bytes memory rD) = address(ep).call(
                abi.encodeWithSignature("simulateExecute(bytes)", encodeUserOps[i])
            );
            uint256 gUsed;

            assembly {
                gUsed := mload(add(rD, 0x24))
            }

            gasUsed[i] = gUsed;
        }

        bytes4[] memory errs = ep.execute(encodeUserOps);

        for (uint256 i; i < n; ++i) {
            assertEq(errs[i], bytes4(0x0000000));
        }
        assertEq(paymentToken.balanceOf(address(0xabcd)), n * 0.5 ether);
    }

    function testExecuteUserBatchCalls(uint256 n) public {
        n = n & 15; // random % 16

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
            signature: ""
        });

        _fillSecp256k1Signature(userOp, privateKey);

        bytes memory encodeUserOps = abi.encode(userOp);
        (, bytes memory rD) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", encodeUserOps));
        uint256 gUsed;

        assembly {
            gUsed := mload(add(rD, 0x24))
        }

        bytes4 err = ep.execute(encodeUserOps);

        assertEq(err, bytes4(0x0000000));
        assertEq(paymentToken.balanceOf(address(0xabcd)), 0.5 ether * n);
        assertEq(
            paymentToken.balanceOf(signer), 100 ether - (0.5 ether * n + (gUsed + 50000) * 1e9)
        );
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
            signature: ""
        });

        bytes32 digest = ep.computeDigest(userOp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        userOp.signature = abi.encodePacked(r, s, v);

        bytes memory op = abi.encode(userOp);

        (, bytes memory rD) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", op));

        bytes4 err;
        uint256 gUsed;

        assembly {
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
            u.nonce = _randomUnique() << 1;
            paymentToken.mint(address(this), 2 ** 128 - 1);
            paymentToken.approve(address(ep), 2 ** 128 - 1);
            t.fundingToken = address(paymentToken);
            t.fundingAmount = _bound(_random(), 0, 2 ** 32 - 1);
            u.paymentToken = address(paymentToken);
            u.paymentAmount = t.fundingAmount;
            u.paymentMaxAmount = u.paymentAmount;
            u.combinedGas = 10000000;
            _fillSecp256k1Signature(u, t.privateKey);
            t.originData = abi.encode(abi.encode(u), t.fundingToken, t.fundingAmount);
        }
        assertEq(ep.fill(t.orderId, t.originData, ""), 0);
        assertEq(ep.orderIdIsFilled(t.orderId), true);
    }

    function testWithdrawTokens() public {
        vm.startPrank(ep.owner());
        vm.deal(address(ep), 1 ether);
        paymentToken.mint(address(ep), 10 ether);
        ep.withdrawTokens(address(0), address(0xabcd), 1 ether);
        ep.withdrawTokens(address(paymentToken), address(0xabcd), 10 ether);
        vm.stopPrank();
    }

    function _fillSecp256k1Signature(EntryPoint.UserOp memory userOp, uint256 privateKey)
        internal
        view
    {
        bytes32 digest = ep.computeDigest(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        userOp.signature = abi.encodePacked(r, s, v);
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

    function testExceuteGasUsed(uint256 n) public {
        n = (n & 15) + 1; // random % 16 + 1
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
                signature: ""
            });

            _fillSecp256k1Signature(userOp, privateKeys[i]);
            encodeUserOps[i] = abi.encode(userOp);
        }

        bytes memory data = abi.encodeWithSignature("execute(bytes[])", encodeUserOps);
        address _ep = address(ep);
        uint256 g;
        assembly {
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
        op.signature = abi.encodePacked(abi.encodePacked(r, s, v), eoa.hash(key), false);

        ep.execute(abi.encode(op));
    }
}
