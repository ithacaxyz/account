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

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.prePaymentAmount = 0x112233112233112233112233;
        i.prePaymentMaxAmount = 0x445566445566445566445566;
        i.totalPaymentAmount = i.prePaymentAmount;
        i.totalPaymentMaxAmount = i.prePaymentMaxAmount;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        // If the caller does not have max balance, then the simulation should revert.
        vm.expectRevert(bytes4(keccak256("StateOverrideError()")));
        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), false, 0, 1, 11_000, 10_000, abi.encode(i));

        vm.expectRevert(bytes4(keccak256("StateOverrideError()")));
        oc.simulateExecute(true, type(uint256).max, abi.encode(i));

        vm.expectPartialRevert(bytes4(keccak256("SimulationPassed(uint256)")));
        oc.simulateExecute(false, type(uint256).max, abi.encode(i));

        uint256 snapshot = vm.snapshotState();
        vm.deal(address(simulator), type(uint256).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), false, 2, 1e11, 11_000, 0, abi.encode(i));

        vm.revertToStateAndDelete(snapshot);
        i.combinedGas = t.gCombined;

        t.gExecute = t.gCombined + 10_000;

        i.signature = _sig(d, i);

        vm.expectRevert(bytes4(keccak256("InsufficientGas()")));
        oc.execute{gas: t.gExecute}(abi.encode(i));

        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
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

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.prePaymentAmount = 0x112233112233112233112233;
        i.prePaymentMaxAmount = 0x445566445566445566445566;
        i.totalPaymentAmount = i.prePaymentAmount;
        i.totalPaymentMaxAmount = i.prePaymentMaxAmount;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        vm.expectRevert(bytes4(keccak256("PaymentError()")));
        simulator.simulateV1Logs(address(oc), false, 0, 1, 11_000, 0, abi.encode(i));

        deal(i.paymentToken, address(i.eoa), 0x112233112233112233112233);
        vm.expectRevert(bytes4(keccak256("PaymentError()")));
        simulator.simulateCombinedGas(address(oc), true, 0, 1, 11_000, abi.encode(i));
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

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.prePaymentAmount = 0x112233112233112233112233;
        i.prePaymentMaxAmount = 0x445566445566445566445566;
        i.totalPaymentAmount = i.prePaymentAmount;
        i.totalPaymentMaxAmount = i.prePaymentMaxAmount;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(address(simulator), type(uint256).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), false, 2, 1e11, 11_000, 0, abi.encode(i));

        vm.revertToStateAndDelete(snapshot);

        i.combinedGas = t.gCombined;
        // gExecute > (100k + combinedGas) * 64/63
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        i.signature = _sig(d, i);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
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

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.prePaymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        i.prePaymentMaxAmount = _bound(_random(), i.prePaymentAmount, 0.5 ether);
        i.totalPaymentAmount = i.prePaymentAmount;
        i.totalPaymentMaxAmount = i.prePaymentMaxAmount;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(address(simulator), type(uint256).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), false, 2, 1e11, 10_800, 0, abi.encode(i));

        vm.revertToStateAndDelete(snapshot);

        i.combinedGas = t.gCombined;
        // gExecute > (100k + combinedGas) * 64/63
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        i.signature = _sig(d, i);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
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

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.prePaymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        i.prePaymentMaxAmount = _bound(_random(), i.prePaymentAmount, 0.5 ether);
        i.totalPaymentAmount = i.prePaymentAmount;
        i.totalPaymentMaxAmount = i.prePaymentMaxAmount;
        i.combinedGas = 20_000;

        // Just fill with some non-zero junk P256 signature that contains the `keyHash`,
        // so that the `simulateExecute` knows that
        // it needs to add the variance for non-precompile P256 verification.
        // We need the `keyHash` in the signature so that the simulation is able
        // to hit all the gas for the GuardedExecutor stuff for the `keyHash`.
        i.signature = abi.encodePacked(keccak256("a"), keccak256("b"), k.keyHash, uint8(0));

        uint256 snapshot = vm.snapshotState();
        vm.deal(address(simulator), type(uint256).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), false, 2, 1e11, 12_000, 10_000, abi.encode(i));

        vm.revertToStateAndDelete(snapshot);

        i.combinedGas = t.gCombined;
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        i.signature = _sig(k, i);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }
}
