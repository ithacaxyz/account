// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";
import {MockPayerWithState} from "./utils/mocks/MockPayerWithState.sol";
import {MockPayerWithSignature} from "./utils/mocks/MockPayerWithSignature.sol";

contract EntryPointTest is BaseTest {
    struct _TestFullFlowTemps {
        EntryPoint.UserOp[] userOps;
        TargetFunctionPayload[] targetFunctionPayloads;
        DelegatedEOA[] delegatedEOAs;
        bytes[] encodedUserOps;
    }

    function testFullFlow(uint256) public {
        _TestFullFlowTemps memory t;

        t.userOps = new EntryPoint.UserOp[](_random() & 3);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.userOps.length);
        t.delegatedEOAs = new DelegatedEOA[](t.userOps.length);
        t.encodedUserOps = new bytes[](t.userOps.length);

        for (uint256 i; i != t.userOps.length; ++i) {
            DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
            t.delegatedEOAs[i] = d;

            EntryPoint.UserOp memory u = t.userOps[i];
            u.eoa = d.eoa;

            vm.deal(u.eoa, 2 ** 128 - 1);
            u.executionData = _thisTargetFunctionExecutionData(
                t.targetFunctionPayloads[i].value = _bound(_random(), 0, 2 ** 32 - 1),
                t.targetFunctionPayloads[i].data = _truncateBytes(_randomBytes(), 0xff)
            );
            u.nonce = ep.getNonce(u.eoa, 0);
            paymentToken.mint(u.eoa, 2 ** 128 - 1);
            u.paymentToken = address(paymentToken);
            u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
            u.paymentMaxAmount = u.paymentAmount;
            u.combinedGas = 10000000;
            u.signature = _sig(d, u);

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

    function testExecuteWithUnauthorizedPayer() public {
        DelegatedEOA memory alice = _randomEIP7702DelegatedEOA();
        DelegatedEOA memory bob = _randomEIP7702DelegatedEOA();

        vm.deal(alice.eoa, 10 ether);
        vm.deal(bob.eoa, 10 ether);
        paymentToken.mint(alice.eoa, 50 ether);

        bytes memory executionData =
            _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);

        EntryPoint.UserOp memory u;
        u.eoa = alice.eoa;
        u.nonce = 0;
        u.executionData = executionData;
        u.payer = bob.eoa;
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 0.1 ether;
        u.paymentMaxAmount = 0.5 ether;
        u.paymentPerGas = 100000 wei;
        u.combinedGas = 10000000;
        u.signature = "";
        u.initData = "";

        u.signature = _sig(alice, u);

        assertEq(ep.execute(abi.encode(u)), bytes4(keccak256("PaymentError()")));
    }

    function testExecuteWithSecp256k1PassKey() public {
        _testExecuteWithPassKey(_randomSecp256k1PassKey());
    }

    function _testExecuteWithPassKey(PassKey memory k) internal {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 10 ether);

        k.k.isSuperAdmin = true;
        vm.prank(d.eoa);
        d.d.authorize(k.k);

        EntryPoint.UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
        u.payer = address(0x00);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 0.1 ether;
        u.paymentMaxAmount = 0.5 ether;
        u.paymentPerGas = 1e9;
        u.combinedGas = 1000000;
        u.signature = _sig(k, u);

        paymentToken.mint(d.eoa, 50 ether);

        (uint256 gUsed,) = _simulateExecute(u);
        assertEq(ep.execute(abi.encode(u)), 0);
        uint256 actualAmount = (gUsed + 50000) * 1e9;
        assertEq(paymentToken.balanceOf(address(ep)), actualAmount);
        assertEq(paymentToken.balanceOf(d.eoa), 50 ether - actualAmount - 1 ether);
    }

    function testSimulateFailed() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        vm.deal(d.eoa, 10 ether);

        PassKey memory k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;
        vm.prank(d.eoa);
        d.d.authorize(k.k);

        address target = address(new MockSampleDelegateCallTarget(0));
        bytes memory data = abi.encodePacked(target.code, "hehe");

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].target = target;
        calls[0].data = abi.encodeWithSignature("revertWithData(bytes)", data);

        EntryPoint.UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = abi.encode(calls);
        u.payer = address(0x00);
        u.combinedGas = 1000000;
        u.signature = _sig(k, u);

        (bool success, bytes memory result) =
            address(ep).call(abi.encodeWithSignature("simulateFailed(bytes)", abi.encode(u)));

        assertFalse(success);
        assertEq(result, abi.encodeWithSignature("ErrorWithData(bytes)", data));
    }

    function testExecuteWithPayingERC20TokensWithRefund(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, 500 ether);

        EntryPoint.UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
        u.payer = d.eoa;
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(this);
        u.paymentAmount = 10 ether;
        u.paymentMaxAmount = 15 ether;
        u.paymentPerGas = 1e9;
        u.combinedGas = 10000000;
        u.signature = _sig(d, u);

        (uint256 gUsed,) = _simulateExecute(u);
        assertEq(ep.execute(abi.encode(u)), 0);
        uint256 actualAmount = (gUsed + 50000) * 1e9;
        assertEq(paymentToken.balanceOf(address(this)), actualAmount);
        assertEq(paymentToken.balanceOf(d.eoa), 500 ether - actualAmount - 1 ether);
        assertEq(ep.getNonce(d.eoa, 0), 1);
    }

    function testExecuteBatchCalls(uint256 n) public {
        n = _bound(n, 0, _randomChance(64) ? 16 : 3);
        bytes[] memory encodedUserOps = new bytes[](n);

        DelegatedEOA[] memory ds = new DelegatedEOA[](n);

        for (uint256 i; i < n; ++i) {
            ds[i] = _randomEIP7702DelegatedEOA();
            paymentToken.mint(ds[i].eoa, 1 ether);

            EntryPoint.UserOp memory u;
            u.eoa = ds[i].eoa;
            u.nonce = 0;
            u.executionData =
                _transferExecutionData(address(paymentToken), address(0xabcd), 0.5 ether);
            u.payer = ds[i].eoa;
            u.paymentToken = address(paymentToken);
            u.paymentRecipient = address(0xbcde);
            u.paymentAmount = 0.5 ether;
            u.paymentMaxAmount = 0.5 ether;
            u.paymentPerGas = 1e9;
            u.combinedGas = 10000000;
            u.signature = _sig(ds[i], u);
            encodedUserOps[i] = abi.encode(u);
        }

        bytes4[] memory errs = ep.execute(encodedUserOps);

        for (uint256 i; i < n; ++i) {
            assertEq(errs[i], 0);
            assertEq(ep.getNonce(ds[i].eoa, 0), 1);
        }
        assertEq(paymentToken.balanceOf(address(0xabcd)), n * 0.5 ether);
    }

    function testExecuteUserBatchCalls(uint256 n) public {
        n = _bound(n, 0, _randomChance(64) ? 16 : 3);
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        paymentToken.mint(d.eoa, 100 ether);

        ERC7821.Call[] memory calls = new ERC7821.Call[](n);

        for (uint256 i; i < n; ++i) {
            calls[i] = _transferCall(address(paymentToken), address(0xabcd), 0.5 ether);
        }

        EntryPoint.UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = abi.encode(calls);
        u.payer = d.eoa;
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0xbcde);
        u.paymentAmount = 10 ether;
        u.paymentMaxAmount = 10 ether;
        u.paymentPerGas = 1e9;
        u.combinedGas = 10000000;
        u.signature = _sig(d, u);

        (uint256 gUsed,) = _simulateExecute(u);
        assertEq(ep.execute(abi.encode(u)), 0);
        assertEq(paymentToken.balanceOf(address(0xabcd)), 0.5 ether * n);
        assertEq(paymentToken.balanceOf(d.eoa), 100 ether - (0.5 ether * n + (gUsed + 50000) * 1e9));
        assertEq(ep.getNonce(d.eoa, 0), 1);
    }

    function testExceuteRevertsIfPaymentIsInsufficient() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, 500 ether);

        EntryPoint.UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
        u.payer = d.eoa;
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 20 ether;
        u.paymentMaxAmount = 15 ether;
        u.paymentPerGas = 1e9;
        u.combinedGas = 10000000;
        u.signature = _sig(d, u);

        (, bytes4 err) = _simulateExecute(u);

        assertEq(err, bytes4(keccak256("PaymentError()")));
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
            DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
            EntryPoint.UserOp memory u = t.userOp;
            u.eoa = d.eoa;
            vm.deal(u.eoa, 2 ** 128 - 1);
            u.executionData = _thisTargetFunctionExecutionData(
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
            u.signature = _sig(d, u);
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

    function testExceuteGasUsed() public {
        vm.pauseGasMetering();
        uint256 n = 7;
        bytes[] memory encodeUserOps = new bytes[](n);

        DelegatedEOA[] memory ds = new DelegatedEOA[](n);

        for (uint256 i; i < n; ++i) {
            ds[i] = _randomEIP7702DelegatedEOA();
            paymentToken.mint(ds[i].eoa, 1 ether);
            vm.deal(ds[i].eoa, 1 ether);

            EntryPoint.UserOp memory u;
            u.eoa = ds[i].eoa;
            u.nonce = 0;
            u.executionData =
                _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
            u.payer = address(0x00);
            u.paymentToken = address(0x00);
            u.paymentRecipient = address(0xbcde);
            u.paymentAmount = 0.5 ether;
            u.paymentMaxAmount = 0.5 ether;
            u.paymentPerGas = 1;
            u.combinedGas = 10000000;
            u.signature = _sig(ds[i], u);

            encodeUserOps[i] = abi.encode(u);
        }

        bytes memory data = abi.encodeWithSignature("execute(bytes[])", encodeUserOps);
        address _ep = address(ep);
        uint256 g;
        vm.resumeGasMetering();

        assembly ("memory-safe") {
            g := gas()
            pop(call(gas(), _ep, 0, add(data, 0x20), mload(data), codesize(), 0x00))
            g := sub(g, gas())
        }

        assertGt(address(0xbcde).balance, g);
    }

    function testKeySlots() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        PassKey memory k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        EntryPoint.UserOp memory u;
        u.eoa = d.eoa;
        u.executionData = _executionData(address(0), 0, bytes(""));
        u.nonce = 0x2;
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 0;
        u.paymentMaxAmount = 0;
        u.combinedGas = 20000000;
        u.signature = _sig(k, u);

        ep.execute(abi.encode(u));
    }

    function testInvalidateNonce(uint96 seqKey, uint64 seq, uint64 seq2) public {
        uint256 nonce = (uint256(seqKey) << 64) | uint256(seq);
        EntryPoint.UserOp memory u;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        u.eoa = d.eoa;

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
                vm.expectRevert(bytes4(keccak256("NewSequenceMustBeLarger()")));
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
        u.executionData = _thisTargetFunctionExecutionData(
            _bound(_random(), 0, 2 ** 32 - 1), _truncateBytes(_randomBytes(), 0xff)
        );
        u.nonce = ep.getNonce(u.eoa, seqKey);
        paymentToken.mint(u.eoa, 2 ** 128 - 1);
        u.paymentToken = address(paymentToken);
        u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
        u.paymentMaxAmount = u.paymentAmount;
        u.combinedGas = 10000000;
        u.signature = _sig(d, u);

        if (seq > type(uint64).max - 2) {
            assertEq(ep.execute(abi.encode(u)), bytes4(keccak256("InvalidNonce()")));
        } else {
            assertEq(ep.execute(abi.encode(u)), 0);
        }
    }

    function _simulateExecute(EntryPoint.UserOp memory u)
        internal
        returns (uint256 gUsed, bytes4 err)
    {
        (, bytes memory rD) =
            address(ep).call(abi.encodePacked(bytes4(0xffffffff), uint256(0), abi.encode(u)));
        gUsed = uint256(LibBytes.load(rD, 0x04));
        err = bytes4(LibBytes.load(rD, 0x24));
    }

    struct _TestAuthorizeWithPreOpsAndTransferTemps {
        uint256 gExecute;
        uint256 gCombined;
        uint256 gUsed;
        bool success;
        bytes result;
        bool testInvalidPreOpEOA;
        bool testPreOpVerificationError;
        bool testPreOpCallError;
        bool testPREP;
        PassKey kPREP;
        DelegatedEOA d;
        address eoa;
    }

    function testAuthorizeWithPreOpsAndTransfer(bytes32) public {
        _TestAuthorizeWithPreOpsAndTransferTemps memory t;
        EntryPoint.UserOp memory u;

        if (_randomChance(2)) {
            t.d = _randomEIP7702DelegatedEOA();
            t.eoa = t.d.eoa;
        } else {
            t.kPREP = _randomSecp256r1PassKey();
            t.kPREP.k.isSuperAdmin = true;

            ERC7821.Call[] memory initCalls = new ERC7821.Call[](1);
            initCalls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, t.kPREP.k);

            bytes32 saltAndDelegation;
            (saltAndDelegation, t.eoa) = _minePREP(_computePREPDigest(initCalls));
            u.initData = abi.encode(initCalls, abi.encodePacked(saltAndDelegation));

            vm.etch(t.eoa, abi.encodePacked(hex"ef0100", delegation));

            t.testPREP = true;
        }

        u.eoa = t.eoa;

        paymentToken.mint(u.eoa, 2 ** 128 - 1);
        u.paymentToken = address(paymentToken);
        u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
        u.paymentMaxAmount = u.paymentAmount;
        u.nonce = 0xc1d0 << 240;

        PassKey memory kSuperAdmin = _randomSecp256r1PassKey();
        PassKey memory kSession = _randomSecp256r1PassKey();

        kSuperAdmin.k.isSuperAdmin = true;

        EntryPoint.UserOp memory uSuperAdmin;
        EntryPoint.UserOp memory uSession;

        uSuperAdmin.eoa = t.eoa;
        uSession.eoa = t.eoa;

        if (_randomChance(64)) {
            uSession.eoa = address(0);
            t.testInvalidPreOpEOA = true;
        }

        u.encodedPreOps = new bytes[](2);
        // Prepare super admin passkey authorization UserOp.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, kSuperAdmin.k);

            uSuperAdmin.executionData = abi.encode(calls);
            // Change this formula accordingly. We just need a non-colliding out-of-order nonce here.
            uSuperAdmin.nonce = (0xc1d0 << 240) | (1 << 64);

            if (t.testPREP) {
                uSuperAdmin.signature = _sig(t.kPREP, uSuperAdmin);
            } else {
                uSuperAdmin.signature = _eoaSig(t.d.privateKey, uSuperAdmin);
            }
        }

        // Prepare session passkey authorization UserOp.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](3);
            calls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, kSession.k);
            // As it's not a superAdmin, we shall just make it able to execute anything for testing sake.
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector,
                kSession.keyHash,
                _ANY_TARGET,
                _ANY_FN_SEL,
                true
            );
            // Set some spend limits.
            calls[2] = _setSpendLimitCall(
                kSession, address(paymentToken), GuardedExecutor.SpendPeriod.Hour, 1 ether
            );

            if (_randomChance(64)) {
                calls[0].value = 1 ether;
                t.testPreOpCallError = true;
            }

            uSession.executionData = abi.encode(calls);
            // Change this formula accordingly. We just need a non-colliding out-of-order nonce here.
            uSession.nonce = (0xc1d0 << 240) | (2 << 64);

            uSession.signature = _sig(kSuperAdmin, uSession);

            if (_randomChance(64)) {
                uSession.signature = _sig(_randomSecp256r1PassKey(), uSession);
                u.encodedPreOps[1] = abi.encode(uSession);
                t.testPreOpVerificationError = true;
            }
        }

        // Prepare the enveloping UserOp.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall(address(paymentToken), address(0xabcd), 0.5 ether);

            u.executionData = abi.encode(calls);
            u.nonce = 0;

            u.encodedPreOps[0] = abi.encode(uSuperAdmin);
            u.encodedPreOps[1] = abi.encode(uSession);
        }

        if (t.testInvalidPreOpEOA) {
            u.combinedGas = 10000000;
            u.signature = _sig(kSession, u);
            assertEq(ep.execute(abi.encode(u)), bytes4(keccak256("InvalidPreOpEOA()")));
            return; // Skip the rest.
        }

        if (t.testPreOpVerificationError) {
            u.combinedGas = 10000000;
            u.signature = _sig(kSession, u);
            assertEq(ep.execute(abi.encode(u)), bytes4(keccak256("PreOpVerificationError()")));
            return; // Skip the rest.
        }

        if (t.testPreOpCallError) {
            u.combinedGas = 10000000;
            u.signature = _sig(kSession, u);
            assertEq(ep.execute(abi.encode(u)), bytes4(keccak256("PreOpCallError()")));
            return; // Skip the rest.
        }

        // Test recursive style.
        if (_randomChance(8)) {
            uSession.encodedPreOps = new bytes[](1);
            uSession.encodedPreOps[0] = abi.encode(uSuperAdmin);
            uSession.signature = _sig(kSuperAdmin, uSession);

            u.encodedPreOps = new bytes[](1);
            u.encodedPreOps[0] = abi.encode(uSession);
        }

        // Test gas estimation.
        if (_randomChance(16)) {
            // Fill with some junk signature, but with the session `keyHash`.
            u.signature =
                abi.encodePacked(keccak256("a"), keccak256("b"), kSession.keyHash, uint8(0));

            (t.success, t.result) =
                address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", abi.encode(u)));

            assertFalse(t.success);
            assertEq(bytes4(LibBytes.load(t.result, 0x00)), EntryPoint.SimulationResult.selector);

            t.gExecute = uint256(LibBytes.load(t.result, 0x04));
            t.gCombined = uint256(LibBytes.load(t.result, 0x24));
            t.gUsed = uint256(LibBytes.load(t.result, 0x44));
            emit LogUint("gExecute", t.gExecute);
            emit LogUint("gCombined", t.gCombined);
            emit LogUint("gUsed", t.gUsed);
            assertEq(bytes4(LibBytes.load(t.result, 0x64)), 0);

            u.combinedGas = t.gCombined;
            u.signature = _sig(kSession, u);

            assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
        } else {
            // Otherwise, test without gas estimation.
            u.combinedGas = 10000000;
            u.signature = _sig(kSession, u);
            assertEq(ep.execute(abi.encode(u)), 0);
        }

        assertEq(paymentToken.balanceOf(address(0xabcd)), 0.5 ether);
        assertEq(ep.getNonce(t.eoa, uint192(uSession.nonce >> 64)), uSession.nonce | 1);
        assertEq(ep.getNonce(t.eoa, uint192(uSuperAdmin.nonce >> 64)), uSuperAdmin.nonce | 1);
    }

    struct _TestPayViaAnotherPayerTemps {
        MockPayerWithState withState;
        MockPayerWithSignature withSignature;
        DelegatedEOA withSignatureEOA;
        address token;
        uint256 funds;
        bool isWithState;
        bool corruptSignature;
        bool unapprovedEntryPoint;
        uint256 balanceBefore;
        DelegatedEOA d;
    }

    function testPayViaAnotherPayer(bytes32) public {
        _TestPayViaAnotherPayerTemps memory t;

        t.withSignatureEOA = _randomEIP7702DelegatedEOA();
        t.withState = new MockPayerWithState();
        t.withSignature = new MockPayerWithSignature();
        vm.deal(address(t.withState), type(uint192).max);
        vm.deal(address(t.withSignature), type(uint192).max);
        _mint(address(paymentToken), address(t.withState), type(uint192).max);
        _mint(address(paymentToken), address(t.withSignature), type(uint192).max);

        t.withState.setApprovedEntryPoint(address(ep), true);
        t.withSignature.setApprovedEntryPoint(address(ep), true);
        t.withSignature.setSigner(t.withSignatureEOA.eoa);

        t.token = _randomChance(2) ? address(0) : address(paymentToken);
        t.isWithState = _randomChance(2);

        EntryPoint.UserOp memory u;
        t.d = _randomEIP7702DelegatedEOA();
        vm.deal(t.d.eoa, type(uint192).max);

        u.eoa = t.d.eoa;
        u.nonce = ep.getNonce(u.eoa, 0);
        u.combinedGas = 1000000;
        u.payer = t.isWithState ? address(t.withState) : address(t.withSignature);
        u.paymentToken = t.token;
        u.paymentAmount = _bound(_random(), 0, 1 ether);
        u.paymentMaxAmount = 1 ether;
        u.executionData = _transferExecutionData(address(0), address(0xabcd), 1 ether);

        t.funds = _bound(_random(), 0, 2 ether);
        if (t.isWithState) {
            t.withState.increaseFunds(u.paymentToken, u.eoa, t.funds);
        } else {
            bytes32 digest = ep.computeDigest(u);
            digest = t.withSignature.computeSignatureDigest(digest);
            u.paymentSignature = _sig(t.withSignatureEOA, digest);
            t.corruptSignature = _randomChance(2);
            if (t.corruptSignature) {
                u.paymentSignature = abi.encodePacked(keccak256(u.paymentSignature));
            }
        }
        t.balanceBefore = _balanceOf(t.token, u.payer);

        u.signature = _eoaSig(t.d.privateKey, u);

        t.unapprovedEntryPoint = _randomChance(32);
        if (t.unapprovedEntryPoint) {
            t.withState.setApprovedEntryPoint(address(ep), false);
            t.withSignature.setApprovedEntryPoint(address(ep), false);
        }

        if (
            (t.isWithState && u.paymentAmount > t.funds && u.paymentAmount != 0)
                || (!t.isWithState && t.corruptSignature && u.paymentAmount != 0)
                || (t.unapprovedEntryPoint && u.paymentAmount != 0)
        ) {
            assertEq(ep.execute(abi.encode(u)), bytes4(keccak256("PaymentError()")));
            assertEq(ep.getNonce(u.eoa, 0), u.nonce);
            assertEq(_balanceOf(t.token, u.payer), t.balanceBefore);
            assertEq(_balanceOf(address(0), address(0xabcd)), 0);
        } else {
            assertEq(ep.execute(abi.encode(u)), 0);
            assertEq(ep.getNonce(u.eoa, 0), u.nonce + 1);
            assertEq(_balanceOf(t.token, u.payer), t.balanceBefore - u.paymentAmount);
            assertEq(_balanceOf(address(0), address(0xabcd)), 1 ether);
        }
    }
}
