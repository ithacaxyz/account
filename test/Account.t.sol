// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";

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

    function testMerkleSignature(uint256 seed) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        // Fuzz number of leaves (2 to 256)
        uint256 numLeaves = bound(seed, 2, 256);
        bytes32[] memory leaves = new bytes32[](numLeaves);

        // Generate random leaves
        for (uint256 i = 0; i < numLeaves; i++) {
            leaves[i] = keccak256(abi.encodePacked("leaf", i, seed));
        }

        // Pick a random valid index
        uint256 validIndex = seed % numLeaves;
        bytes32 validDigest = leaves[validIndex];

        Merkle merkle = new Merkle();
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, validIndex);

        // Test valid merkle proof
        {
            bytes memory rootSig = abi.encode(proof, root, _sig(k, root));
            bytes memory sig = abi.encodePacked(rootSig, bytes32(0), uint8(0), uint8(1));

            (bool isValid, bytes32 keyHash) = d.d.unwrapAndValidateSignature(validDigest, sig);
            assertEq(isValid, true);
            assertEq(keyHash, k.keyHash);

            // Test invalid digest not in tree
            bytes32 invalidDigest = keccak256(abi.encodePacked("not_in_tree", seed));
            (isValid, keyHash) = d.d.unwrapAndValidateSignature(invalidDigest, sig);
            assertEq(isValid, false);
            assertEq(keyHash, bytes32(0));
        }

        // Test tampered proof (only if proof has elements to tamper)
        if (proof.length > 0) {
            bytes32[] memory tamperedProof = new bytes32[](proof.length);
            for (uint256 i = 0; i < proof.length; i++) {
                tamperedProof[i] = i == 0 ? bytes32(uint256(proof[i]) ^ 1) : proof[i];
            }
            bytes memory tamperedRootSig = abi.encode(tamperedProof, root, _sig(k, root));
            bytes memory tamperedSig =
                abi.encodePacked(tamperedRootSig, bytes32(0), uint8(0), uint8(1));
            (bool isValid,) = d.d.unwrapAndValidateSignature(validDigest, tamperedSig);
            assertEq(isValid, false);
        }

        // Test wrong root (tampered root should fail verification)
        {
            bytes32 wrongRoot = bytes32(uint256(root) ^ 1);
            bytes memory wrongRootSig = abi.encode(proof, wrongRoot, _sig(k, wrongRoot));
            bytes memory wrongSig = abi.encodePacked(wrongRootSig, bytes32(0), uint8(0), uint8(1));
            (bool isValid,) = d.d.unwrapAndValidateSignature(validDigest, wrongSig);
            assertEq(isValid, false);
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

        (,,,, address verifyingContract,,) = d.d.eip712Domain();
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

    function testContextKeyHash() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        PassKey memory key = _randomPassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        // Orchestrator workflow
        vm.prank(d.d.ORCHESTRATOR());
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].data = abi.encodeWithSelector(this.targetFunctionContextKeyHash.selector);
        calls[0].to = address(this);
        calls[0].value = 0;
        bytes memory opData = abi.encode(key.keyHash);
        bytes memory executionData = abi.encode(calls, opData);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(contextKeyHash, key.keyHash, "Context key hash mismatch orchestrator workflow");

        // Reset context key hash
        contextKeyHash = bytes32(0);

        // Workflow with opData
        uint256 nonce = d.d.getNonce(0);
        bytes memory signature = _sig(key, d.d.computeDigest(calls, nonce));
        opData = abi.encodePacked(nonce, signature);
        executionData = abi.encode(calls, opData);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(contextKeyHash, key.keyHash, "Context key hash mismatch orchestrator workflow");

        // Reset context key hash
        contextKeyHash = bytes32(0);

        // Simple workflow without opData (self-execution)
        bytes memory emptyOpData;
        executionData = abi.encode(calls, emptyOpData);
        vm.prank(address(d.d));
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(
            contextKeyHash,
            bytes32(0),
            "Context key hash should be zero for self-execution without opData"
        );
    }
}
