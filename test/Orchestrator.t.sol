// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";
import {MockPayerWithState} from "./utils/mocks/MockPayerWithState.sol";
import {MockPayerWithSignature} from "./utils/mocks/MockPayerWithSignature.sol";
import {IOrchestrator} from "../src/interfaces/IOrchestrator.sol";
import {IIthacaAccount} from "../src/interfaces/IIthacaAccount.sol";
import {MultiSigSigner} from "../src/MultiSigSigner.sol";
import {ICommon} from "../src/interfaces/ICommon.sol";
import {Merkle} from "murky/Merkle.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";

import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";

contract OrchestratorTest is BaseTest {
    struct _TestFullFlowTemps {
        Orchestrator.Intent[] intents;
        TargetFunctionPayload[] targetFunctionPayloads;
        DelegatedEOA[] delegatedEOAs;
        bytes[] encodedIntents;
    }

    function testFullFlow(uint256) public {
        _TestFullFlowTemps memory t;

        t.intents = new Orchestrator.Intent[](_random() & 3);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.intents.length);
        t.delegatedEOAs = new DelegatedEOA[](t.intents.length);
        t.encodedIntents = new bytes[](t.intents.length);

        for (uint256 i; i != t.intents.length; ++i) {
            DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
            t.delegatedEOAs[i] = d;

            Orchestrator.Intent memory u = t.intents[i];
            u.eoa = d.eoa;

            vm.deal(u.eoa, 2 ** 128 - 1);
            u.executionData = _thisTargetFunctionExecutionData(
                t.targetFunctionPayloads[i].value = _bound(_random(), 0, 2 ** 32 - 1),
                t.targetFunctionPayloads[i].data = _truncateBytes(_randomBytes(), 0xff)
            );
            u.nonce = d.d.getNonce(0);
            paymentToken.mint(u.eoa, 2 ** 128 - 1);
            u.paymentToken = address(paymentToken);
            u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
            u.paymentMaxAmount = u.paymentAmount;
            u.combinedGas = 10000000;
            u.signature = _sig(d, u);

            t.encodedIntents[i] = abi.encode(u);
        }

        bytes4[] memory errors = oc.execute(t.encodedIntents);
        assertEq(errors.length, t.intents.length);
        for (uint256 i; i != errors.length; ++i) {
            assertEq(errors[i], 0);
            assertEq(targetFunctionPayloads[i].by, t.intents[i].eoa);
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

        Orchestrator.Intent memory u;
        u.eoa = alice.eoa;
        u.nonce = 0;
        u.executionData = executionData;
        u.payer = bob.eoa;
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 0.1 ether;
        u.paymentMaxAmount = 0.5 ether;
        u.combinedGas = 10000000;
        u.signature = "";

        u.signature = _sig(alice, u);

        assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("PaymentError()")));
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

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
        u.payer = address(0x00);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 0.1 ether;
        u.paymentMaxAmount = 0.5 ether;
        u.paymentRecipient = address(oc);
        u.combinedGas = 1000000;
        u.signature = _sig(k, u);

        paymentToken.mint(d.eoa, 50 ether);

        _simulateExecute(
            _EstimateGasParams({
                u: u,
                paymentPerGasPrecision: 0,
                paymentPerGas: 1,
                combinedGasIncrement: 11_000,
                combinedGasVerificationOffset: 0
            })
        );
        assertEq(oc.execute(abi.encode(u)), 0);
        uint256 actualAmount = 0.1 ether;
        assertEq(paymentToken.balanceOf(address(oc)), actualAmount);
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
        calls[0].to = target;
        calls[0].data = abi.encodeWithSignature("revertWithData(bytes)", data);

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = abi.encode(calls);
        u.payer = address(0x00);
        u.combinedGas = 1000000;
        u.signature = _sig(k, u);

        (bool success, bytes memory result) =
            address(oc).call(abi.encodeWithSignature("simulateFailed(bytes)", abi.encode(u)));

        assertFalse(success);
        assertEq(result, abi.encodeWithSignature("ErrorWithData(bytes)", data));
    }

    function testExecuteWithPayingERC20Tokens(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, 500 ether);

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(this);
        u.paymentAmount = 10 ether;
        u.paymentMaxAmount = 15 ether;
        u.combinedGas = 10000000;
        u.signature = _sig(d, u);

        _simulateExecute(
            _EstimateGasParams({
                u: u,
                paymentPerGasPrecision: 0,
                paymentPerGas: 1,
                combinedGasIncrement: 11_000,
                combinedGasVerificationOffset: 0
            })
        );

        assertEq(oc.execute(abi.encode(u)), 0);
        uint256 actualAmount = 10 ether;
        assertEq(paymentToken.balanceOf(address(this)), actualAmount);
        assertEq(paymentToken.balanceOf(d.eoa), 500 ether - actualAmount - 1 ether);
        assertEq(d.d.getNonce(0), 1);
    }

    function testExecuteBatchCalls(uint256 n) public {
        n = _bound(n, 0, _randomChance(64) ? 16 : 3);
        bytes[] memory encodedIntents = new bytes[](n);

        DelegatedEOA[] memory ds = new DelegatedEOA[](n);

        for (uint256 i; i < n; ++i) {
            ds[i] = _randomEIP7702DelegatedEOA();
            paymentToken.mint(ds[i].eoa, 1 ether);

            Orchestrator.Intent memory u;
            u.eoa = ds[i].eoa;
            u.nonce = 0;
            u.executionData =
                _transferExecutionData(address(paymentToken), address(0xabcd), 0.5 ether);

            u.paymentToken = address(paymentToken);
            u.paymentRecipient = address(0xbcde);
            u.paymentAmount = 0.5 ether;
            u.paymentMaxAmount = 0.5 ether;
            u.combinedGas = 10000000;
            u.signature = _sig(ds[i], u);
            encodedIntents[i] = abi.encode(u);
        }

        bytes4[] memory errs = oc.execute(encodedIntents);

        for (uint256 i; i < n; ++i) {
            assertEq(errs[i], 0);
            assertEq(ds[i].d.getNonce(0), 1);
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

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = abi.encode(calls);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0xbcde);
        u.paymentAmount = 10 ether;
        u.paymentMaxAmount = 10 ether;
        u.combinedGas = 10000000;
        u.signature = _sig(d, u);

        (uint256 gExecute,,) = _estimateGas(u);

        assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
        assertEq(paymentToken.balanceOf(address(0xabcd)), 0.5 ether * n);
        assertEq(paymentToken.balanceOf(d.eoa), 100 ether - (u.paymentAmount + 0.5 ether * n));
        assertEq(d.d.getNonce(0), 1);
    }

    function testExceuteRevertsIfPaymentIsInsufficient() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, 500 ether);

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
        u.payer = d.eoa;
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 20 ether;
        u.paymentMaxAmount = 15 ether;
        u.combinedGas = 10000000;
        u.signature = _sig(d, u);

        vm.expectRevert(bytes4(keccak256("PaymentError()")));

        _simulateExecute(
            _EstimateGasParams({
                u: u,
                paymentPerGasPrecision: 0,
                paymentPerGas: 1,
                combinedGasIncrement: 11_000,
                combinedGasVerificationOffset: 0
            })
        );
    }

    function testWithdrawTokens() public {
        // Anyone can withdraw tokens from the orchestrator.
        vm.deal(address(oc), 1 ether);
        paymentToken.mint(address(oc), 10 ether);
        oc.withdrawTokens(address(0), address(0xabcd), 1 ether);
        oc.withdrawTokens(address(paymentToken), address(0xabcd), 10 ether);
    }

    function testIntentExpiry() public {
        // Warp time forward to ensure we have reasonable timestamps to work with
        vm.warp(1000);

        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 1 ether);
        paymentToken.mint(d.eoa, 10 ether);

        // Create base intent with common fields
        Orchestrator.Intent memory baseIntent;
        baseIntent.eoa = d.eoa;
        baseIntent.paymentToken = address(paymentToken);
        baseIntent.paymentAmount = 0.1 ether;
        baseIntent.paymentMaxAmount = 0.1 ether;
        baseIntent.combinedGas = 10000000;

        // Test case 1: Intent with no expiry (expiry = 0) should always be valid
        {
            Orchestrator.Intent memory u = baseIntent;
            u.nonce = d.d.getNonce(0);
            u.executionData =
                _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
            u.expiry = 0; // No expiry
            u.signature = _sig(d, u);

            assertEq(oc.execute(abi.encode(u)), 0);
            assertEq(paymentToken.balanceOf(address(0xabcd)), 1 ether);
        }

        // Test case 2: Intent with future expiry should be valid
        {
            Orchestrator.Intent memory u = baseIntent;
            u.nonce = d.d.getNonce(0);
            u.executionData =
                _transferExecutionData(address(paymentToken), address(0xbcde), 1 ether);
            u.expiry = block.timestamp + 1 hours; // Future expiry
            u.signature = _sig(d, u);

            assertEq(oc.execute(abi.encode(u)), 0);
            assertEq(paymentToken.balanceOf(address(0xbcde)), 1 ether);
        }

        // Test case 3: Intent with past expiry should fail
        {
            Orchestrator.Intent memory u = baseIntent;
            u.nonce = d.d.getNonce(0); // This will be 2 after the previous two intents
            u.executionData =
                _transferExecutionData(address(paymentToken), address(0xcdef), 1 ether);
            u.expiry = block.timestamp - 1; // Past expiry
            u.signature = _sig(d, u);

            bytes4 result = oc.execute(abi.encode(u));
            assertEq(result, bytes4(keccak256("IntentExpired()")));
            assertEq(paymentToken.balanceOf(address(0xcdef)), 0); // Transfer should not happen
        }

        // Test case 4: Batch execution with mixed expired and valid intents
        {
            bytes[] memory encodedIntents = new bytes[](3);

            // Create base intent for batch with smaller amounts
            Orchestrator.Intent memory batchBase;
            batchBase.eoa = d.eoa;
            batchBase.paymentToken = address(paymentToken);
            batchBase.paymentAmount = 0.05 ether;
            batchBase.paymentMaxAmount = 0.05 ether;
            batchBase.combinedGas = 10000000;

            // Valid intent with nonce 2
            Orchestrator.Intent memory u1 = batchBase;
            u1.nonce = 2;
            u1.executionData =
                _transferExecutionData(address(paymentToken), address(0x1111), 0.5 ether);
            u1.expiry = block.timestamp + 1 hours;
            u1.signature = _sig(d, u1);
            encodedIntents[0] = abi.encode(u1);

            // Expired intent with nonce 3
            Orchestrator.Intent memory u2 = batchBase;
            u2.nonce = 3;
            u2.executionData =
                _transferExecutionData(address(paymentToken), address(0x2222), 0.5 ether);
            u2.expiry = block.timestamp - 1;
            u2.signature = _sig(d, u2);
            encodedIntents[1] = abi.encode(u2);

            // Another valid intent with nonce 3 (since nonce 3 wasn't consumed due to expiry)
            Orchestrator.Intent memory u3 = batchBase;
            u3.nonce = 3;
            u3.executionData =
                _transferExecutionData(address(paymentToken), address(0x3333), 0.5 ether);
            u3.expiry = 0; // No expiry
            u3.signature = _sig(d, u3);
            encodedIntents[2] = abi.encode(u3);

            bytes4[] memory errors = oc.execute(encodedIntents);
            assertEq(errors.length, 3);
            assertEq(errors[0], 0); // First intent succeeded
            assertEq(errors[1], bytes4(keccak256("IntentExpired()"))); // Second intent expired
            assertEq(errors[2], 0); // Third intent succeeded

            // Verify transfers
            assertEq(paymentToken.balanceOf(address(0x1111)), 0.5 ether);
            assertEq(paymentToken.balanceOf(address(0x2222)), 0); // Expired intent didn't transfer
            assertEq(paymentToken.balanceOf(address(0x3333)), 0.5 ether);
        }
    }

    function testExceuteGasUsed() public {
        vm.pauseGasMetering();
        uint256 n = 7;
        bytes[] memory encodeIntents = new bytes[](n);

        DelegatedEOA[] memory ds = new DelegatedEOA[](n);

        for (uint256 i; i < n; ++i) {
            ds[i] = _randomEIP7702DelegatedEOA();
            paymentToken.mint(ds[i].eoa, 1 ether);
            vm.deal(ds[i].eoa, 1 ether);

            Orchestrator.Intent memory u;
            u.eoa = ds[i].eoa;
            u.nonce = 0;
            u.executionData =
                _transferExecutionData(address(paymentToken), address(0xabcd), 1 ether);
            u.payer = address(0x00);
            u.paymentToken = address(0x00);
            u.paymentRecipient = address(0xbcde);
            u.paymentAmount = 0.5 ether;
            u.paymentMaxAmount = 0.5 ether;
            u.combinedGas = 10000000;
            u.signature = _sig(ds[i], u);

            encodeIntents[i] = abi.encode(u);
        }

        bytes memory data = abi.encodeWithSignature("execute(bytes[])", encodeIntents);
        address _ep = address(oc);
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

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.executionData = _executionData(address(0), 0, bytes(""));
        u.nonce = 0x2;
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 0;
        u.paymentMaxAmount = 0;
        u.combinedGas = 20000000;
        u.signature = _sig(k, u);

        oc.execute(abi.encode(u));
    }

    function testInvalidateNonce(uint96 seqKey, uint64 seq, uint64 seq2) public {
        uint256 nonce = (uint256(seqKey) << 64) | uint256(seq);
        Orchestrator.Intent memory u;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        u.eoa = d.eoa;

        vm.startPrank(u.eoa);
        if (seq == type(uint64).max) {
            d.d.invalidateNonce(nonce);
            assertEq(d.d.getNonce(seqKey), nonce);
            return;
        }

        d.d.invalidateNonce(nonce);
        assertEq(d.d.getNonce(seqKey), nonce + 1);

        if (_randomChance(2)) {
            uint256 nonce2 = (uint256(seqKey) << 64) | uint256(seq2);
            if (seq2 < uint64(d.d.getNonce(seqKey))) {
                vm.expectRevert(bytes4(keccak256("NewSequenceMustBeLarger()")));
                d.d.invalidateNonce(nonce2);
            } else {
                d.d.invalidateNonce(nonce2);
                assertEq(uint64(d.d.getNonce(seqKey)), Math.min(uint256(seq2) + 1, 2 ** 64 - 1));
            }
            if (uint64(d.d.getNonce(seqKey)) == type(uint64).max) return;
            seq = seq2;
        }

        vm.deal(u.eoa, 2 ** 128 - 1);
        u.executionData = _thisTargetFunctionExecutionData(
            _bound(_random(), 0, 2 ** 32 - 1), _truncateBytes(_randomBytes(), 0xff)
        );
        u.nonce = d.d.getNonce(seqKey);
        paymentToken.mint(u.eoa, 2 ** 128 - 1);
        u.paymentToken = address(paymentToken);
        u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
        u.paymentMaxAmount = u.paymentAmount;
        u.combinedGas = 10000000;
        u.signature = _sig(d, u);

        if (seq > type(uint64).max - 2) {
            assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("InvalidNonce()")));
        } else {
            assertEq(oc.execute(abi.encode(u)), 0);
        }
    }

    function _simulateExecute(_EstimateGasParams memory p)
        internal
        returns (uint256 gUsed, uint256 gCombined)
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

    function testExecutePreCalls() public {
        uint256 ephemeralPK = _randomPrivateKey();
        address eoa = vm.addr(ephemeralPK);

        vm.etch(eoa, abi.encodePacked(hex"ef0100", account));

        PassKey memory kSession = _randomSecp256r1PassKey();

        Orchestrator.SignedCall memory preCall;
        preCall.eoa = address(0);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, kSession.k);
        preCall.executionData = abi.encode(calls);
        preCall.nonce = (0xc1d0 << 240);
        preCall.signature = _eoaSig(ephemeralPK, oc.computeDigest(preCall));

        ICommon.SignedCall[] memory preCalls = new ICommon.SignedCall[](1);
        preCalls[0] = preCall;

        oc.executePreCalls(eoa, preCalls);

        assertTrue(MockAccount(payable(eoa)).keyCount() > 0);
    }

    function testExecutePreCallsFromFeePayer() public {
        uint256 ephemeralPK = _randomPrivateKey();
        address eoa = vm.addr(ephemeralPK);

        vm.etch(eoa, abi.encodePacked(hex"ef0100", account));

        // Create a fee payer
        DelegatedEOA memory payer = _randomEIP7702DelegatedEOA();
        paymentToken.mint(address(payer.d), 10 ether);

        PassKey memory kSession = _randomSecp256r1PassKey();

        // Create the pre-call to authorize the session key
        Orchestrator.SignedCall memory preCall;
        preCall.eoa = payer.eoa;

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, kSession.k);
        preCall.executionData = abi.encode(calls);
        preCall.nonce = (0xc1d0 << 240);
        preCall.signature = _eoaSig(payer.privateKey, oc.computeDigest(preCall));

        // Create an Intent with the pre-call and fee payer
        ICommon.Intent memory u;
        u.eoa = eoa;
        u.payer = address(payer.d);
        u.nonce = 0;
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 0.1 ether;
        u.paymentMaxAmount = 0.5 ether;
        u.paymentRecipient = address(oc);
        u.combinedGas = 1000000;

        // Simple execution data (no-op)
        ERC7821.Call[] memory executionCalls = new ERC7821.Call[](1);
        executionCalls[0].to = address(0);
        executionCalls[0].value = 0;
        executionCalls[0].data = "";
        u.executionData = abi.encode(executionCalls);

        // Add the pre-call
        u.encodedPreCalls = new bytes[](1);
        u.encodedPreCalls[0] = abi.encode(preCall);

        // Sign the intent with the ephemeral key and the payment with the payer
        bytes32 digest = oc.computeDigest(u);
        u.signature = _eoaSig(ephemeralPK, digest);
        u.paymentSignature = _eoaSig(payer.privateKey, digest);

        // Execute the intent
        uint256 payerBalanceBefore = paymentToken.balanceOf(address(payer.d));
        assertFalse(MockAccount(payable(payer.eoa)).keyCount() > 0);

        assertEq(oc.execute(abi.encode(u)), 0);

        // Verify the session key was authorized in the payer's account
        assertTrue(MockAccount(payable(payer.eoa)).keyCount() > 0);

        // Verify payment was made by the fee payer
        assertEq(paymentToken.balanceOf(address(payer.d)), payerBalanceBefore - u.paymentAmount);
        assertEq(paymentToken.balanceOf(u.paymentRecipient), u.paymentAmount);
    }

    struct _TestAuthorizeWithPreCallsAndTransferTemps {
        uint256 gExecute;
        uint256 gCombined;
        uint256 gUsed;
        bool success;
        bytes result;
        bool testInvalidPreCallEOA;
        bool testPreCallVerificationError;
        bool testPreCallError;
        bool testInit;
        bool testEOACoalesce;
        bool testSkipNonce;
        uint192 superAdminNonceSeqKey;
        uint192 sessionNonceSeqKey;
        uint256 retrievedSuperAdminNonce;
        uint256 retrievedSessionNonce;
        PassKey kInit;
        DelegatedEOA d;
        address eoa;
    }

    function testInitAndTransferInOneShot(bytes32) public {
        _TestAuthorizeWithPreCallsAndTransferTemps memory t;
        Orchestrator.Intent memory u;

        uint256 ephemeralPK = _randomPrivateKey();
        t.eoa = vm.addr(ephemeralPK);

        vm.etch(t.eoa, abi.encodePacked(hex"ef0100", account));

        u.eoa = t.eoa;
        Orchestrator.SignedCall memory pInit;

        // Prepare Ephemeral Key Authorization
        {
            t.kInit = _randomSecp256r1PassKey(); // This would be WebAuthn in practice.
            t.kInit.k.isSuperAdmin = true;

            ERC7821.Call[] memory initCalls = new ERC7821.Call[](1);
            initCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, t.kInit.k);
            pInit.eoa = t.eoa;

            pInit.executionData = abi.encode(initCalls);
            pInit.nonce = (0xc1d0 << 240);

            pInit.signature = _eoaSig(ephemeralPK, oc.computeDigest(pInit));
        }

        address tokenToTransfer =
            _randomChance(2) ? address(0) : LibClone.clone(address(paymentToken));
        _mint(tokenToTransfer, u.eoa, 2 ** 128 - 1);

        paymentToken.mint(u.eoa, 2 ** 128 - 1);
        u.paymentToken = address(paymentToken);
        u.paymentAmount = _bound(_random(), 0, 0.5 ether);
        u.paymentMaxAmount = u.paymentAmount;
        u.paymentRecipient = address(oc);

        PassKey memory kSession = _randomSecp256r1PassKey();

        Orchestrator.SignedCall memory pSession;

        pSession.eoa = t.eoa;

        // Prepare session passkey authorization Intent.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](5);
            calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, kSession.k);
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector,
                kSession.keyHash,
                _randomChance(2) && tokenToTransfer != address(0) ? tokenToTransfer : _ANY_TARGET,
                _randomChance(2) && tokenToTransfer != address(0)
                    ? bytes4(keccak256("transfer(address,uint256)"))
                    : _ANY_FN_SEL,
                true
            );
            calls[2] = _setSpendLimitCall(
                kSession, address(paymentToken), GuardedExecutor.SpendPeriod.Hour, 1 ether
            );
            calls[3] =
                _setSpendLimitCall(kSession, address(0), GuardedExecutor.SpendPeriod.Hour, 1 ether);
            calls[4] = _setSpendLimitCall(
                kSession, tokenToTransfer, GuardedExecutor.SpendPeriod.Hour, 1 ether
            );
            if (_randomChance(2)) {
                (calls[1], calls[2]) = (calls[2], calls[1]);
            }

            pSession.executionData = abi.encode(calls);
            pSession.nonce = (0xc1d0 << 240) + 1;

            pSession.signature = _sig(t.kInit, oc.computeDigest(pSession));
        }

        u.encodedPreCalls = new bytes[](2);

        // Prepare the enveloping Intent.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall(address(tokenToTransfer), address(0xabcd), 0.5 ether);

            u.executionData = abi.encode(calls);
            u.nonce = 0;

            u.encodedPreCalls[0] = abi.encode(pInit);
            u.encodedPreCalls[1] = abi.encode(pSession);
        }

        // Test without gas estimation.
        u.combinedGas = 10000000;
        u.signature = _sig(kSession, u);
        assertEq(oc.execute(abi.encode(u)), 0);

        assertEq(_balanceOf(tokenToTransfer, address(0xabcd)), 0.5 ether);
    }

    function testAuthorizeWithPreCallsAndTransfer(bytes32) public {
        _TestAuthorizeWithPreCallsAndTransferTemps memory t;
        Orchestrator.Intent memory u;
        Orchestrator.SignedCall memory pInit;

        if (_randomChance(2)) {
            t.d = _randomEIP7702DelegatedEOA();
            t.eoa = t.d.eoa;
        } else {
            t.kInit = _randomSecp256r1PassKey();
            t.kInit.k.isSuperAdmin = true;

            uint256 ephemeralPK = _randomPrivateKey();
            t.eoa = vm.addr(ephemeralPK);

            vm.etch(t.eoa, abi.encodePacked(hex"ef0100", account));

            u.eoa = t.eoa;

            // Prepare Ephemeral Key Authorization
            {
                t.kInit = _randomSecp256r1PassKey(); // This would be WebAuthn in practice.
                t.kInit.k.isSuperAdmin = true;

                ERC7821.Call[] memory initCalls = new ERC7821.Call[](1);
                initCalls[0].data =
                    abi.encodeWithSelector(IthacaAccount.authorize.selector, t.kInit.k);
                pInit.eoa = t.eoa;

                pInit.executionData = abi.encode(initCalls);
                pInit.nonce = (0xc1d0 << 240);

                pInit.signature = _eoaSig(ephemeralPK, oc.computeDigest(pInit));
            }

            t.testInit = true;
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

        Orchestrator.SignedCall memory pSuperAdmin;
        Orchestrator.SignedCall memory pSession;

        if (_randomChance(2)) {
            t.testEOACoalesce = true;
        } else {
            pSuperAdmin.eoa = t.eoa;
            pSession.eoa = t.eoa;
        }

        if (_randomChance(64) && !t.testEOACoalesce) {
            pSession.eoa = _randomUniqueHashedAddress();
            t.testInvalidPreCallEOA = true;
        }

        if (t.testInit) {
            u.encodedPreCalls = new bytes[](3);
        } else {
            u.encodedPreCalls = new bytes[](2);
        }

        // Prepare super admin passkey authorization Intent.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, kSuperAdmin.k);

            pSuperAdmin.executionData = abi.encode(calls);
            // Change this formula accordingly. We just need a non-colliding out-of-order nonce here.
            pSuperAdmin.nonce = (0xc1d0 << 240) | (1 << 64);
            t.superAdminNonceSeqKey = uint192(pSuperAdmin.nonce >> 64);
            if (t.testSkipNonce) {
                pSuperAdmin.nonce = type(uint256).max;
            }

            if (t.testInit) {
                pSuperAdmin.signature = _sig(t.kInit, oc.computeDigest(pSuperAdmin));
            } else {
                pSuperAdmin.signature = _eoaSig(t.d.privateKey, oc.computeDigest(pSuperAdmin));
            }
        }

        // Prepare session passkey authorization Intent.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](3);
            calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, kSession.k);
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
                t.testPreCallError = true;
            }

            pSession.executionData = abi.encode(calls);
            // Change this formula accordingly. We just need a non-colliding out-of-order nonce here.
            pSession.nonce = (0xc1d0 << 240) | (2 << 64);
            t.sessionNonceSeqKey = uint192(pSession.nonce >> 64);
            if (t.testSkipNonce) {
                pSession.nonce = type(uint256).max;
            }

            pSession.signature = _sig(kSuperAdmin, oc.computeDigest(pSession));

            if (_randomChance(64)) {
                pSession.signature = _sig(_randomSecp256r1PassKey(), oc.computeDigest(pSession));
                u.encodedPreCalls[1] = abi.encode(pSession);
                t.testPreCallVerificationError = true;
            }
        }

        // Prepare the enveloping Intent.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall(address(paymentToken), address(0xabcd), 0.5 ether);

            u.executionData = abi.encode(calls);
            u.nonce = 0;

            if (t.testInit) {
                u.encodedPreCalls[0] = abi.encode(pInit);
                u.encodedPreCalls[1] = abi.encode(pSuperAdmin);
                u.encodedPreCalls[2] = abi.encode(pSession);
            } else {
                u.encodedPreCalls[0] = abi.encode(pSuperAdmin);
                u.encodedPreCalls[1] = abi.encode(pSession);
            }
        }

        if (t.testInvalidPreCallEOA) {
            u.combinedGas = 10000000;
            u.signature = _sig(kSession, u);
            assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("InvalidPreCallEOA()")));
            return; // Skip the rest.
        }

        if (t.testPreCallVerificationError) {
            u.combinedGas = 10000000;
            u.signature = _sig(kSession, u);
            assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("PreCallVerificationError()")));
            return; // Skip the rest.
        }

        if (t.testPreCallError) {
            u.combinedGas = 10000000;
            u.signature = _sig(kSession, u);
            assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("PreCallError()")));
            return; // Skip the rest.
        }

        // Test gas estimation.
        if (_randomChance(16)) {
            u.combinedGas += 10_000;
            // Fill with some junk signature, but with the session `keyHash`.
            u.signature = abi.encodePacked(
                keccak256("a"), keccak256("b"), kSession.keyHash, uint8(0), uint8(0)
            );

            (t.gExecute, t.gCombined, t.gUsed) = _estimateGas(u);

            u.combinedGas = t.gCombined;
            u.signature = _sig(kSession, u);

            assertEq(oc.execute{gas: t.gExecute}(abi.encode(u)), 0);
        } else {
            // Otherwise, test without gas estimation.
            u.combinedGas = 10000000;
            u.signature = _sig(kSession, u);
            assertEq(oc.execute(abi.encode(u)), 0);
        }

        assertEq(paymentToken.balanceOf(address(0xabcd)), 0.5 ether);
        t.retrievedSessionNonce = IIthacaAccount(t.eoa).getNonce(t.sessionNonceSeqKey);
        t.retrievedSuperAdminNonce = IIthacaAccount(t.eoa).getNonce(t.superAdminNonceSeqKey);
        if (t.testSkipNonce) {
            assertEq(t.retrievedSessionNonce, uint256(t.sessionNonceSeqKey) << 64);
            assertEq(t.retrievedSuperAdminNonce, uint256(t.superAdminNonceSeqKey) << 64);
        } else {
            assertEq(t.retrievedSessionNonce, pSession.nonce | 1);
            assertEq(t.retrievedSuperAdminNonce, pSuperAdmin.nonce | 1);
        }
    }

    function testAccountPaymaster(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        DelegatedEOA memory payer = _randomEIP7702DelegatedEOA();

        bool isNative = _randomChance(2);

        if (isNative) {
            vm.deal(address(payer.d), type(uint192).max);
        } else {
            _mint(address(paymentToken), address(payer.d), type(uint192).max);
        }

        // 1 ether in the EOA for execution.
        vm.deal(address(d.d), 1 ether);

        Orchestrator.Intent memory u;

        u.eoa = d.eoa;
        u.payer = address(payer.d);

        u.nonce = d.d.getNonce(0);
        u.paymentToken = isNative ? address(0) : address(paymentToken);
        u.paymentAmount = _bound(_random(), 0, 5 ether);
        u.paymentMaxAmount = _bound(_random(), u.paymentAmount, 10 ether);

        u.executionData = _transferExecutionData(address(0), address(0xabcd), 1 ether);
        u.paymentRecipient = address(0x12345);

        bytes32 digest = oc.computeDigest(u);

        uint256 snapshot = vm.snapshotState();
        // To allow paymasters to be used in simulation mode.
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);
        (uint256 gExecute, uint256 gCombined,) = _estimateGas(u);
        vm.revertToStateAndDelete(snapshot);
        u.combinedGas = gCombined;

        digest = oc.computeDigest(u);
        u.signature = _eoaSig(d.privateKey, digest);
        u.paymentSignature = _eoaSig(payer.privateKey, digest);

        uint256 payerBalanceBefore = _balanceOf(u.paymentToken, address(payer.d));
        assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
        assertEq(d.d.getNonce(0), u.nonce + 1);
        assertEq(_balanceOf(u.paymentToken, u.paymentRecipient), u.paymentAmount);
        assertEq(_balanceOf(u.paymentToken, address(payer.d)), payerBalanceBefore - u.paymentAmount);
        assertEq(address(d.d).balance, 0);
        assertEq(address(0xabcd).balance, 1 ether);
    }

    struct _TestPayViaAnotherPayerTemps {
        MockPayerWithState withState;
        MockPayerWithSignature withSignature;
        DelegatedEOA withSignatureEOA;
        address token;
        uint256 funds;
        bool isWithState;
        bool corruptSignature;
        bool unapprovedOrchestrator;
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

        t.withState.setApprovedOrchestrator(address(oc), true);
        t.withSignature.setApprovedOrchestrator(address(oc), true);
        t.withSignature.setSigner(t.withSignatureEOA.eoa);

        t.token = _randomChance(2) ? address(0) : address(paymentToken);
        t.isWithState = _randomChance(2);

        Orchestrator.Intent memory u;
        t.d = _randomEIP7702DelegatedEOA();
        vm.deal(t.d.eoa, type(uint192).max);

        u.eoa = t.d.eoa;
        u.nonce = t.d.d.getNonce(0);
        u.combinedGas = 1000000;
        u.payer = t.isWithState ? address(t.withState) : address(t.withSignature);
        u.paymentToken = t.token;
        u.paymentAmount = _bound(_random(), 0, 5 ether);
        u.paymentMaxAmount = _bound(_random(), u.paymentAmount, 10 ether);
        u.executionData = _transferExecutionData(address(0), address(0xabcd), 1 ether);
        u.paymentRecipient = address(oc);

        t.funds = _bound(_random(), 0, 5 ether);
        if (t.isWithState) {
            t.withState.increaseFunds(u.paymentToken, u.eoa, t.funds);
        } else {
            bytes32 digest = oc.computeDigest(u);
            digest = t.withSignature.computeSignatureDigest(digest);
            u.paymentSignature = _sig(t.withSignatureEOA, digest);
            t.corruptSignature = _randomChance(2);
            if (t.corruptSignature) {
                u.paymentSignature = abi.encodePacked(keccak256(u.paymentSignature));
            }
        }
        t.balanceBefore = _balanceOf(t.token, u.payer);

        u.signature = _eoaSig(t.d.privateKey, u);

        t.unapprovedOrchestrator = _randomChance(32);
        if (t.unapprovedOrchestrator) {
            t.withState.setApprovedOrchestrator(address(oc), false);
            t.withSignature.setApprovedOrchestrator(address(oc), false);
        }
        if ((t.unapprovedOrchestrator && u.paymentAmount != 0)) {
            assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("Unauthorized()")));

            if (u.paymentAmount != 0) {
                assertEq(t.d.d.getNonce(0), u.nonce);
            }

            assertEq(_balanceOf(t.token, u.payer), t.balanceBefore);
            assertEq(_balanceOf(address(0), address(0xabcd)), 0);
        } else if (t.isWithState && u.paymentAmount > t.funds && u.paymentAmount != 0) {
            // Arithmetic underflow error
            assertEq(
                oc.execute(abi.encode(u)),
                0x4e487b7100000000000000000000000000000000000000000000000000000000
            );

            if (u.paymentAmount > t.funds) {
                // Pre payment will not happen
                assertEq(t.d.d.getNonce(0), u.nonce);
                assertEq(_balanceOf(t.token, u.payer), t.balanceBefore);
                assertEq(_balanceOf(address(0), address(0xabcd)), 0);
            } else {
                // Pre payment will happen, post payment will fail
                assertEq(t.d.d.getNonce(0), u.nonce + 1);
                assertEq(_balanceOf(t.token, u.payer), t.balanceBefore - u.paymentAmount);
                // Execution should have failed
                assertEq(_balanceOf(address(0), address(0xabcd)), 0);
            }
        } else if ((!t.isWithState && t.corruptSignature && u.paymentAmount != 0)) {
            // Pre payment will not happen
            assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("InvalidSignature()")));
            // If prePayment is 0, then nonce is incremented, because the prePayment doesn't fail.
            if (u.paymentAmount == 0) {
                assertEq(t.d.d.getNonce(0), u.nonce + 1);
            } else {
                assertEq(t.d.d.getNonce(0), u.nonce);
            }
            assertEq(_balanceOf(t.token, u.payer), t.balanceBefore);
            assertEq(_balanceOf(address(0), address(0xabcd)), 0);
        } else {
            assertEq(oc.execute(abi.encode(u)), 0);
            assertEq(t.d.d.getNonce(0), u.nonce + 1);
            assertEq(_balanceOf(t.token, u.payer), t.balanceBefore - u.paymentAmount);
            assertEq(_balanceOf(address(0), address(0xabcd)), 1 ether);
        }
    }

    struct _TestAccountImplementationVerificationTemps {
        bool testImplementationCheck;
        bool requireWrongImplementation;
        DelegatedEOA d;
    }

    function testAccountImplementationVerification(bytes32) public {
        _TestAccountImplementationVerificationTemps memory t;
        t.d = _randomEIP7702DelegatedEOA();
        t.testImplementationCheck = _randomChance(2);
        t.requireWrongImplementation = _randomChance(2);

        Orchestrator.Intent memory u;
        vm.deal(t.d.eoa, type(uint192).max);

        u.eoa = t.d.eoa;
        u.nonce = t.d.d.getNonce(0);
        u.combinedGas = 1000000;
        u.executionData = _transferExecutionData(address(0), address(0xabcd), 1 ether);
        u.signature = _eoaSig(t.d.privateKey, u);

        if (t.testImplementationCheck) {
            if (t.requireWrongImplementation) {
                u.supportedAccountImplementation = _randomUniqueHashedAddress();
            } else {
                u.supportedAccountImplementation = oc.accountImplementationOf(u.eoa);
                assertEq(u.supportedAccountImplementation, accountImplementation);
            }
        }

        if (t.testImplementationCheck && t.requireWrongImplementation) {
            assertEq(
                oc.execute(abi.encode(u)), bytes4(keccak256("UnsupportedAccountImplementation()"))
            );
            assertEq(t.d.d.getNonce(0), u.nonce);
            assertEq(_balanceOf(address(0), address(0xabcd)), 0);
        } else {
            assertEq(oc.execute(abi.encode(u)), 0);
            assertEq(t.d.d.getNonce(0), u.nonce + 1);
            assertEq(_balanceOf(address(0), address(0xabcd)), 1 ether);
        }
    }

    struct _TestMultiSigTemps {
        DelegatedEOA d;
        MultiSigSigner multiSigSigner;
        uint256 numKeys;
        MultiSigKey multiSigKey;
    }

    function testMultiSig(bytes32) public {
        _TestMultiSigTemps memory t;
        t.d = _randomEIP7702DelegatedEOA();

        vm.deal(t.d.eoa, type(uint192).max);

        t.multiSigSigner = new MultiSigSigner();
        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(
                address(t.multiSigSigner), bytes12(uint96(_bound(_random(), 0, type(uint96).max)))
            )
        });

        // Setup Phase
        vm.startPrank(t.d.eoa);
        t.d.d.authorize(t.multiSigKey.k);

        t.numKeys = _bound(_random(), 0, 32);
        t.numKeys = 3;
        t.multiSigKey.threshold = _bound(_random(), 0, t.numKeys);

        t.multiSigKey.owners = new PassKey[](t.numKeys);

        bytes32[] memory ownerKeyHashes = new bytes32[](t.numKeys);

        for (uint256 i; i < t.numKeys; ++i) {
            PassKey memory passKey =
                _randomChance(2) ? _randomSecp256k1PassKey() : _randomSecp256r1PassKey();
            t.d.d.authorize(passKey.k);
            t.multiSigKey.owners[i] = passKey;
            ownerKeyHashes[i] = _hash(passKey.k);
        }

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: address(t.multiSigSigner),
            value: 0,
            data: abi.encodeWithSelector(
                MultiSigSigner.initConfig.selector,
                _hash(t.multiSigKey.k),
                t.multiSigKey.threshold,
                ownerKeyHashes
            )
        });

        if (t.multiSigKey.threshold == 0) vm.expectRevert(bytes4(keccak256("InvalidThreshold()")));
        t.d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls));
        if (t.multiSigKey.threshold == 0) return;

        vm.stopPrank();

        assertEq(t.d.d.keyCount(), t.numKeys + 1);

        // Try to set config again
        vm.startPrank(t.d.eoa);
        vm.expectRevert(bytes4(keccak256("ConfigAlreadySet()")));
        t.multiSigSigner.initConfig(_hash(t.multiSigKey.k), 1, ownerKeyHashes);
        vm.stopPrank();

        calls[0] = ERC7821.Call({
            to: address(t.multiSigSigner),
            value: 0,
            data: abi.encodeWithSelector(
                MultiSigSigner.addOwner.selector, _hash(t.multiSigKey.k), bytes32(_random())
            )
        });

        vm.prank(t.d.eoa);
        vm.expectRevert(bytes4(keccak256("InvalidKeyHash()")));
        t.d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls));

        Orchestrator.Intent memory u;
        u.eoa = t.d.eoa;
        u.nonce = t.d.d.getNonce(0);
        u.executionData = abi.encode(calls);
        u.signature = _sig(t.multiSigKey, bytes32(_random()));
        (uint256 gExecute, uint256 gCombined,) = _estimateGasForMultiSigKey(t.multiSigKey, u);
        u.combinedGas = gCombined;
        u.signature = _sig(t.multiSigKey, u);

        // Test unwrapAndValidateSignature
        bytes32 digest = oc.computeDigest(u);
        (bool isValid, bytes32 keyHash) =
            t.d.d.unwrapAndValidateSignature(digest, _sig(t.multiSigKey, digest));

        assertEq(isValid, true);
        assertEq(keyHash, _hash(t.multiSigKey.k));

        assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
        (uint256 _threshold, bytes32[] memory o) =
            t.multiSigSigner.getConfig(address(t.d.d), _hash(t.multiSigKey.k));

        assertEq(o.length, t.multiSigKey.owners.length + 1);
        assertEq(_threshold, t.multiSigKey.threshold);

        // Test setThreshold
        {
            uint256 newThreshold = _bound(_random(), 0, t.multiSigKey.owners.length);
            calls[0] = ERC7821.Call({
                to: address(t.multiSigSigner),
                value: 0,
                data: abi.encodeWithSelector(
                    MultiSigSigner.setThreshold.selector, _hash(t.multiSigKey.k), newThreshold
                )
            });

            u.nonce = t.d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(t.multiSigKey, bytes32(_random()));
            if (newThreshold == 0) {
                vm.expectRevert(bytes4(keccak256("InvalidThreshold()")));
            }

            (gExecute, gCombined,) = _estimateGasForMultiSigKey(t.multiSigKey, u);

            u.combinedGas = gCombined;
            u.signature = _sig(t.multiSigKey, u);

            if (newThreshold > 0) {
                assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
                (_threshold, o) = t.multiSigSigner.getConfig(address(t.d.d), _hash(t.multiSigKey.k));

                assertEq(_threshold, newThreshold);
                assertEq(o.length, t.multiSigKey.owners.length + 1);

                t.multiSigKey.threshold = newThreshold;
            }
        }

        // Test removeOwner
        {
            uint256 removeIndex = _bound(_random(), 0, o.length - 1);
            calls[0] = ERC7821.Call({
                to: address(t.multiSigSigner),
                value: 0,
                data: abi.encodeWithSelector(
                    MultiSigSigner.removeOwner.selector, _hash(t.multiSigKey.k), o[removeIndex]
                )
            });

            u.nonce = t.d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(t.multiSigKey, bytes32(_random()));
            (gExecute, gCombined,) = _estimateGasForMultiSigKey(t.multiSigKey, u);
            u.combinedGas = gCombined;
            u.signature = _sig(t.multiSigKey, u);

            assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
            (_threshold, o) = t.multiSigSigner.getConfig(address(t.d.d), _hash(t.multiSigKey.k));

            assertEq(o.length, t.multiSigKey.owners.length);
            assertEq(_threshold, t.multiSigKey.threshold);
        }
    }

    Merkle merkleHelper;

    struct _TestMultiChainIntentTemps {
        // Core test data
        SimpleFunder funder;
        SimpleSettler settler;
        uint256 funderPrivateKey;
        MockPaymentToken usdcMainnet;
        MockPaymentToken usdcArb;
        MockPaymentToken usdcBase;
        DelegatedEOA d;
        PassKey k;
        // Intent data
        ICommon.Intent baseIntent;
        ICommon.Intent arbIntent;
        ICommon.Intent outputIntent;
        // Merkle data
        bytes32[] leafs;
        bytes32 root;
        bytes rootSig;
        // Common addresses
        address gasWallet;
        address relay;
        address friend;
        address settlementOracle;
        // Escrow contracts
        Escrow escrowBase;
        Escrow escrowArb;
        // Escrow data
        bytes32 settlementId;
        bytes32 escrowIdBase;
        bytes32 escrowIdArb;
        // Other common data
        bytes[] encodedIntents;
        bytes4[] errs;
        uint256 snapshot;
    }

    function testMultiChainIntent() public {
        _TestMultiChainIntentTemps memory t;

        address[] memory ocs = new address[](1);
        ocs[0] = address(oc);

        // Initialize core test data
        t.funderPrivateKey = _randomPrivateKey();
        t.settlementOracle = makeAddr("SETTLEMENT_ORACLE");
        t.funder = new SimpleFunder(vm.addr(t.funderPrivateKey), address(this));

        t.funder.setOrchestrators(ocs, true);
        t.settler = new SimpleSettler(t.settlementOracle);
        t.gasWallet = makeAddr("GAS_WALLET");
        t.relay = makeAddr("RELAY");
        t.friend = makeAddr("FRIEND");

        // ------------------------------------------------------------------
        // SimpleFunder ‑ gas wallet set-up & basic functionality checks
        // ------------------------------------------------------------------
        {
            address[] memory gasWallets = new address[](1);
            gasWallets[0] = t.gasWallet;
            // Owner (this test contract) whitelists the gas wallet.
            t.funder.setGasWallet(gasWallets, true);

            // Fund the SimpleFunder with native tokens so the gas wallet can pull gas.
            vm.deal(address(t.funder), 2 ether);
            uint256 gasBalanceBefore = t.gasWallet.balance;

            // Gas wallet successfully pulls 1 ether.
            vm.prank(t.gasWallet);
            t.funder.pullGas(1 ether);
            assertEq(t.gasWallet.balance, gasBalanceBefore + 1 ether);
            assertEq(address(t.funder).balance, 1 ether);
        }
        // ------------------------------------------------------------------

        merkleHelper = new Merkle();
        // USDC has different address on all chains
        t.usdcMainnet = new MockPaymentToken();
        t.usdcArb = new MockPaymentToken();
        t.usdcBase = new MockPaymentToken();

        // Deploy Escrow contracts on input chains
        t.escrowBase = new Escrow();
        t.escrowArb = new Escrow();

        // Deploy the account on all chains
        t.d = _randomEIP7702DelegatedEOA();
        vm.deal(t.d.eoa, 10 ether);

        // Authorize the passskey on all chains
        t.k = _randomPassKey();
        t.k.k.isSuperAdmin = true;
        vm.prank(t.d.eoa);
        t.d.d.authorize(t.k.k);

        // Test Scenario:
        // Send 1000 USDC to a friend on Mainnet. By pulling funds from Base and Arb.
        // User has 0 USDC on Mainnet.
        // Relay fees (Bridging + gas on all chains included) is 100 USDC.

        // 1. Prepare the output intent first to get its digest as settlementId
        t.outputIntent.eoa = t.d.eoa;
        t.outputIntent.nonce = t.d.d.getNonce(0);
        t.outputIntent.executionData =
            _transferExecutionData(address(t.usdcMainnet), t.friend, 1000);
        t.outputIntent.combinedGas = 1000000;
        t.outputIntent.settler = address(t.settler);
        t.outputIntent.isMultichain = true;

        {
            bytes[] memory encodedFundTransfers = new bytes[](1);
            encodedFundTransfers[0] =
                abi.encode(ICommon.Transfer({token: address(t.usdcMainnet), amount: 1000}));

            t.outputIntent.encodedFundTransfers = encodedFundTransfers;
            t.outputIntent.funder = address(t.funder);

            // Set settlerContext with input chains
            uint256[] memory _inputChains = new uint256[](2);
            _inputChains[0] = 8453; // Base
            _inputChains[1] = 42161; // Arbitrum
            t.outputIntent.settlerContext = abi.encode(_inputChains);
        }

        // Compute the output intent digest to use as settlementId
        vm.chainId(1); // Mainnet
        t.settlementId = oc.computeDigest(t.outputIntent);

        // Base Intent with escrow execution data
        t.baseIntent.eoa = t.d.eoa;
        t.baseIntent.nonce = t.d.d.getNonce(0);
        t.baseIntent.combinedGas = 1000000;
        t.baseIntent.isMultichain = true;

        // Create Base escrow execution data
        {
            IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
            escrows[0] = IEscrow.Escrow({
                salt: bytes12(uint96(_random())),
                depositor: t.d.eoa,
                recipient: t.relay,
                token: address(t.usdcBase),
                settler: address(t.settler),
                sender: address(oc), // Orchestrator on output chain (mainnet)
                settlementId: t.settlementId,
                senderChainId: 1, // Mainnet chain ID
                escrowAmount: 600,
                refundAmount: 600, // Full refund if settlement fails
                refundTimestamp: block.timestamp + 1 hours
            });
            t.escrowIdBase = keccak256(abi.encode(escrows[0]));

            ERC7821.Call[] memory calls = new ERC7821.Call[](2);
            // First approve the escrow contract
            calls[0] = ERC7821.Call({
                to: address(t.usdcBase),
                value: 0,
                data: abi.encodeWithSignature(
                    "approve(address,uint256)", address(t.escrowBase), 600
                )
            });
            // Then call escrow function
            calls[1] = ERC7821.Call({
                to: address(t.escrowBase),
                value: 0,
                data: abi.encodeWithSelector(IEscrow.escrow.selector, escrows)
            });
            t.baseIntent.executionData = abi.encode(calls);
        }

        // Arbitrum Intent with escrow execution data
        t.arbIntent.eoa = t.d.eoa;
        t.arbIntent.nonce = t.d.d.getNonce(0);
        t.arbIntent.combinedGas = 1000000;
        t.arbIntent.isMultichain = true;
        // Create Arbitrum escrow execution data
        {
            IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
            escrows[0] = IEscrow.Escrow({
                salt: bytes12(uint96(_random())),
                depositor: t.d.eoa,
                recipient: t.relay,
                token: address(t.usdcArb),
                settler: address(t.settler),
                sender: address(oc), // Orchestrator on output chain (mainnet)
                settlementId: t.settlementId,
                senderChainId: 1, // Mainnet chain ID
                escrowAmount: 500,
                refundAmount: 500, // Full refund if settlement fails
                refundTimestamp: block.timestamp + 1 hours
            });
            t.escrowIdArb = keccak256(abi.encode(escrows[0]));

            ERC7821.Call[] memory calls = new ERC7821.Call[](2);
            // First approve the escrow contract
            calls[0] = ERC7821.Call({
                to: address(t.usdcArb),
                value: 0,
                data: abi.encodeWithSignature("approve(address,uint256)", address(t.escrowArb), 500)
            });
            // Then call escrow function
            calls[1] = ERC7821.Call({
                to: address(t.escrowArb),
                value: 0,
                data: abi.encodeWithSelector(IEscrow.escrow.selector, escrows)
            });
            t.arbIntent.executionData = abi.encode(calls);
        }

        // Compute merkle tree data
        _computeMerkleData(t);

        t.encodedIntents = new bytes[](1);

        // Setup complete.
        t.snapshot = vm.snapshotState();
        // 3. Actions on Base
        vm.chainId(8453);
        // User has 600 USDC on base
        t.usdcBase.mint(t.d.eoa, 600);

        t.encodedIntents[0] = abi.encode(t.baseIntent);
        // User escrows funds on Base
        vm.expectEmit(true, false, false, false, address(t.escrowBase));
        emit Escrow.EscrowCreated(t.escrowIdBase);
        vm.prank(t.gasWallet);
        t.errs = oc.execute(t.encodedIntents);
        assertEq(uint256(bytes32(t.errs[0])), 0);
        // Verify funds are escrowed, not transferred yet
        vm.assertEq(t.usdcBase.balanceOf(address(t.escrowBase)), 600);
        vm.assertEq(t.usdcBase.balanceOf(t.relay), 0);

        // 4. Action on Arb
        vm.revertToState(t.snapshot);
        vm.chainId(42161);
        // User has 500 USDC on arb
        t.usdcArb.mint(t.d.eoa, 500);
        // Unhappy case, try to send base intent to arb
        t.encodedIntents[0] = abi.encode(t.baseIntent);
        vm.prank(t.gasWallet);
        t.errs = oc.execute(t.encodedIntents);
        assertEq(
            uint256(bytes32(t.errs[0])), uint256(bytes32(bytes4(keccak256("VerificationError()"))))
        );

        // Try to send wrong proof
        {
            bytes32[] memory wrongLeafs = new bytes32[](3);

            // Some random leaf
            wrongLeafs[0] = oc.computeDigest(t.arbIntent);
            wrongLeafs[1] = oc.computeDigest(t.arbIntent);
            wrongLeafs[2] = oc.computeDigest(t.outputIntent);

            bytes memory correctSig = t.arbIntent.signature;

            t.arbIntent.signature =
                abi.encode(merkleHelper.getProof(wrongLeafs, 1), t.root, t.rootSig);
            t.encodedIntents[0] = abi.encode(t.arbIntent);
            vm.prank(t.gasWallet);
            t.errs = oc.execute(t.encodedIntents);
            assertEq(
                uint256(bytes32(t.errs[0])),
                uint256(bytes32(bytes4(keccak256("VerificationError()"))))
            );

            // Restore correct sig
            t.arbIntent.signature = correctSig;
        }

        // User escrows funds on Arb
        t.encodedIntents[0] = abi.encode(t.arbIntent);
        vm.expectEmit(true, false, false, false, address(t.escrowArb));
        emit Escrow.EscrowCreated(t.escrowIdArb);
        vm.prank(t.gasWallet);
        t.errs = oc.execute(t.encodedIntents);
        assertEq(uint256(bytes32(t.errs[0])), 0);
        // Verify funds are escrowed, not transferred yet
        vm.assertEq(t.usdcArb.balanceOf(address(t.escrowArb)), 500);
        vm.assertEq(t.usdcArb.balanceOf(t.relay), 0);

        // 5. Action on Mainnet (Destination Chain)
        vm.revertToState(t.snapshot);
        vm.chainId(1);
        // Relay has funds on mainnet for settlement. User has no funds.
        t.usdcMainnet.mint(t.relay, 1000);

        vm.prank(makeAddr("RANDOM_RELAY_ADDRESS"));
        t.usdcMainnet.mint(address(t.funder), 1000);

        // Expect settler.send to be called during outputIntent execution
        vm.expectEmit(true, true, true, false, address(t.settler));
        emit SimpleSettler.Sent(address(oc), t.settlementId, 8453); // Base
        vm.expectEmit(true, true, true, false, address(t.settler));
        emit SimpleSettler.Sent(address(oc), t.settlementId, 42161); // Arbitrum

        // Relay funds the user account, and the intended execution happens.
        t.encodedIntents[0] = abi.encode(t.outputIntent);
        vm.prank(t.gasWallet);
        t.errs = oc.execute(t.encodedIntents);
        assertEq(uint256(bytes32(t.errs[0])), 0);
        vm.assertEq(t.usdcMainnet.balanceOf(t.friend), 1000);

        // 6. Settlement Phase - After outputIntent is executed successfully
        // The orchestrator emits Sent events using the output intent digest as settlementId

        // First, let's check that the Sent events were emitted
        uint256[] memory inputChains = new uint256[](2);
        inputChains[0] = 8453; // Base
        inputChains[1] = 42161; // Arbitrum

        // The orchestrator calls send on the settler to emit events
        // Using the output intent digest as the settlementId
        vm.expectEmit(true, true, true, false, address(t.settler));
        emit SimpleSettler.Sent(address(oc), t.settlementId, 8453); // Base
        vm.expectEmit(true, true, true, false, address(t.settler));
        emit SimpleSettler.Sent(address(oc), t.settlementId, 42161); // Arbitrum
        vm.prank(address(oc));
        t.settler.send(t.settlementId, abi.encode(inputChains));

        // Now the settler owner (settlement oracle) writes the settlement attestation
        // This represents the off-chain process where the oracle verifies the Sent events
        // and writes the settlement on all input chains
        vm.prank(t.settlementOracle);
        t.settler.write(address(oc), t.settlementId, 1); // Mainnet attestation

        // 7. Settle on Base chain - release escrowed funds
        vm.revertToState(t.snapshot);
        vm.chainId(8453);

        // Re-execute the escrow on Base (to recreate the state)
        t.usdcBase.mint(t.d.eoa, 600);
        t.encodedIntents[0] = abi.encode(t.baseIntent);
        vm.expectEmit(true, false, false, false, address(t.escrowBase));
        emit Escrow.EscrowCreated(t.escrowIdBase);
        vm.prank(t.gasWallet);
        oc.execute(t.encodedIntents);

        // Settler owner needs to write the settlement on Base chain too
        vm.prank(t.settlementOracle);
        t.settler.write(address(oc), t.settlementId, 1); // Write that mainnet orchestrator attested

        // Now settle the escrow
        vm.expectEmit(true, false, false, false, address(t.escrowBase));
        emit Escrow.EscrowSettled(t.escrowIdBase);
        vm.prank(t.relay); // Relay can call settle

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = t.escrowIdBase;
        t.escrowBase.settle(escrowIds);

        // Verify funds are transferred to relay
        vm.assertEq(t.usdcBase.balanceOf(t.relay), 600);
        vm.assertEq(t.usdcBase.balanceOf(address(t.escrowBase)), 0);

        // 8. Settle on Arbitrum chain - release escrowed funds
        vm.revertToState(t.snapshot);
        vm.chainId(42161);

        // Re-execute the escrow on Arbitrum (to recreate the state)
        t.usdcArb.mint(t.d.eoa, 500);
        t.encodedIntents[0] = abi.encode(t.arbIntent);
        vm.expectEmit(true, false, false, false, address(t.escrowArb));
        emit Escrow.EscrowCreated(t.escrowIdArb);
        vm.prank(t.gasWallet);
        oc.execute(t.encodedIntents);

        // Settler owner needs to write the settlement on Arbitrum chain too
        vm.prank(t.settlementOracle);
        t.settler.write(address(oc), t.settlementId, 1); // Write that mainnet orchestrator attested

        // Now settle the escrow
        vm.expectEmit(true, false, false, false, address(t.escrowArb));
        emit Escrow.EscrowSettled(t.escrowIdArb);
        vm.prank(t.relay); // Relay can call settle

        bytes32[] memory escrowIdsArb = new bytes32[](1);
        escrowIdsArb[0] = t.escrowIdArb;
        t.escrowArb.settle(escrowIdsArb);

        // Verify funds are transferred to relay
        vm.assertEq(t.usdcArb.balanceOf(t.relay), 500);
        vm.assertEq(t.usdcArb.balanceOf(address(t.escrowArb)), 0);

        // ------------------------------------------------------------------
        // Test invalid funder signature - should revert
        // ------------------------------------------------------------------
        vm.revertToState(t.snapshot);
        vm.chainId(1);
        {
            // Setup funds for the test
            t.usdcMainnet.mint(t.relay, 1000);
            vm.prank(makeAddr("RANDOM_RELAY_ADDRESS"));
            t.usdcMainnet.mint(address(t.funder), 1000);

            // Reset encodedFundTransfers back to original single transfer
            bytes[] memory originalTransfers = new bytes[](1);
            originalTransfers[0] =
                abi.encode(ICommon.Transfer({token: address(t.usdcMainnet), amount: 1000}));
            t.outputIntent.encodedFundTransfers = originalTransfers;

            // Create an invalid signature by using a wrong private key
            uint256 wrongPrivateKey = _randomPrivateKey();
            // Recompute merkle data since we need the original digest
            _computeMerkleData(t);

            t.outputIntent.funderSignature = _eoaSig(wrongPrivateKey, t.leafs[2]);

            t.encodedIntents[0] = abi.encode(t.outputIntent);
            vm.prank(t.gasWallet);
            t.errs = oc.execute(t.encodedIntents);

            // Check that it reverted with InvalidFunderSignature error
            assertEq(t.errs[0], bytes4(keccak256("InvalidFunderSignature()")));
        }

        // ------------------------------------------------------------------
        // Gas wallet blacklist check – after removal it should no longer pull gas.
        // ------------------------------------------------------------------
        address[] memory removeGasWallets = new address[](1);
        removeGasWallets[0] = t.gasWallet;
        t.funder.setGasWallet(removeGasWallets, false);
        vm.prank(t.gasWallet);
        vm.expectRevert(bytes4(keccak256("OnlyGasWallet()")));
        t.funder.pullGas(0.1 ether);
        // ------------------------------------------------------------------
    }

    function _computeMerkleData(_TestMultiChainIntentTemps memory t) internal {
        t.leafs = new bytes32[](3);
        vm.chainId(8453);
        t.leafs[0] = oc.computeDigest(t.baseIntent);
        vm.chainId(42161);
        t.leafs[1] = oc.computeDigest(t.arbIntent);
        vm.chainId(1);
        t.leafs[2] = oc.computeDigest(t.outputIntent);

        t.root = merkleHelper.getRoot(t.leafs);

        // 2. User signs the root in a single click.
        t.rootSig = _sig(t.k, t.root);

        t.outputIntent.funderSignature = _eoaSig(t.funderPrivateKey, t.leafs[2]);

        t.baseIntent.signature = abi.encode(merkleHelper.getProof(t.leafs, 0), t.root, t.rootSig);
        t.arbIntent.signature = abi.encode(merkleHelper.getProof(t.leafs, 1), t.root, t.rootSig);
        t.outputIntent.signature = abi.encode(merkleHelper.getProof(t.leafs, 2), t.root, t.rootSig);
    }
}
