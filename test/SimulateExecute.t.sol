// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockGasBurner} from "./utils/mocks/MockGasBurner.sol";

contract SimulateExecuteTest is BaseTest {
    MockGasBurner gasBurner;

    function setUp() public virtual override {
        super.setUp();
        gasBurner = new MockGasBurner();
    }

    struct _SimulateExecuteTemps {
        uint256 gasToBurn;
        uint256 randomness;
        uint256 gExecute;
        uint256 gCombined;
        uint256 gUsed;
        bytes executionData;
        bool success;
        bytes result;
    }

    function _gasToBurn() internal returns (uint256) {
        uint256 r = _randomUniform();
        if (r & 0x003f000 == 0) return _bound(_random(), 0, 15000000);
        if (r & 0x0000f00 == 0) return _bound(_random(), 0, 1000000);
        if (r & 0x0000070 == 0) return _bound(_random(), 0, 100000);
        return _bound(_random(), 0, 10000);
    }

    function testSimulateV1Logs() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        assertEq(_balanceOf(address(paymentToken), d.eoa), 0);

        paymentToken.mint(d.eoa, type(uint128).max);

        _SimulateExecuteTemps memory t;

        gasBurner.setRandomness(1); // Warm the storage first.

        t.gasToBurn = _gasToBurn();
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
        u.prePaymentAmount = 0x112233112233112233112233;
        u.prePaymentMaxAmount = 0x445566445566445566445566;
        u.totalPaymentAmount = u.prePaymentAmount;
        u.totalPaymentMaxAmount = u.prePaymentMaxAmount;
        u.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            u.signature = abi.encodePacked(r, s, v);
        }

        // If the caller does not have max balance, then the simulation should revert.
        vm.expectRevert(bytes4(keccak256("StateOverrideError()")));
        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(ep), false, 1, 11_000, 10_000, abi.encode(u));

        vm.expectRevert(bytes4(keccak256("StateOverrideError()")));
        ep.simulateExecute(true, type(uint256).max, abi.encode(u));

        vm.expectPartialRevert(bytes4(keccak256("SimulationPassed(uint256)")));
        ep.simulateExecute(false, type(uint256).max, abi.encode(u));

        uint256 snapshot = vm.snapshotState();
        vm.deal(address(simulator), type(uint256).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(ep), false, 1e9, 11_000, 0, abi.encode(u));

        vm.revertToStateAndDelete(snapshot);
        u.combinedGas = t.gCombined;

        t.gExecute = t.gCombined + 10_000;

        u.signature = _sig(d, u);

        vm.expectRevert(bytes4(keccak256("InsufficientGas()")));
        ep.execute{gas: t.gExecute}(abi.encode(u));

        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
    }

    function testSimulateExecuteNoRevertUnderfundedReverts() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        assertEq(_balanceOf(address(paymentToken), d.eoa), 0);

        _SimulateExecuteTemps memory t;

        gasBurner.setRandomness(1); // Warm the storage first.

        t.gasToBurn = _gasToBurn();
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
        u.prePaymentAmount = 0x112233112233112233112233;
        u.prePaymentMaxAmount = 0x445566445566445566445566;
        u.totalPaymentAmount = u.prePaymentAmount;
        u.totalPaymentMaxAmount = u.prePaymentMaxAmount;
        u.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            u.signature = abi.encodePacked(r, s, v);
        }

        vm.expectRevert(bytes4(keccak256("PaymentError()")));
        simulator.simulateV1Logs(address(ep), false, 1, 11_000, 0, abi.encode(u));

        deal(u.paymentToken, address(u.eoa), 0x112233112233112233112233);
        vm.expectRevert(bytes4(keccak256("PaymentError()")));
        simulator.simulateCombinedGas(address(ep), true, 1, 11_000, abi.encode(u));
    }

    function testSimulateExecuteNoRevert() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, type(uint128).max);

        _SimulateExecuteTemps memory t;

        gasBurner.setRandomness(1); // Warm the storage first.

        t.gasToBurn = _gasToBurn();
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
        u.prePaymentAmount = 0x112233112233112233112233;
        u.prePaymentMaxAmount = 0x445566445566445566445566;
        u.totalPaymentAmount = u.prePaymentAmount;
        u.totalPaymentMaxAmount = u.prePaymentMaxAmount;
        u.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            u.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(address(simulator), type(uint256).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(ep), false, 1e9, 11_000, 0, abi.encode(u));

        vm.revertToStateAndDelete(snapshot);

        u.combinedGas = t.gCombined;
        // gExecute > (100k + combinedGas) * 64/63
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        u.signature = _sig(d, u);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateExecuteWithEOAKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, 500 ether);

        _SimulateExecuteTemps memory t;

        gasBurner.setRandomness(1); // Warm the storage first.

        t.gasToBurn = _gasToBurn();
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
        u.prePaymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        u.prePaymentMaxAmount = _bound(_random(), u.prePaymentAmount, 0.5 ether);
        u.totalPaymentAmount = u.prePaymentAmount;
        u.totalPaymentMaxAmount = u.prePaymentMaxAmount;
        u.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            u.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(address(simulator), type(uint256).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(ep), false, 1e9, 10_800, 0, abi.encode(u));

        vm.revertToStateAndDelete(snapshot);

        u.combinedGas = t.gCombined;
        // gExecute > (100k + combinedGas) * 64/63
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        u.signature = _sig(d, u);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateExecuteWithPassKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        vm.deal(d.eoa, 10 ether);
        paymentToken.mint(d.eoa, 50 ether);

        PassKey memory k = _randomPassKey(); // Can be r1 or k1.
        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        _SimulateExecuteTemps memory t;

        t.gasToBurn = _gasToBurn();
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
        u.prePaymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        u.prePaymentMaxAmount = _bound(_random(), u.prePaymentAmount, 0.5 ether);
        u.totalPaymentAmount = u.prePaymentAmount;
        u.totalPaymentMaxAmount = u.prePaymentMaxAmount;
        u.combinedGas = 20_000;

        // Just fill with some non-zero junk P256 signature that contains the `keyHash`,
        // so that the `simulateExecute` knows that
        // it needs to add the variance for non-precompile P256 verification.
        // We need the `keyHash` in the signature so that the simulation is able
        // to hit all the gas for the GuardedExecutor stuff for the `keyHash`.
        u.signature = abi.encodePacked(keccak256("a"), keccak256("b"), k.keyHash, uint8(0));

        uint256 snapshot = vm.snapshotState();
        vm.deal(address(simulator), type(uint256).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(ep), false, 1e9, 12_000, 10_000, abi.encode(u));

        vm.revertToStateAndDelete(snapshot);

        u.combinedGas = t.gCombined;
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        u.signature = _sig(k, u);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }
}
