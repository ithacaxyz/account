// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

/// @dev Mock target that reads getContextKeyHash from the calling account
/// and stores it, supporting multiple reads for nested context verification.
contract ContextKeyHashReader {
    bytes32[] public capturedKeyHashes;

    function captureContextKeyHash() external {
        bytes32 keyHash = IthacaAccount(payable(msg.sender)).getContextKeyHash();
        capturedKeyHashes.push(keyHash);
    }

    function getCapturedKeyHash(uint256 index) external view returns (bytes32) {
        return capturedKeyHashes[index];
    }

    function getCapturedCount() external view returns (uint256) {
        return capturedKeyHashes.length;
    }

    function reset() external {
        delete capturedKeyHashes;
    }
}

contract ContextKeyHashTest is BaseTest {
    ContextKeyHashReader reader;

    function setUp() public override {
        super.setUp();
        reader = new ContextKeyHashReader();
    }

    // ---------------------------------------------------------------
    // Key hash computation correctness
    // ---------------------------------------------------------------

    /// @dev Verify that the on-chain hash function matches manual keccak computation.
    function testKeyHashComputationSecp256k1() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;

        // Manually compute: keccak256(abi.encode(uint8(keyType), keccak256(publicKey)))
        bytes32 manualHash = keccak256(abi.encode(uint8(k.k.keyType), keccak256(k.k.publicKey)));

        // Compare with the contract's hash function
        bytes32 contractHash = d.d.hash(k.k);

        assertEq(contractHash, manualHash, "Secp256k1 key hash mismatch with manual computation");
        assertEq(contractHash, k.keyHash, "Secp256k1 key hash mismatch with stored keyHash");
    }

    /// @dev Verify that the on-chain hash function matches for P256 keys.
    function testKeyHashComputationP256() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256r1PassKey();
        k.k.isSuperAdmin = true;

        bytes32 manualHash = keccak256(abi.encode(uint8(k.k.keyType), keccak256(k.k.publicKey)));

        bytes32 contractHash = d.d.hash(k.k);

        assertEq(contractHash, manualHash, "P256 key hash mismatch with manual computation");
        assertEq(contractHash, k.keyHash, "P256 key hash mismatch with stored keyHash");
    }

    /// @dev Different keys must produce different hashes.
    function testDifferentKeysProduceDifferentHashes() public {
        PassKey memory k1 = _randomSecp256k1PassKey();
        PassKey memory k2 = _randomSecp256k1PassKey();

        assertTrue(k1.keyHash != k2.keyHash, "Different keys should have different hashes");
    }

    /// @dev Same key type with same public key produces the same hash regardless of expiry.
    function testKeyHashIgnoresExpiry() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        bytes32 hash1 = d.d.hash(k.k);

        k.k.expiry = uint40(block.timestamp + 1000);
        bytes32 hash2 = d.d.hash(k.k);

        assertEq(hash1, hash2, "Key hash should not depend on expiry");
    }

    // ---------------------------------------------------------------
    // getContextKeyHash outside execution context
    // ---------------------------------------------------------------

    /// @dev getContextKeyHash returns bytes32(0) when called outside any execution.
    function testGetContextKeyHashOutsideExecution() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        bytes32 result = d.d.getContextKeyHash();
        assertEq(result, bytes32(0), "Should return zero outside execution context");
    }

    // ---------------------------------------------------------------
    // Orchestrator workflow
    // ---------------------------------------------------------------

    /// @dev Verify getContextKeyHash returns the correct key hash during orchestrator execution.
    function testContextKeyHashOrchestratorWorkflow() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key = _randomSecp256k1PassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        bytes memory opData = abi.encode(key.keyHash);
        bytes memory executionData = abi.encode(calls, opData);

        vm.prank(d.d.ORCHESTRATOR());
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(reader.getCapturedCount(), 1, "Should have captured one key hash");
        assertEq(
            reader.getCapturedKeyHash(0),
            key.keyHash,
            "Orchestrator workflow should expose correct key hash"
        );
    }

    /// @dev Verify getContextKeyHash with P256 key via orchestrator.
    function testContextKeyHashOrchestratorP256Key() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key = _randomSecp256r1PassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        bytes memory opData = abi.encode(key.keyHash);
        bytes memory executionData = abi.encode(calls, opData);

        vm.prank(d.d.ORCHESTRATOR());
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(
            reader.getCapturedKeyHash(0),
            key.keyHash,
            "P256 key hash should be correct in orchestrator workflow"
        );
    }

    // ---------------------------------------------------------------
    // Signature-based workflow (opData with nonce + signature)
    // ---------------------------------------------------------------

    /// @dev Verify getContextKeyHash returns the correct key hash during signature-based execution.
    function testContextKeyHashSignatureWorkflow() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key = _randomSecp256k1PassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        uint256 nonce = d.d.getNonce(0);
        bytes memory signature = _sig(key, d.d.computeDigest(calls, nonce));
        bytes memory opData = abi.encodePacked(nonce, signature);
        bytes memory executionData = abi.encode(calls, opData);

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(
            reader.getCapturedKeyHash(0),
            key.keyHash,
            "Signature workflow should expose correct key hash"
        );
    }

    /// @dev Verify getContextKeyHash with P256 key via signature workflow.
    function testContextKeyHashSignatureWorkflowP256() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key = _randomSecp256r1PassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        uint256 nonce = d.d.getNonce(0);
        bytes memory signature = _sig(key, d.d.computeDigest(calls, nonce));
        bytes memory opData = abi.encodePacked(nonce, signature);
        bytes memory executionData = abi.encode(calls, opData);

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(
            reader.getCapturedKeyHash(0),
            key.keyHash,
            "P256 signature workflow should expose correct key hash"
        );
    }

    // ---------------------------------------------------------------
    // Self-execution (no opData = EOA key)
    // ---------------------------------------------------------------

    /// @dev Self-execution without opData should yield bytes32(0) for the key hash.
    function testContextKeyHashSelfExecution() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        bytes memory emptyOpData;
        bytes memory executionData = abi.encode(calls, emptyOpData);

        vm.prank(address(d.d));
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(
            reader.getCapturedKeyHash(0),
            bytes32(0),
            "Self-execution should yield zero key hash (EOA key)"
        );
    }

    // ---------------------------------------------------------------
    // Stack cleanup: key hash is zero after execution completes
    // ---------------------------------------------------------------

    /// @dev After orchestrator execution completes, getContextKeyHash should return zero.
    function testContextKeyHashClearedAfterOrchestratorExecution() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key = _randomSecp256k1PassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        bytes memory opData = abi.encode(key.keyHash);
        bytes memory executionData = abi.encode(calls, opData);

        vm.prank(d.d.ORCHESTRATOR());
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        // After execution, the stack should be empty again.
        assertEq(
            d.d.getContextKeyHash(), bytes32(0), "Key hash stack should be empty after execution"
        );
    }

    /// @dev After signature-based execution completes, getContextKeyHash should return zero.
    function testContextKeyHashClearedAfterSignatureExecution() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key = _randomSecp256k1PassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        uint256 nonce = d.d.getNonce(0);
        bytes memory signature = _sig(key, d.d.computeDigest(calls, nonce));
        bytes memory opData = abi.encodePacked(nonce, signature);
        bytes memory executionData = abi.encode(calls, opData);

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(
            d.d.getContextKeyHash(),
            bytes32(0),
            "Key hash stack should be empty after signature-based execution"
        );
    }

    // ---------------------------------------------------------------
    // Multiple calls in a single batch share the same context key hash
    // ---------------------------------------------------------------

    /// @dev All calls within a batch should see the same key hash.
    function testContextKeyHashConsistentAcrossBatchCalls() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key = _randomSecp256k1PassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        ERC7821.Call[] memory calls = new ERC7821.Call[](3);
        for (uint256 i; i < 3; ++i) {
            calls[i].to = address(reader);
            calls[i].data =
                abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);
        }

        bytes memory opData = abi.encode(key.keyHash);
        bytes memory executionData = abi.encode(calls, opData);

        vm.prank(d.d.ORCHESTRATOR());
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(reader.getCapturedCount(), 3, "Should have captured three key hashes");
        for (uint256 i; i < 3; ++i) {
            assertEq(
                reader.getCapturedKeyHash(i),
                key.keyHash,
                "All batch calls should see the same key hash"
            );
        }
    }

    // ---------------------------------------------------------------
    // Different keys produce different context key hashes
    // ---------------------------------------------------------------

    /// @dev Two separate executions with different keys should report different key hashes.
    function testContextKeyHashDiffersBetweenKeys() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        PassKey memory key1 = _randomSecp256k1PassKey();
        key1.k.isSuperAdmin = true;

        PassKey memory key2 = _randomSecp256k1PassKey();
        key2.k.isSuperAdmin = true;

        vm.startPrank(d.eoa);
        d.d.authorize(key1.k);
        d.d.authorize(key2.k);
        vm.stopPrank();

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        // Execute with key1 via orchestrator
        bytes memory opData1 = abi.encode(key1.keyHash);
        bytes memory executionData1 = abi.encode(calls, opData1);
        vm.prank(d.d.ORCHESTRATOR());
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData1);

        // Execute with key2 via orchestrator
        bytes memory opData2 = abi.encode(key2.keyHash);
        bytes memory executionData2 = abi.encode(calls, opData2);
        vm.prank(d.d.ORCHESTRATOR());
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData2);

        assertEq(reader.getCapturedCount(), 2, "Should have captured two key hashes");
        assertEq(reader.getCapturedKeyHash(0), key1.keyHash, "First execution should use key1");
        assertEq(reader.getCapturedKeyHash(1), key2.keyHash, "Second execution should use key2");
        assertTrue(
            reader.getCapturedKeyHash(0) != reader.getCapturedKeyHash(1),
            "Different keys should produce different context key hashes"
        );
    }

    // ---------------------------------------------------------------
    // Fuzz: key hash computation is deterministic
    // ---------------------------------------------------------------

    /// @dev Fuzz test: hash function is deterministic for the same key type and public key.
    function testFuzz_KeyHashDeterministic(uint8 keyTypeSeed, bytes memory publicKey) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        IthacaAccount.KeyType keyType = IthacaAccount.KeyType(keyTypeSeed & 1);

        IthacaAccount.Key memory k;
        k.keyType = keyType;
        k.publicKey = publicKey;

        bytes32 hash1 = d.d.hash(k);
        bytes32 hash2 = d.d.hash(k);

        assertEq(hash1, hash2, "Hash must be deterministic");

        // Verify against manual computation.
        bytes32 expected = keccak256(abi.encode(uint8(keyType), keccak256(publicKey)));
        assertEq(hash1, expected, "Hash must match manual keccak computation");
    }

    // ---------------------------------------------------------------
    // Fuzz: orchestrator workflow preserves key hash
    // ---------------------------------------------------------------

    /// @dev Fuzz test: orchestrator workflow always exposes the authorized key's hash.
    function testFuzz_ContextKeyHashOrchestrator(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key = _randomPassKey();
        key.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(key.k);

        reader.reset();

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        bytes memory opData = abi.encode(key.keyHash);
        bytes memory executionData = abi.encode(calls, opData);

        vm.prank(d.d.ORCHESTRATOR());
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(
            reader.getCapturedKeyHash(0),
            key.keyHash,
            "Orchestrator should expose the authorized key hash"
        );

        // Verify stack is cleaned up.
        assertEq(d.d.getContextKeyHash(), bytes32(0), "Stack must be clean after execution");
    }

    // ---------------------------------------------------------------
    // Sequential executions with different keys
    // ---------------------------------------------------------------

    /// @dev Sequential executions should each have independent key hash contexts.
    function testContextKeyHashSequentialExecutions() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory key1 = _randomSecp256k1PassKey();
        key1.k.isSuperAdmin = true;
        PassKey memory key2 = _randomSecp256r1PassKey();
        key2.k.isSuperAdmin = true;

        vm.startPrank(d.eoa);
        d.d.authorize(key1.k);
        d.d.authorize(key2.k);
        vm.stopPrank();

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        // First execution with key1 (secp256k1) via signature workflow
        uint256 nonce1 = d.d.getNonce(0);
        bytes memory sig1 = _sig(key1, d.d.computeDigest(calls, nonce1));
        d.d.execute(
            _ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls, abi.encodePacked(nonce1, sig1))
        );

        // Verify stack is clean between executions
        assertEq(d.d.getContextKeyHash(), bytes32(0), "Stack should be clean between executions");

        // Second execution with key2 (P256) via signature workflow
        uint256 nonce2 = d.d.getNonce(0);
        bytes memory sig2 = _sig(key2, d.d.computeDigest(calls, nonce2));
        d.d.execute(
            _ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls, abi.encodePacked(nonce2, sig2))
        );

        assertEq(reader.getCapturedCount(), 2, "Should have two captures");
        assertEq(reader.getCapturedKeyHash(0), key1.keyHash, "First should be key1 hash");
        assertEq(reader.getCapturedKeyHash(1), key2.keyHash, "Second should be key2 hash");
    }

    // ---------------------------------------------------------------
    // EOA signature (no key hash appended) yields bytes32(0)
    // ---------------------------------------------------------------

    /// @dev When the EOA itself signs (no key hash in signature), context key hash is bytes32(0).
    function testContextKeyHashEOASignature() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(reader);
        calls[0].data = abi.encodeWithSelector(ContextKeyHashReader.captureContextKeyHash.selector);

        uint256 nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(calls, nonce));
        bytes memory opData = abi.encodePacked(nonce, signature);
        bytes memory executionData = abi.encode(calls, opData);

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        assertEq(
            reader.getCapturedKeyHash(0), bytes32(0), "EOA signature should produce zero key hash"
        );
    }

    // ---------------------------------------------------------------
    // MockAccount.setContextKeyHash helper
    // ---------------------------------------------------------------

    /// @dev Verify the MockAccount helper pushes onto the transient stack correctly.
    function testSetContextKeyHashMockHelper() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        bytes32 testHash = keccak256("test-key-hash");

        // Use the mock helper to push a value.
        d.d.setContextKeyHash(testHash);

        // The stack should now have the value.
        assertEq(d.d.getContextKeyHash(), testHash, "Mock helper should push onto key hash stack");

        // Push another value.
        bytes32 testHash2 = keccak256("test-key-hash-2");
        d.d.setContextKeyHash(testHash2);

        // Top of stack should be the new value.
        assertEq(d.d.getContextKeyHash(), testHash2, "Top of stack should be the latest push");
    }
}
