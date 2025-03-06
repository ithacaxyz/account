// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockGasBurner} from "./utils/mocks/MockGasBurner.sol";

contract EntryPointTest is BaseTest {
    MockGasBurner gasBurner;

    function setUp() public virtual override {
        super.setUp();
        gasBurner = new MockGasBurner();
    }

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
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, 500 ether);

        _SimulateExecute2Temps memory t;

        gasBurner.setRandomness(1); // Warm the storage first.

        t.gasToBurn = _bound(_random(), 0, _randomChance(32) ? 15000000 : 300000);
        do {
            t.randomness = _randomUniform();
        } while (t.randomness == 0);
        emit LogUint("gasToBurn", t.gasToBurn);

        t.executionData = _executionData(
            address(gasBurner),
            abi.encodeWithSignature("burnGas(uint256,uint256)", t.gasToBurn, t.randomness)
        );

        EntryPoint.UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = t.executionData;
        u.payer = address(0x00);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 0.1 ether;
        u.paymentMaxAmount = 0.5 ether;
        u.paymentPerGas = 1e9;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            u.signature = abi.encodePacked(r, s, v);
        }

        (t.success, t.result) =
            address(ep).call(abi.encodeWithSignature("simulateExecute2(bytes)", abi.encode(u)));

        assertFalse(t.success);
        assertEq(bytes4(LibBytes.load(t.result, 0x00)), EntryPoint.SimulationResult2.selector);

        t.gExecute = uint256(LibBytes.load(t.result, 0x04));
        t.gCombined = uint256(LibBytes.load(t.result, 0x24));
        t.gUsed = uint256(LibBytes.load(t.result, 0x44));
        emit LogUint("gExecute", t.gExecute);
        emit LogUint("gCombined", t.gCombined);
        emit LogUint("gUsed", t.gUsed);
        assertEq(bytes4(LibBytes.load(t.result, 0x64)), 0);

        u.combinedGas = t.gCombined;
        u.signature = _sig(d, u);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateExecute2WithPassKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        vm.deal(d.eoa, 10 ether);
        paymentToken.mint(d.eoa, 50 ether);

        PassKey memory k = _randomPassKey(); // Can be r1 or k1.
        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        _SimulateExecute2Temps memory t;

        t.gasToBurn = _bound(_random(), 0, _randomChance(32) ? 15000000 : 300000);
        do {
            t.randomness = _randomUniform();
        } while (t.randomness == 0);
        emit LogUint("gasToBurn", t.gasToBurn);
        t.executionData = _executionData(
            address(gasBurner),
            abi.encodeWithSignature("burnGas(uint256,uint256)", t.gasToBurn, t.randomness)
        );

        EntryPoint.UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = t.executionData;
        u.payer = address(0x00);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 0.1 ether;
        u.paymentMaxAmount = 0.5 ether;
        u.paymentPerGas = 1e9;

        // Just fill with some non-zero junk P256 signature that contains the `keyHash`,
        // so that the `simulateExecute2` knows that
        // it needs to add the variance for non-precompile P256 verification.
        // We need the `keyHash` in the signature so that the simulation is able
        // to hit all the gas for the GuardedExecutor stuff for the `keyHash`.
        u.signature = abi.encodePacked(keccak256("a"), keccak256("b"), k.keyHash, uint8(0));

        (t.success, t.result) =
            address(ep).call(abi.encodeWithSignature("simulateExecute2(bytes)", abi.encode(u)));

        assertFalse(t.success);
        assertEq(bytes4(LibBytes.load(t.result, 0x00)), EntryPoint.SimulationResult2.selector);

        t.gExecute = uint256(LibBytes.load(t.result, 0x04));
        t.gCombined = uint256(LibBytes.load(t.result, 0x24));
        t.gUsed = uint256(LibBytes.load(t.result, 0x44));
        emit LogUint("gExecute", t.gExecute);
        emit LogUint("gCombined", t.gCombined);
        emit LogUint("gUsed", t.gUsed);
        assertEq(bytes4(LibBytes.load(t.result, 0x64)), 0);

        u.combinedGas = t.gCombined;
        u.signature = _sig(k, u);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testExecuteWithSecp256r1PassKey() public {
        _testExecuteWithPassKey(_randomSecp256r1PassKey());
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
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", abi.encode(u)));
        gUsed = uint256(LibBytes.load(rD, 0x04));
        err = bytes4(LibBytes.load(rD, 0x24));
    }
}
