// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";

import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";

import {IOrchestrator} from "../src/interfaces/IOrchestrator.sol";
import {IIthacaAccount} from "../src/interfaces/IIthacaAccount.sol";
import {MultiSigSigner} from "../src/MultiSigSigner.sol";
import {ICommon} from "../src/interfaces/ICommon.sol";

import {Merkle} from "murky/Merkle.sol";

contract AccountTest is BaseTest {
    struct _TestExecuteWithSignatureTemps {
        TargetFunctionPayload[] targetFunctionPayloads;
        ERC7821.Call[] calls;
        uint256 n;
        uint256 nonce;
        bytes opData;
        bytes executionData;
    }

    function testExecuteWithSignature(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        _TestExecuteWithSignatureTemps memory t;
        t.n = _bound(_randomUniform(), 1, 5);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.n);
        t.calls = new ERC7821.Call[](t.n);
        for (uint256 i; i < t.n; ++i) {
            uint256 value = _random() % 0.1 ether;
            bytes memory data = _truncateBytes(_randomBytes(), 0xff);
            t.calls[i] = _thisTargetFunctionCall(value, data);
            t.targetFunctionPayloads[i].value = value;
            t.targetFunctionPayloads[i].data = data;
        }
        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        if (_randomChance(32)) {
            signature = _sig(_randomEIP7702DelegatedEOA(), d.d.computeDigest(t.calls, t.nonce));
            t.opData = abi.encodePacked(t.nonce, signature);
            t.executionData = abi.encode(t.calls, t.opData);
            vm.expectRevert(bytes4(keccak256("Unauthorized()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
            return;
        }

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);

        if (_randomChance(32)) {
            vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
        }

        if (_randomChance(32)) {
            t.nonce = d.d.getNonce(0);
            signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
            t.opData = abi.encodePacked(t.nonce, signature);
            t.executionData = abi.encode(t.calls, t.opData);
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
            return;
        }

        for (uint256 i; i < t.n; ++i) {
            assertEq(targetFunctionPayloads[i].by, d.eoa);
            assertEq(targetFunctionPayloads[i].value, t.targetFunctionPayloads[i].value);
            assertEq(targetFunctionPayloads[i].data, t.targetFunctionPayloads[i].data);
        }
    }

    function testSignatureCheckerApproval(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = _randomChance(32);

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        address[] memory checkers = new address[](_bound(_random(), 1, 3));
        for (uint256 i; i < checkers.length; ++i) {
            checkers[i] = _randomUniqueHashedAddress();
            vm.prank(d.eoa);
            d.d.setSignatureCheckerApproval(k.keyHash, checkers[i], true);
        }
        assertEq(d.d.approvedSignatureCheckers(k.keyHash).length, checkers.length);

        bytes32 digest = bytes32(_randomUniform());
        bytes memory sig = _sig(k, digest);

        // test that the signature fails without the replay safe wrapper
        assertTrue(d.d.isValidSignature(digest, sig) == 0xFFFFFFFF);

        bytes32 replaySafeDigest = keccak256(abi.encode(d.d.SIGN_TYPEHASH(), digest));

        (, string memory name, string memory version,, address verifyingContract,,) =
            d.d.eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                0x035aff83d86937d35b32e04f0ddc6ff469290eef2f1b692d8a815c89404d4749, // DOMAIN_TYPEHASH with only verifyingContract
                verifyingContract
            )
        );
        replaySafeDigest = keccak256(abi.encodePacked("\x19\x01", domain, replaySafeDigest));
        sig = _sig(k, replaySafeDigest);

        assertEq(
            d.d.isValidSignature(digest, sig) == IthacaAccount.isValidSignature.selector,
            k.k.isSuperAdmin
        );

        vm.prank(checkers[_randomUniform() % checkers.length]);
        assertEq(d.d.isValidSignature(digest, sig), IthacaAccount.isValidSignature.selector);

        vm.prank(d.eoa);
        d.d.revoke(_hash(k.k));

        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        d.d.isValidSignature(digest, sig);

        if (k.k.isSuperAdmin) k.k.isSuperAdmin = _randomChance(2);
        vm.prank(d.eoa);
        d.d.authorize(k.k);

        assertEq(
            d.d.isValidSignature(digest, sig) == IthacaAccount.isValidSignature.selector,
            k.k.isSuperAdmin
        );
        assertEq(d.d.approvedSignatureCheckers(k.keyHash).length, 0);
    }

    struct _TestUpgradeAccountWithPassKeyTemps {
        uint256 randomVersion;
        address implementation;
        ERC7821.Call[] calls;
        uint256 nonce;
        bytes opData;
        bytes executionData;
    }

    function testUpgradeAccountWithPassKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        _TestUpgradeAccountWithPassKeyTemps memory t;
        t.randomVersion = _randomUniform();
        t.implementation = address(new MockSampleDelegateCallTarget(t.randomVersion));

        t.calls = new ERC7821.Call[](1);
        t.calls[0].data = abi.encodeWithSignature("upgradeProxyAccount(address)", t.implementation);

        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);

        assertEq(MockSampleDelegateCallTarget(d.eoa).version(), t.randomVersion);
        assertEq(MockSampleDelegateCallTarget(d.eoa).upgradeHookCounter(), 1);
    }

    function testUpgradeAccountToZeroAddressReverts() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        _TestUpgradeAccountWithPassKeyTemps memory t;
        t.calls = new ERC7821.Call[](1);
        t.calls[0].data = abi.encodeWithSignature("upgradeProxyAccount(address)", address(0));

        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        vm.expectRevert(IthacaAccount.NewImplementationIsZero.selector);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
    }

    function testApproveAndRevokeKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        IthacaAccount.Key memory k;
        IthacaAccount.Key memory kRetrieved;

        k.keyType = IthacaAccount.KeyType(_randomUniform() & 1);
        k.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));
        k.publicKey = _truncateBytes(_randomBytes(), 0x1ff);

        assertEq(d.d.keyCount(), 0);

        vm.prank(d.eoa);
        d.d.authorize(k);

        assertEq(d.d.keyCount(), 1);

        kRetrieved = d.d.keyAt(0);
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        k.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));

        vm.prank(d.eoa);
        d.d.authorize(k);

        assertEq(d.d.keyCount(), 1);

        kRetrieved = d.d.keyAt(0);
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        kRetrieved = d.d.getKey(_hash(k));
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        vm.prank(d.eoa);
        d.d.revoke(_hash(k));

        assertEq(d.d.keyCount(), 0);

        vm.expectRevert(bytes4(keccak256("IndexOutOfBounds()")));
        d.d.keyAt(0);

        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        kRetrieved = d.d.getKey(_hash(k));
    }

    function testManyKeys() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        IthacaAccount.Key memory k;
        k.keyType = IthacaAccount.KeyType(_randomUniform() & 1);

        for (uint40 i = 0; i < 20; i++) {
            k.expiry = i;
            k.publicKey = abi.encode(i);
            vm.prank(d.eoa);
            d.d.authorize(k);
        }

        vm.warp(5);

        (IthacaAccount.Key[] memory keys, bytes32[] memory keyHashes) = d.d.getKeys();

        assert(keys.length == keyHashes.length);
        assert(keys.length == 16);

        assert(keys[0].expiry == 0);
        assert(keys[1].expiry == 5);
    }

    function testCrossChainKeyPreCallsAuthorization() public {
        // Setup Keys
        PassKey memory adminKey = _randomSecp256k1PassKey();
        adminKey.k.isSuperAdmin = true;

        PassKey memory newKey = _randomPassKey();
        newKey.k.isSuperAdmin = false;

        // Setup ephemeral EOA (simulates EIP-7702 delegation)
        uint256 ephemeralPK = _randomPrivateKey();
        address payable eoaAddress = payable(vm.addr(ephemeralPK));
        address impl = accountImplementation;

        paymentToken.mint(eoaAddress, 2 ** 128 - 1);

        // === PREPARE CROSS-CHAIN PRE-CALLS ===
        // These pre-calls will be used on multiple chains with multichain nonces

        // Pre-call 1: Initialize admin key using ephemeral EOA signature
        Orchestrator.SignedCall memory pInit;
        {
            ERC7821.Call[] memory initCalls = new ERC7821.Call[](1);
            initCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, adminKey.k);

            pInit.eoa = eoaAddress;
            pInit.executionData = abi.encode(initCalls);
            pInit.nonce = (0xc1d0 << 240) | (1 << 64); // Multichain nonce
            pInit.signature = _eoaSig(ephemeralPK, oc.computeDigest(pInit));
        }

        // Pre-call 2: Authorize new key using admin key
        Orchestrator.SignedCall memory pAuth;
        {
            ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
            authCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, newKey.k);

            pAuth.eoa = eoaAddress;
            pAuth.executionData = abi.encode(authCalls);
            pAuth.nonce = (0xc1d0 << 240) | (2 << 64); // Multichain nonce
            pAuth.signature = _sig(adminKey, oc.computeDigest(pAuth));
        }

        // Prepare main Intent structure (will be reused with same pre-calls)
        Orchestrator.Intent memory baseIntent;
        baseIntent.eoa = eoaAddress;
        baseIntent.paymentToken = address(paymentToken);
        baseIntent.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
        baseIntent.paymentMaxAmount = baseIntent.paymentAmount;
        baseIntent.combinedGas = 10000000;

        // Encode the pre-calls once (to be reused on both chains)
        baseIntent.encodedPreCalls = new bytes[](2);
        baseIntent.encodedPreCalls[0] = abi.encode(pInit);
        baseIntent.encodedPreCalls[1] = abi.encode(pAuth);

        // Main execution (empty for this test)
        ERC7821.Call[] memory calls = new ERC7821.Call[](0);
        baseIntent.executionData = abi.encode(calls);

        // Take a snapshot before any chain-specific operations
        uint256 initialSnapshot = vm.snapshot();

        // === Chain 1 Execution ===
        vm.chainId(1);
        vm.etch(eoaAddress, abi.encodePacked(hex"ef0100", impl));

        // Use the prepared pre-calls on chain 1
        Orchestrator.Intent memory u1 = baseIntent;
        u1.nonce = (0xc1d0 << 240) | 0; // Multichain nonce for main intent
        u1.signature = _sig(adminKey, u1);

        // Execute on chain 1 - should succeed
        assertEq(oc.execute(abi.encode(u1)), 0, "Execution should succeed on chain 1");

        // Verify keys were added on chain 1
        uint256 keysCount1 = IthacaAccount(eoaAddress).keyCount();
        assertEq(keysCount1, 2, "Both keys should be added on chain 1");

        // === Reset State and Switch to Chain 137 ===
        vm.revertTo(initialSnapshot);
        vm.clearMockedCalls();
        paymentToken.mint(eoaAddress, 2 ** 128 - 1);

        // === Chain 137 Execution ===
        vm.chainId(137);
        vm.etch(eoaAddress, abi.encodePacked(hex"ef0100", impl));

        // Execution should succeed due to multichain nonce in pre-calls
        assertEq(oc.execute(abi.encode(baseIntent)), 0, "Should succeed due to multichain nonce");

        // Verify keys were added on chain 137
        uint256 keysCount137 = IthacaAccount(eoaAddress).keyCount();
        assertEq(keysCount137, 2, "Keys should be added on chain 137");
    }

    /**
     *
     *     Calldata layout (32-byte words; left column = byte offset from start)
     *
     *     bytes
     *     pos  0x
     *     0:   0000000000000000000000000000000000000000000000000000000000000b20 - bytes length prefix (=2848)
     *     32:  0000000000000000000000000000000000000000000000000000000000000020 - Intent start offset
     *     64:  0000000000000000000000005c6bd1597b1411cce0e79a0841fd11073120493b - eoa
     *     96:  0000000000000000000000000000000000000000000000000000000000000280 - executionData offset
     *     128: c1d0000000000000000000000000000000000000000000000000000000000000 - nonce
     *     160: 0000000000000000000000000000000000000000000000000000000000000000 - payer
     *     192: 0000000000000000000000002e234dae75c793f67a35089c9d99245e1c58470b - paymentToken
     *     224: 000000000000000000000000000000000000000000000000000000008e95aab8 - paymentMaxAmount
     *     256: 0000000000000000000000000000000000000000000000000000000000989680 - combinedGas
     *     288: 00000000000000000000000000000000000000000000000000000000000002e0 - encodedPreCalls offset
     *     320: 00000000000000000000000000000000000000000000000000000000000009e0 - encodedFundTransfers offset
     *     352: 0000000000000000000000000000000000000000000000000000000000000000 - settler
     *     384: 0000000000000000000000000000000000000000000000000000000000000000 - expiry
     *     416: 0000000000000000000000000000000000000000000000000000000000000000 - isMultichain
     *     448: 0000000000000000000000000000000000000000000000000000000000000000 - funder
     *     480: 0000000000000000000000000000000000000000000000000000000000000a00 - funderSignature offset
     *     512: 0000000000000000000000000000000000000000000000000000000000000a20 - settlerContext offset
     *     544: 000000000000000000000000000000000000000000000000000000008e95aab8 - paymentAmount
     *     576: 0000000000000000000000000000000000000000000000000000000000000000 - paymentReceipt
     *     608: 0000000000000000000000000000000000000000000000000000000000000a40 - signature offset
     *     640: 0000000000000000000000000000000000000000000000000000000000000ae0 - paymentSignature offset
     *     672: 0000000000000000000000000000000000000000000000000000000000000000 - supportedAccountImplementation
     *
     */

    //////// Corrupting the 13 static fields of Intent ////////

    // Test 1: eoa corruption
    function testPayWithAllCorruptedEOAFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 64), 0x10000000000000000) // 2^64 (strictly greater than 2^64-1)
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("PaymentError()")));
    }

    // Test 2: nonce corruption
    function testPayWithAllCorruptedNonceFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 128), 0x10000000000000001) // 2^64 + 1
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerificationError()")));
    }

    // Test 3: payer corruption
    function testPayWithAllCorruptedPayerFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 160), 0x10000000000000002) // 2^64 + 2
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("PaymentError()")));
    }

    // Test 4: paymentToken corruption
    function testPayWithAllCorruptedPaymentTokenFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 192), 0x10000000000000003) // 2^64 + 3
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("PaymentError()")));
    }

    // Test 5: paymentMaxAmount corruption
    function testPayWithAllCorruptedPaymentMaxAmountFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 224), 0x10000000000000004) // 2^64 + 4
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerificationError()")));
    }

    // Test 6: combinedGas corruption
    function testPayWithAllCorruptedCombinedGasFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 256), 0x00) // 0 gas limit
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));
    }

    // Test 7: settler corruption
    function testPayWithAllCorruptedSettlerFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 352), 0x10000000000000005) // 2^64 + 5
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerificationError()")));
    }

    // Test 8: expiry corruption
    function testPayWithAllCorruptedExpiryFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 384), 0x10000000000000006) // 2^64 + 6
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerificationError()")));
    }

    // Test 9: isMultichain corruption
    function testPayWithAllCorruptedIsMultichainFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 416), 0x01) // true flag with non-multichain intent
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));
    }

    // Test 10: funder corruption
    function testPayWithAllCorruptedFunderFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            // corupting with garbage address as returns 0x00000000 with 0x10000000000000008 (2^64 + 8)
            mstore(
                add(maliciousCalldata, 448),
                0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
            )
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));
    }

    // Test 11: paymentAmount corruption
    function testPayWithAllCorruptedPaymentAmountFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            let paymentMaxAmount := mload(add(maliciousCalldata, 224))
            // corrupt paymentAmount with paymentMaxAmount + 1
            mstore(add(maliciousCalldata, 544), add(paymentMaxAmount, 1))
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("PaymentError()")));
    }

    // Test 12: paymentReceipt corruption
    function testPayWithAllCorruptedPaymentReceiptFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        // corrupt paymentReceipt with garbage address as returns 0x00000000 with 0x10000000000000009 (2^64 + 9)
        assembly {
            mstore(
                add(maliciousCalldata, 576),
                0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
            )
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));
    }

    // Test 13: supportedAccountImplementation corruption
    function testPayWithAllCorruptedSupportedAccountImplementationFieldOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 672), 0x10000000000000009) // 2^64 + 9
        }
        assertEq(
            oc.execute(maliciousCalldata), bytes4(keccak256("UnsupportedAccountImplementation()"))
        );
    }

    //////// Corrupting the main offset and 7 dynamic field offsets of Intent ////////

    // Test 1: Main Intent struct offset corruption
    function testPayWithCorruptedMainIntentStructOffsetOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            // 0x10000000000000000 = 2^64 (strictly greater than 2^64-1, which is the max value
            // checked against, by the compiler in abi.decode())
            mstore(add(maliciousCalldata, 32), 0x10000000000000000)
        }
        (bool success, bytes memory returnData) =
            address(oc).call(abi.encodeWithSignature("execute(bytes)", maliciousCalldata));
        assertEq(success, false);
    }

    // Test 2: executionData offset corruption
    function testPayWithCorruptedExecutionDataOffsetOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            // note: this reverts with decoding error on corrupting with a random offset part of Intent
            mstore(add(maliciousCalldata, 96), 0x300)
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("DecodingError()")));
    }

    // Test 3: encodedPreCalls offset corruption
    function testPayWithCorruptedEncodedPreCallsOffsetOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            // note: this evm reverts with a value well within bounds of 2^64 - 1 too
            mstore(add(maliciousCalldata, 288), 0x300)
        }
        (bool success, bytes memory returnData) =
            address(oc).call(abi.encodeWithSignature("execute(bytes)", maliciousCalldata));
        assertEq(success, false);
    }

    // Test 4: encodedFundTransfers offset corruption
    function testPayWithCorruptedEncodedFundTransfersOffsetOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            mstore(add(maliciousCalldata, 320), 0x10000000000000003) // 2^64 + 3
        }
        (bool success, bytes memory returnData) =
            address(oc).call(abi.encodeWithSignature("execute(bytes)", maliciousCalldata));
        assertEq(success, false);
    }

    // Test 5: funderSignature offset corruption
    function testPayWithCorruptedFunderSignatureOffsetOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            // note: corrupting with 0xa20 returns 0x00000000, which is equivalent to not being corrupted
            // so we corrupt with extreme value
            mstore(add(maliciousCalldata, 480), 0x10000000000000004) // 2^64 + 4
        }
        (bool success, bytes memory returnData) =
            address(oc).call(abi.encodeWithSignature("execute(bytes)", maliciousCalldata));
        assertEq(success, false);
    }

    // Test 6: signature offset corruption
    function testPayWithCorruptedSignatureOffsetOfIntent() public {
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            // note: this reverts with verification error on corrupting with a random offset part of Intent
            mstore(add(maliciousCalldata, 608), 0x300)
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerificationError()")));
    }

    // modified from testCrossChainKeyPreCallsAuthorization()'s intent creation
    function _createIntentOnMainnet() public returns (bytes memory) {
        // Setup Keys
        PassKey memory adminKey = _randomSecp256k1PassKey();
        adminKey.k.isSuperAdmin = true;

        PassKey memory newKey = _randomPassKey();
        newKey.k.isSuperAdmin = false;

        // Setup ephemeral EOA (simulates EIP-7702 delegation)
        uint256 ephemeralPK = _randomPrivateKey();
        address payable eoaAddress = payable(vm.addr(ephemeralPK));
        address impl = accountImplementation;

        paymentToken.mint(eoaAddress, 2 ** 128 - 1);

        // === PREPARE CROSS-CHAIN PRE-CALLS ===
        // These pre-calls will be used on multiple chains with multichain nonces

        // Pre-call 1: Initialize admin key using ephemeral EOA signature
        Orchestrator.SignedCall memory pInit;
        {
            ERC7821.Call[] memory initCalls = new ERC7821.Call[](1);
            initCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, adminKey.k);

            pInit.eoa = eoaAddress;
            pInit.executionData = abi.encode(initCalls);
            pInit.nonce = (0xc1d0 << 240) | (1 << 64); // Multichain nonce
            pInit.signature = _eoaSig(ephemeralPK, oc.computeDigest(pInit));
        }

        // Pre-call 2: Authorize new key using admin key
        Orchestrator.SignedCall memory pAuth;
        {
            ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
            authCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, newKey.k);

            pAuth.eoa = eoaAddress;
            pAuth.executionData = abi.encode(authCalls);
            pAuth.nonce = (0xc1d0 << 240) | (2 << 64); // Multichain nonce
            pAuth.signature = _sig(adminKey, oc.computeDigest(pAuth));
        }

        // Prepare main Intent structure (will be reused with same pre-calls)
        Orchestrator.Intent memory baseIntent;
        baseIntent.eoa = eoaAddress;
        baseIntent.paymentToken = address(paymentToken);
        baseIntent.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
        baseIntent.paymentMaxAmount = baseIntent.paymentAmount;
        baseIntent.combinedGas = 10000000;

        // Encode the pre-calls once (to be reused on both chains)
        baseIntent.encodedPreCalls = new bytes[](2);
        baseIntent.encodedPreCalls[0] = abi.encode(pInit);
        baseIntent.encodedPreCalls[1] = abi.encode(pAuth);

        // Main execution (empty for this test)
        ERC7821.Call[] memory calls = new ERC7821.Call[](0);
        baseIntent.executionData = abi.encode(calls);

        // Take a snapshot before any chain-specific operations
        uint256 initialSnapshot = vm.snapshot();

        // === Chain 1 Execution ===
        vm.chainId(1);
        vm.etch(eoaAddress, abi.encodePacked(hex"ef0100", impl));

        // Use the prepared pre-calls on chain 1
        Orchestrator.Intent memory u1 = baseIntent;
        u1.nonce = (0xc1d0 << 240) | 0; // Multichain nonce for main intent
        u1.signature = _sig(adminKey, u1);

        return abi.encode(u1);
    }

    // Test 7: paymentSignature offset corruption
    // modified from Orchestrator.t.sol's testAccountPaymaster()
    function testPayWithCorruptedPaymentSignatureOffsetOfIntent() public {
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

        bytes memory maliciousCalldata = abi.encode(u);
        assembly {
            mstore(add(maliciousCalldata, 640), 0x10000000000000006) // 2^64 + 6
        }
        (bool success, bytes memory returnData) =
            address(oc).call(abi.encodeWithSignature("execute(bytes)", maliciousCalldata));
        assertEq(success, false);
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

    // Test 8: settlerContext offset corruption
    // modified from Orchestrator.t.sol's testMultiChainIntent()
    function testPayWithCorruptedSettlerContextOffsetOfIntent() public {
        _TestMultiChainIntentTemps memory t;

        // Initialize core test data
        t.funderPrivateKey = _randomPrivateKey();
        t.settlementOracle = makeAddr("SETTLEMENT_ORACLE");
        t.funder = new SimpleFunder(vm.addr(t.funderPrivateKey), address(oc), address(this));
        t.settler = new SimpleSettler(t.settlementOracle);
        t.relay = makeAddr("RELAY");
        t.friend = makeAddr("FRIEND");

        // ------------------------------------------------------------------
        // SimpleFunder ‑ gas wallet set-up & basic functionality checks
        // ------------------------------------------------------------------
        // Setting up the gas wallet and hooking it to the SimpleFunder don't make a difference
        // to this test, so skipping it

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
        // Send 1000 USDC to a friend on Mainnet. By pulling funds from Base and Arb (which are skipped in this test).
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
                data: abi.encodeWithSignature("approve(address,uint256)", address(t.escrowBase), 600)
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

        // 3. Action on Base, 4. Action on Arbitrum are irrelevant for this test

        // 5. Action on Mainnet (Destination Chain)
        vm.chainId(1);
        // Relay has funds on mainnet for settlement. User has no funds.
        t.usdcMainnet.mint(t.relay, 1000);

        vm.prank(makeAddr("RANDOM_RELAY_ADDRESS"));
        t.usdcMainnet.mint(address(t.funder), 1000);

        // Relay funds the user account, and the intended execution happens.
        t.encodedIntents[0] = abi.encode(t.outputIntent);

        bytes memory maliciousCalldata = t.encodedIntents[0];
        assembly {
            mstore(add(maliciousCalldata, 512), 0x10000000000000007) // 2^64 + 7
        }
        (bool success,) =
            address(oc).call(abi.encodeWithSignature("execute(bytes)", maliciousCalldata));
        assertEq(success, false);
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
