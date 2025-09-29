// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./Base.t.sol";
import {MultiSigSigner} from "../src/MultiSigSigner.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";

contract MultiSigSignerTest is BaseTest {
    MultiSigSigner multiSigSigner;
    DelegatedEOA delegatedAccount;

    struct MultiSigTestTemps {
        PassKey[] owners;
        bytes32[] ownerKeyHashes;
        uint256 threshold;
        MultiSigKey multiSigKey;
        bytes32 digest;
    }

    function setUp() public override {
        super.setUp();
        multiSigSigner = new MultiSigSigner();
        delegatedAccount = _randomEIP7702DelegatedEOA();
    }

    function test_DuplicateOwnerSignatures() public {
        MultiSigTestTemps memory t;

        // Setup: Create a multisig with threshold 2 but only 1 owner
        t.threshold = 2;
        t.owners = new PassKey[](2);
        t.owners[0] = _randomPassKey();
        t.owners[1] = _randomPassKey();

        // Create the multisig key configuration
        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });
        t.multiSigKey.threshold = t.threshold;
        t.multiSigKey.owners = t.owners;

        // Authorize keys in the delegated account
        vm.startPrank(delegatedAccount.eoa);
        delegatedAccount.d.authorize(t.multiSigKey.k);
        delegatedAccount.d.authorize(t.owners[0].k);

        // Initialize multisig config with threshold=2 but only 1 owner
        t.ownerKeyHashes = new bytes32[](1);
        t.ownerKeyHashes[0] = _hash(t.owners[0].k);

        // This should revert because threshold > number of owners
        vm.expectRevert(MultiSigSigner.InvalidThreshold.selector);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        // Now test with a valid config: threshold=2, 2 owners
        t.ownerKeyHashes = new bytes32[](2);
        t.ownerKeyHashes[0] = _hash(t.owners[0].k);
        t.ownerKeyHashes[1] = _hash(t.owners[1].k);

        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        vm.stopPrank();

        // Create a digest to sign
        t.digest = keccak256("test message");

        // Create signature array with the same signature duplicated
        // Note: Each owner currently only has 1 signer power.
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sig(t.owners[0], t.digest);
        signatures[1] = signatures[0]; // Duplicate signature of the first owner

        // Call isValidSignatureWithKeyHash
        vm.prank(address(delegatedAccount.d));
        bytes4 result = multiSigSigner.isValidSignatureWithKeyHash(
            t.digest, _hash(t.multiSigKey.k), abi.encode(signatures)
        );

        // Same owner should not be able to sign multiple times
        assertEq(result, bytes4(0xffffffff), "Duplicate signature should not be valid");

        // Add the first owner twice in the owner key hash
        vm.startPrank(address(delegatedAccount.eoa));
        delegatedAccount.d.setContextKeyHash(_hash(t.multiSigKey.k));
        multiSigSigner.addOwner(_hash(t.multiSigKey.k), _hash(t.owners[0].k));
        vm.stopPrank();

        // Now it should be valid, because the first owner has 2 signer powers.
        vm.prank(address(delegatedAccount.d));
        result = multiSigSigner.isValidSignatureWithKeyHash(
            t.digest, _hash(t.multiSigKey.k), abi.encode(signatures)
        );

        assertEq(result, bytes4(0x8afc93b4), "Duplicate signature should be valid now");
    }

    function test_InitConfig() public {
        MultiSigTestTemps memory t;

        // Setup owners
        uint256 numOwners = 3;
        t.owners = new PassKey[](numOwners);
        t.ownerKeyHashes = new bytes32[](numOwners);

        for (uint256 i = 0; i < numOwners; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }

        t.threshold = 2;

        // Create multisig key
        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: false,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        vm.prank(address(delegatedAccount.d));
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        // Verify config was set correctly
        (uint256 storedThreshold, bytes32[] memory storedOwners) =
            multiSigSigner.getConfig(address(delegatedAccount.d), _hash(t.multiSigKey.k));

        assertEq(storedThreshold, t.threshold);
        assertEq(storedOwners.length, t.ownerKeyHashes.length);

        for (uint256 i = 0; i < storedOwners.length; i++) {
            assertEq(storedOwners[i], t.ownerKeyHashes[i]);
        }
    }

    function test_InitConfig_RevertsOnReinit() public {
        MultiSigTestTemps memory t;

        t.owners = new PassKey[](1);
        t.owners[0] = _randomPassKey();
        t.ownerKeyHashes = new bytes32[](1);
        t.ownerKeyHashes[0] = _hash(t.owners[0].k);
        t.threshold = 1;

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: false,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        // First initialization should succeed
        vm.startPrank(address(delegatedAccount.d));
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        // Second initialization should revert
        vm.expectRevert(MultiSigSigner.ConfigAlreadySet.selector);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);
        vm.stopPrank();
    }

    function test_InitConfig_InvalidThreshold() public {
        MultiSigTestTemps memory t;

        t.owners = new PassKey[](2);
        t.ownerKeyHashes = new bytes32[](2);
        for (uint256 i = 0; i < 2; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: false,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        vm.startPrank(address(delegatedAccount.d));

        // Test threshold = 0
        vm.expectRevert(MultiSigSigner.InvalidThreshold.selector);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), 0, t.ownerKeyHashes);

        // Test threshold > number of owners
        vm.expectRevert(MultiSigSigner.InvalidThreshold.selector);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), 3, t.ownerKeyHashes);

        vm.stopPrank();
    }

    function test_AddOwner() public {
        MultiSigTestTemps memory t;

        // Initial setup with 2 owners
        t.owners = new PassKey[](2);
        t.ownerKeyHashes = new bytes32[](2);
        for (uint256 i = 0; i < 2; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }
        t.threshold = 2;

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        // Initialize config
        vm.startPrank(address(delegatedAccount.d));
        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        // Add a new owner
        PassKey memory newOwner = _randomPassKey();
        bytes32 newOwnerKeyHash = _hash(newOwner.k);

        // Set context key hash
        delegatedAccount.d.setContextKeyHash(_hash(t.multiSigKey.k));
        multiSigSigner.addOwner(_hash(t.multiSigKey.k), newOwnerKeyHash);

        // Verify owner was added
        (, bytes32[] memory storedOwners) =
            multiSigSigner.getConfig(address(delegatedAccount.d), _hash(t.multiSigKey.k));

        assertEq(storedOwners.length, 3);
        assertEq(storedOwners[2], newOwnerKeyHash);

        vm.stopPrank();
    }

    function test_AddOwner_InvalidKeyHash() public {
        MultiSigTestTemps memory t;

        t.owners = new PassKey[](1);
        t.owners[0] = _randomPassKey();
        t.ownerKeyHashes = new bytes32[](1);
        t.ownerKeyHashes[0] = _hash(t.owners[0].k);

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        vm.startPrank(address(delegatedAccount.d));
        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), 1, t.ownerKeyHashes);

        // Try to add owner with wrong context key hash
        PassKey memory newOwner = _randomPassKey();

        // Set wrong context key hash
        delegatedAccount.d.setContextKeyHash(bytes32(uint256(123)));

        vm.expectRevert(MultiSigSigner.InvalidKeyHash.selector);
        multiSigSigner.addOwner(_hash(t.multiSigKey.k), _hash(newOwner.k));

        vm.stopPrank();
    }

    function test_RemoveOwner() public {
        MultiSigTestTemps memory t;

        // Setup with 3 owners
        t.owners = new PassKey[](3);
        t.ownerKeyHashes = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }
        t.threshold = 2;

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        vm.startPrank(address(delegatedAccount.d));
        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        // Remove the second owner
        delegatedAccount.d.setContextKeyHash(_hash(t.multiSigKey.k));
        multiSigSigner.removeOwner(_hash(t.multiSigKey.k), t.ownerKeyHashes[1]);

        // Verify owner was removed
        (, bytes32[] memory storedOwners) =
            multiSigSigner.getConfig(address(delegatedAccount.d), _hash(t.multiSigKey.k));

        assertEq(storedOwners.length, 2);
        // The last owner should have replaced the removed one
        assertEq(storedOwners[1], t.ownerKeyHashes[2]);

        vm.stopPrank();
    }

    function test_RemoveOwner_OwnerNotFound() public {
        MultiSigTestTemps memory t;

        t.owners = new PassKey[](2);
        t.ownerKeyHashes = new bytes32[](2);
        for (uint256 i = 0; i < 2; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        vm.startPrank(address(delegatedAccount.d));
        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), 1, t.ownerKeyHashes);

        // Try to remove non-existent owner
        delegatedAccount.d.setContextKeyHash(_hash(t.multiSigKey.k));
        vm.expectRevert(MultiSigSigner.OwnerNotFound.selector);
        multiSigSigner.removeOwner(_hash(t.multiSigKey.k), bytes32(uint256(999)));

        vm.stopPrank();
    }

    function test_RemoveOwner_ThresholdViolation() public {
        MultiSigTestTemps memory t;

        // Setup with 2 owners and threshold 2
        t.owners = new PassKey[](2);
        t.ownerKeyHashes = new bytes32[](2);
        for (uint256 i = 0; i < 2; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }
        t.threshold = 2;

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        vm.startPrank(address(delegatedAccount.d));
        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        // Try to remove owner when it would violate threshold
        delegatedAccount.d.setContextKeyHash(_hash(t.multiSigKey.k));
        vm.expectRevert(MultiSigSigner.InvalidThreshold.selector);
        multiSigSigner.removeOwner(_hash(t.multiSigKey.k), t.ownerKeyHashes[0]);

        vm.stopPrank();
    }

    function test_SetThreshold() public {
        MultiSigTestTemps memory t;

        // Setup with 3 owners
        t.owners = new PassKey[](3);
        t.ownerKeyHashes = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }
        t.threshold = 1;

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        vm.startPrank(address(delegatedAccount.d));
        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        // Change threshold to 2
        delegatedAccount.d.setContextKeyHash(_hash(t.multiSigKey.k));
        multiSigSigner.setThreshold(_hash(t.multiSigKey.k), 2);

        // Verify threshold was changed
        (uint256 storedThreshold,) =
            multiSigSigner.getConfig(address(delegatedAccount.d), _hash(t.multiSigKey.k));

        assertEq(storedThreshold, 2);

        // Change threshold to 3
        multiSigSigner.setThreshold(_hash(t.multiSigKey.k), 3);

        (storedThreshold,) =
            multiSigSigner.getConfig(address(delegatedAccount.d), _hash(t.multiSigKey.k));

        assertEq(storedThreshold, 3);

        vm.stopPrank();
    }

    function test_SetThreshold_Invalid() public {
        MultiSigTestTemps memory t;

        t.owners = new PassKey[](2);
        t.ownerKeyHashes = new bytes32[](2);
        for (uint256 i = 0; i < 2; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        vm.startPrank(address(delegatedAccount.d));
        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), 1, t.ownerKeyHashes);
        delegatedAccount.d.setContextKeyHash(_hash(t.multiSigKey.k));

        // Test threshold = 0
        vm.expectRevert(MultiSigSigner.InvalidThreshold.selector);
        multiSigSigner.setThreshold(_hash(t.multiSigKey.k), 0);

        // Test threshold > number of owners
        vm.expectRevert(MultiSigSigner.InvalidThreshold.selector);
        multiSigSigner.setThreshold(_hash(t.multiSigKey.k), 3);

        vm.stopPrank();
    }

    function test_ValidSignature_MeetsThreshold() public {
        MultiSigTestTemps memory t;

        // Setup with 3 owners, threshold 2
        t.owners = new PassKey[](3);
        t.ownerKeyHashes = new bytes32[](3);

        vm.startPrank(delegatedAccount.eoa);
        for (uint256 i = 0; i < 3; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
            delegatedAccount.d.authorize(t.owners[i].k);
        }

        t.threshold = 2;

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);
        vm.stopPrank();

        // Create a digest to sign
        t.digest = keccak256("test message");

        // Create signatures from 2 owners (meets threshold)
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sig(t.owners[0], t.digest);
        signatures[1] = _sig(t.owners[1], t.digest);

        // Validate signature
        vm.prank(address(delegatedAccount.d));
        bytes4 result = multiSigSigner.isValidSignatureWithKeyHash(
            t.digest, _hash(t.multiSigKey.k), abi.encode(signatures)
        );

        assertEq(result, bytes4(0x8afc93b4), "Valid signature should return MAGIC_VALUE");
    }

    function test_InvalidSignature_BelowThreshold() public {
        MultiSigTestTemps memory t;

        // Setup with 3 owners, threshold 2
        t.owners = new PassKey[](3);
        t.ownerKeyHashes = new bytes32[](3);

        vm.startPrank(delegatedAccount.eoa);
        for (uint256 i = 0; i < 3; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
            delegatedAccount.d.authorize(t.owners[i].k);
        }

        t.threshold = 2;

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);
        vm.stopPrank();

        // Create a digest to sign
        t.digest = keccak256("test message");

        // Create signature from only 1 owner (below threshold)
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sig(t.owners[0], t.digest);

        // Validate signature
        vm.prank(address(delegatedAccount.d));
        bytes4 result = multiSigSigner.isValidSignatureWithKeyHash(
            t.digest, _hash(t.multiSigKey.k), abi.encode(signatures)
        );

        assertEq(result, bytes4(0xffffffff), "Invalid signature should return FAIL_VALUE");
    }

    function test_InvalidSignature_NonOwner() public {
        MultiSigTestTemps memory t;

        // Setup with 2 owners
        t.owners = new PassKey[](2);
        t.ownerKeyHashes = new bytes32[](2);

        vm.startPrank(delegatedAccount.eoa);
        for (uint256 i = 0; i < 2; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
            delegatedAccount.d.authorize(t.owners[i].k);
        }

        t.threshold = 2;

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(0))
        });

        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), t.threshold, t.ownerKeyHashes);

        // Create a non-owner key
        PassKey memory nonOwner = _randomPassKey();
        delegatedAccount.d.authorize(nonOwner.k);

        vm.stopPrank();

        // Create a digest to sign
        t.digest = keccak256("test message");

        // Create signatures with one owner and one non-owner
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sig(t.owners[0], t.digest);
        signatures[1] = _sig(nonOwner, t.digest);

        // Validate signature
        vm.prank(address(delegatedAccount.d));
        bytes4 result = multiSigSigner.isValidSignatureWithKeyHash(
            t.digest, _hash(t.multiSigKey.k), abi.encode(signatures)
        );

        assertEq(result, bytes4(0xffffffff), "Non-owner signature should return FAIL_VALUE");
    }

    function testFuzz_InitConfig(uint256 numOwners, uint256 threshold) public {
        numOwners = bound(numOwners, 1, 10);
        threshold = bound(threshold, 1, numOwners);

        MultiSigTestTemps memory t;
        t.owners = new PassKey[](numOwners);
        t.ownerKeyHashes = new bytes32[](numOwners);

        for (uint256 i = 0; i < numOwners; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
        }

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: false,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(uint96(_random())))
        });

        vm.prank(address(delegatedAccount.d));
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), threshold, t.ownerKeyHashes);

        (uint256 storedThreshold, bytes32[] memory storedOwners) =
            multiSigSigner.getConfig(address(delegatedAccount.d), _hash(t.multiSigKey.k));

        assertEq(storedThreshold, threshold);
        assertEq(storedOwners.length, numOwners);
    }

    function testFuzz_SignatureValidation(uint256 numOwners, uint256 threshold, uint256 numSigners)
        public
    {
        numOwners = bound(numOwners, 1, 10);
        threshold = bound(threshold, 1, numOwners);
        numSigners = bound(numSigners, 0, numOwners);

        MultiSigTestTemps memory t;
        t.owners = new PassKey[](numOwners);
        t.ownerKeyHashes = new bytes32[](numOwners);

        vm.startPrank(delegatedAccount.eoa);
        for (uint256 i = 0; i < numOwners; i++) {
            t.owners[i] = _randomPassKey();
            t.ownerKeyHashes[i] = _hash(t.owners[i].k);
            delegatedAccount.d.authorize(t.owners[i].k);
        }

        t.multiSigKey.k = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true,
            publicKey: abi.encodePacked(address(multiSigSigner), bytes12(uint96(_random())))
        });

        delegatedAccount.d.authorize(t.multiSigKey.k);
        multiSigSigner.initConfig(_hash(t.multiSigKey.k), threshold, t.ownerKeyHashes);
        vm.stopPrank();

        t.digest = keccak256(abi.encode("test", _random()));

        bytes[] memory signatures = new bytes[](numSigners);
        for (uint256 i = 0; i < numSigners; i++) {
            signatures[i] = _sig(t.owners[i], t.digest);
        }

        vm.prank(address(delegatedAccount.d));
        bytes4 result = multiSigSigner.isValidSignatureWithKeyHash(
            t.digest, _hash(t.multiSigKey.k), abi.encode(signatures)
        );

        if (numSigners >= threshold) {
            assertEq(result, bytes4(0x8afc93b4), "Should be valid when signatures >= threshold");
        } else {
            assertEq(result, bytes4(0xffffffff), "Should be invalid when signatures < threshold");
        }
    }
}
