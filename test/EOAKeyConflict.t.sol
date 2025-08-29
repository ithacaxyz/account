// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./Base.t.sol";

/// @dev Test that reproduces the issue where using the EOA's private key as an admin key
/// causes validation failure due to recursive validation loop.
contract EOAKeyConflictTest is BaseTest {
    
    /// @dev Test that using EOA's own address as admin key publicKey causes validation failure
    function testEOAAsAdminKeyFails() public {
        // Create a delegated EOA
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);
        
        // Create an admin key where the publicKey is the EOA's own address
        // This simulates what happens when using mock_admin_with_key(KeyType::Secp256k1, eoa_private_key)
        PassKey memory adminKey;
        adminKey.k.keyType = IthacaAccount.KeyType.Secp256k1;
        adminKey.k.publicKey = abi.encode(d.eoa); // EOA's address as publicKey
        adminKey.k.isSuperAdmin = true;
        adminKey.k.expiry = 0;
        adminKey.privateKey = d.privateKey; // Same private key as EOA
        adminKey.keyHash = _hash(adminKey.k);
        
        // Authorize the key
        vm.prank(d.eoa);
        d.d.authorize(adminKey.k);
        
        // Create a simple call
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = _thisTargetFunctionCall(0, hex"");
        
        // Get nonce and compute digest
        uint256 nonce = d.d.getNonce(0);
        bytes32 digest = d.d.computeDigest(calls, nonce);
        
        // Sign with the admin key (using EOA's private key)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminKey.privateKey, digest);
        bytes memory innerSignature = abi.encodePacked(r, s, v);
        
        // Wrap the signature with keyHash and prehash flag (as relay.rs does)
        bytes memory wrappedSignature = abi.encodePacked(
            innerSignature,
            adminKey.keyHash,
            uint8(0) // prehash = false
        );
        
        // Try to execute with the wrapped signature
        bytes memory opData = abi.encodePacked(nonce, wrappedSignature);
        bytes memory executionData = abi.encode(calls, opData);
        
        // This should fail because:
        // 1. unwrapAndValidateSignature extracts the 65-byte inner signature
        // 2. For Secp256k1 keys, it calls SignatureCheckerLib.isValidSignatureNowCalldata
        // 3. Since publicKey is the EOA's address and EOA has code (delegated), 
        //    it calls isValidSignature on the EOA
        // 4. This triggers the 64/65 byte special case which expects ecrecover to return EOA address
        // 5. But ecrecover returns a different address because the digest is EIP-712 formatted
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);
    }
}