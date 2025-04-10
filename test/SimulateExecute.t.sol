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
        u.paymentAmount = 0x112233112233112233112233;
        u.paymentMaxAmount = 0x445566445566445566445566;
        u.paymentPerGas = 1;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            u.signature = abi.encodePacked(r, s, v);
        }

        address maxBalanceCaller = _randomUniqueHashedAddress();
        vm.deal(maxBalanceCaller, type(uint256).max);
        vm.prank(maxBalanceCaller);
        (t.success, t.result) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", abi.encode(u)));

        assertFalse(t.success);

        assertEq(t.result, abi.encodePacked(bytes4(keccak256("PaymentError()"))));
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

        UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = t.executionData;
        u.payer = address(0x00);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = 0x112233112233112233112233;
        u.paymentMaxAmount = 0x445566445566445566445566;
        u.paymentPerGas = 1;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            u.signature = abi.encodePacked(r, s, v);
        }

        address maxBalanceCaller = _randomUniqueHashedAddress();
        vm.deal(maxBalanceCaller, type(uint256).max);
        vm.prank(maxBalanceCaller);
        (t.success, t.result) =
            address(ep).call(abi.encodeWithSignature("simulateExecute(bytes)", abi.encode(u)));

        assertTrue(t.success);

        t.gExecute = uint256(LibBytes.load(t.result, 0x00));
        t.gCombined = uint256(LibBytes.load(t.result, 0x20));
        t.gUsed = uint256(LibBytes.load(t.result, 0x40));
        emit LogUint("gExecute", t.gExecute);
        emit LogUint("gCombined", t.gCombined);
        emit LogUint("gUsed", t.gUsed);
        assertEq(bytes4(LibBytes.load(t.result, 0x60)), 0);

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

        UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = t.executionData;
        u.payer = address(0x00);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        u.paymentMaxAmount = _bound(_random(), u.paymentAmount, 0.5 ether);
        u.paymentPerGas = 1e9;

        {
            // Just pass in a junk secp256k1 signature.
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(uint128(_randomUniform()), bytes32(_randomUniform()));
            u.signature = abi.encodePacked(r, s, v);
        }

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

        UserOp memory u;
        u.eoa = d.eoa;
        u.nonce = 0;
        u.executionData = t.executionData;
        u.payer = address(0x00);
        u.paymentToken = address(paymentToken);
        u.paymentRecipient = address(0x00);
        u.paymentAmount = _randomChance(2) ? 0 : 0.1 ether;
        u.paymentMaxAmount = _bound(_random(), u.paymentAmount, 0.5 ether);
        u.paymentPerGas = 1e9;

        // Just fill with some non-zero junk P256 signature that contains the `keyHash`,
        // so that the `simulateExecute` knows that
        // it needs to add the variance for non-precompile P256 verification.
        // We need the `keyHash` in the signature so that the simulation is able
        // to hit all the gas for the GuardedExecutor stuff for the `keyHash`.
        u.signature = abi.encodePacked(keccak256("a"), keccak256("b"), k.keyHash, uint8(0));

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
        u.signature = _sig(k, u);

        assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
        assertEq(gasBurner.randomness(), t.randomness);
    }
}
