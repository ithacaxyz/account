// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockGasBurner} from "./utils/mocks/MockGasBurner.sol";
import {IMulticall3} from "../src/interfaces/IMulticall3.sol";

contract SimulateExecuteTest is BaseTest {
    MockGasBurner gasBurner;
    MockMulticall3 multicall3;

    function setUp() public virtual override {
        super.setUp();
        gasBurner = new MockGasBurner();
        multicall3 = new MockMulticall3();
    }

    struct _SimulateExecuteTemps {
        uint256 gasToBurn;
        uint256 randomness;
        uint256 gExecute;
        uint256 gCombined;
        uint256 gUsed;
        uint256 gMulticall3;
        bytes executionData;
        bool success;
        bytes result;
        IMulticall3.Call3[] preCalls;
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
        i.paymentAmount = 0x112233112233112233112233;
        i.paymentMaxAmount = 0x445566445566445566445566;
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
            simulator.simulateV1Logs(address(oc), 0, 1, 11_000, 10_000, abi.encode(i));

        vm.expectRevert(bytes4(keccak256("StateOverrideError()")));
        oc.simulateExecute(true, type(uint256).max, abi.encode(i));

        vm.expectPartialRevert(bytes4(keccak256("SimulationPassed(uint256)")));
        oc.simulateExecute(false, type(uint256).max, abi.encode(i));

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), 2, 1e11, 11_000, 0, abi.encode(i));

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
        i.paymentAmount = 0x112233112233112233112233;
        i.paymentMaxAmount = 0x445566445566445566445566;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        vm.expectRevert(bytes4(keccak256("PaymentError()")));
        simulator.simulateV1Logs(address(oc), 0, 1, 11_000, 0, abi.encode(i));

        deal(i.paymentToken, address(i.eoa), 0x112233112233112233112233);
        vm.expectRevert(bytes4(keccak256("PaymentError()")));
        simulator.simulateCombinedGas(address(oc), 0, 1, 11_000, abi.encode(i));
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
        i.paymentAmount = 0x112233112233112233112233;
        i.paymentMaxAmount = 0x445566445566445566445566;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), 2, 1e11, 11_000, 0, abi.encode(i));

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
        i.paymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        i.paymentMaxAmount = _bound(_random(), i.paymentAmount, 0.5 ether);
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), 2, 1e11, 10_800, 0, abi.encode(i));

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
        i.paymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        i.paymentMaxAmount = _bound(_random(), i.paymentAmount, 0.5 ether);
        i.combinedGas = 20_000;

        // Just fill with some non-zero junk P256 signature that contains the `keyHash`,
        // so that the `simulateExecute` knows that
        // it needs to add the variance for non-precompile P256 verification.
        // We need the `keyHash` in the signature so that the simulation is able
        // to hit all the gas for the GuardedExecutor stuff for the `keyHash`.
        i.signature =
            abi.encodePacked(keccak256("a"), keccak256("b"), k.keyHash, uint8(0), uint8(0));

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gCombined) =
            simulator.simulateV1Logs(address(oc), 2, 1e11, 12_000, 10_000, abi.encode(i));

        vm.revertToStateAndDelete(snapshot);

        i.combinedGas = t.gCombined;
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        i.signature = _sig(k, i);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateMulticall3V1Logs() public {
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

        // Create some preCalls
        t.preCalls = new IMulticall3.Call3[](2);
        t.preCalls[0] = IMulticall3.Call3({
            target: address(gasBurner),
            allowFailure: false,
            callData: abi.encodeWithSignature("setRandomness(uint256)", 42)
        });
        t.preCalls[1] = IMulticall3.Call3({
            target: address(paymentToken),
            allowFailure: false,
            callData: abi.encodeWithSignature("approve(address,uint256)", address(this), 1000)
        });

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.paymentAmount = 0x112233112233112233112233;
        i.paymentMaxAmount = 0x445566445566445566445566;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        // If the caller does not have max balance, then the simulation should revert.
        vm.expectRevert(bytes4(keccak256("StateOverrideError()")));
        (t.gUsed, t.gMulticall3, t.gCombined) = simulator.simulateMulticall3V1Logs(
            address(multicall3), t.preCalls, address(oc), 0, 1, 11_000, 10_000, abi.encode(i)
        );

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gMulticall3, t.gCombined) = simulator.simulateMulticall3V1Logs(
            address(multicall3), t.preCalls, address(oc), 2, 1e11, 11_000, 0, abi.encode(i)
        );

        vm.revertToStateAndDelete(snapshot);
        i.combinedGas = t.gCombined;

        t.gExecute = t.gCombined + 10_000;

        i.signature = _sig(d, i);

        vm.expectRevert(bytes4(keccak256("InsufficientGas()")));
        oc.execute{gas: t.gExecute}(abi.encode(i));

        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
    }

    function testSimulateMulticall3NoRevertUnderfundedReverts() public {
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

        // Empty preCalls for this test
        t.preCalls = new IMulticall3.Call3[](0);

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.paymentAmount = 0x112233112233112233112233;
        i.paymentMaxAmount = 0x445566445566445566445566;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        vm.expectRevert(bytes4(keccak256("PaymentError()")));
        simulator.simulateMulticall3V1Logs(
            address(multicall3), t.preCalls, address(oc), 0, 1, 11_000, 0, abi.encode(i)
        );

        deal(i.paymentToken, address(i.eoa), 0x112233112233112233112233);
        vm.expectRevert(bytes4(keccak256("PaymentError()")));
        simulator.simulateMulticall3CombinedGas(
            address(multicall3), t.preCalls, address(oc), 0, 1, 11_000, abi.encode(i)
        );
    }

    function testSimulateMulticall3WithEOAKey(bytes32) public {
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

        // Create a single preCall
        t.preCalls = new IMulticall3.Call3[](1);
        t.preCalls[0] = IMulticall3.Call3({
            target: address(gasBurner),
            allowFailure: false,
            callData: abi.encodeWithSignature("setRandomness(uint256)", 1)
        });

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.paymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        i.paymentMaxAmount = _bound(_random(), i.paymentAmount, 0.5 ether);
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gMulticall3, t.gCombined) = simulator.simulateMulticall3V1Logs(
            address(multicall3), t.preCalls, address(oc), 2, 1e11, 10_800, 0, abi.encode(i)
        );

        vm.revertToStateAndDelete(snapshot);

        i.combinedGas = t.gCombined;
        // gExecute > (100k + combinedGas) * 64/63
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        i.signature = _sig(d, i);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateMulticall3WithPassKey(bytes32) public {
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

        // Create preCalls with token approval
        t.preCalls = new IMulticall3.Call3[](1);
        t.preCalls[0] = IMulticall3.Call3({
            target: address(paymentToken),
            allowFailure: false,
            callData: abi.encodeWithSignature(
                "approve(address,uint256)", address(oc), type(uint256).max
            )
        });

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.paymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        i.paymentMaxAmount = _bound(_random(), i.paymentAmount, 0.5 ether);
        i.combinedGas = 20_000;

        // Just fill with some non-zero junk P256 signature that contains the `keyHash`,
        // so that the `simulateExecute` knows that
        // it needs to add the variance for non-precompile P256 verification.
        // We need the `keyHash` in the signature so that the simulation is able
        // to hit all the gas for the GuardedExecutor stuff for the `keyHash`.
        i.signature = abi.encodePacked(keccak256("a"), keccak256("b"), k.keyHash, uint8(0));

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gMulticall3, t.gCombined) = simulator.simulateMulticall3V1Logs(
            address(multicall3), t.preCalls, address(oc), 2, 1e11, 12_000, 10_000, abi.encode(i)
        );

        vm.revertToStateAndDelete(snapshot);

        i.combinedGas = t.gCombined;
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        i.signature = _sig(k, i);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateMulticall3EmptyPreCalls() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, type(uint128).max);

        _SimulateExecuteTemps memory t;

        gasBurner.setRandomness(1); // Warm the storage first.

        t.gasToBurn = _gasToBurn();
        do {
            t.randomness = _randomUniform();
        } while (t.randomness == 0);

        t.executionData = _executionData(
            address(gasBurner),
            abi.encodeWithSignature("burnGas(uint256,uint256)", t.gasToBurn, t.randomness)
        );

        // Empty preCalls - should behave similarly to regular simulate
        t.preCalls = new IMulticall3.Call3[](0);

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.paymentAmount = 0x112233112233112233112233;
        i.paymentMaxAmount = 0x445566445566445566445566;
        i.combinedGas = 100_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gMulticall3, t.gCombined) = simulator.simulateMulticall3V1Logs(
            address(multicall3), t.preCalls, address(oc), 2, 1e11, 11_000, 0, abi.encode(i)
        );

        vm.revertToStateAndDelete(snapshot);

        i.combinedGas = t.gCombined;
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        i.signature = _sig(d, i);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateMulticall3MultiplePreCalls() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        paymentToken.mint(d.eoa, type(uint128).max);

        _SimulateExecuteTemps memory t;

        gasBurner.setRandomness(1); // Warm the storage first.

        t.gasToBurn = _gasToBurn();
        do {
            t.randomness = _randomUniform();
        } while (t.randomness == 0);

        t.executionData = _executionData(
            address(gasBurner),
            abi.encodeWithSignature("burnGas(uint256,uint256)", t.gasToBurn, t.randomness)
        );

        // Multiple preCalls with different operations
        t.preCalls = new IMulticall3.Call3[](3);
        t.preCalls[0] = IMulticall3.Call3({
            target: address(gasBurner),
            allowFailure: false,
            callData: abi.encodeWithSignature("setRandomness(uint256)", 100)
        });
        t.preCalls[1] = IMulticall3.Call3({
            target: address(paymentToken),
            allowFailure: false,
            callData: abi.encodeWithSignature("approve(address,uint256)", address(this), 5000)
        });
        t.preCalls[2] = IMulticall3.Call3({
            target: address(gasBurner),
            allowFailure: false,
            callData: abi.encodeWithSignature("setRandomness(uint256)", 1)
        });

        Orchestrator.Intent memory i;
        i.eoa = d.eoa;
        i.nonce = 0;
        i.executionData = t.executionData;
        i.payer = address(0x00);
        i.paymentToken = address(paymentToken);
        i.paymentRecipient = address(0x00);
        i.paymentAmount = 0.1 ether;
        i.paymentMaxAmount = 0.5 ether;
        i.combinedGas = 20_000;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        uint256 snapshot = vm.snapshotState();
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        (t.gUsed, t.gMulticall3, t.gCombined) = simulator.simulateMulticall3V1Logs(
            address(multicall3), t.preCalls, address(oc), 2, 1e11, 11_000, 0, abi.encode(i)
        );

        vm.revertToStateAndDelete(snapshot);

        i.combinedGas = t.gCombined;
        t.gExecute = Math.mulDiv(t.gCombined + 110_000, 64, 63);

        i.signature = _sig(d, i);

        assertEq(oc.execute{gas: t.gExecute}(abi.encode(i)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }

    function testSimulateVsActualGas() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        paymentToken.mint(d.eoa, type(uint128).max);

        _SimulateExecuteTemps memory t;

        gasBurner.setRandomness(1);

        t.gasToBurn = _gasToBurn();
        do {
            t.randomness = _randomUniform();
        } while (t.randomness == 0);

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
        i.paymentAmount = 0.1 ether;
        i.paymentMaxAmount = 0.5 ether;
        i.combinedGas = 20_000;

        {
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            i.signature = abi.encodePacked(r, s, v);
        }

        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        // Get simulated gas using multicall3 with empty preCalls (simulation automatically reverts, no state changes persist)
        t.preCalls = new IMulticall3.Call3[](0);
        (uint256 simulatedGas, uint256 multicall3Gas, uint256 combinedGas) = simulator.simulateMulticall3CombinedGas(
            address(multicall3), t.preCalls, address(oc), 2, 1e11, 11_000, abi.encode(i)
        );

        // Now execute through multicall3 with the calculated combinedGas and measure actual gas
        i.combinedGas = combinedGas;
        i.signature = _sig(d, i);
        t.gExecute = Math.mulDiv(combinedGas + 110_000, 64, 63);

        // Build multicall3 calls array: empty preCalls + orchestrator execute call
        IMulticall3.Call3[] memory executeCalls = new IMulticall3.Call3[](1);
        executeCalls[0] = IMulticall3.Call3({
            target: address(oc),
            allowFailure: false,
            callData: abi.encodeWithSignature("execute(bytes)", abi.encode(i))
        });

        IMulticall3.Result[] memory results = multicall3.aggregate3{gas: t.gExecute}(executeCalls);

        // Check that the orchestrator call succeeded and returned 0 (no error)
        if (results.length > 0 && results[0].success) {
            bytes4 err = abi.decode(results[0].returnData, (bytes4));
            assertEq(err, 0, "Execution should succeed");
        } else {
            revert("Multicall3 execution failed");
        }

        assertEq(gasBurner.randomness(), t.randomness);
    }
}

// Mock Multicall3 implementation for testing
contract MockMulticall3 is IMulticall3 {
    function aggregate(Call[] calldata calls)
        external
        payable
        override
        returns (uint256 blockNumber, bytes[] memory returnData)
    {
        blockNumber = block.number;
        returnData = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            if (!success) revert("Multicall3: call failed");
            returnData[i] = ret;
        }
    }

    function aggregate3(Call3[] calldata calls)
        external
        payable
        override
        returns (Result[] memory returnData)
    {
        returnData = new Result[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            returnData[i] = Result({success: success, returnData: ret});
            if (!calls[i].allowFailure && !success) {
                revert("Multicall3: call failed");
            }
        }
    }
}
