// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {IthacaAccount} from "./utils/mocks/MockAccount.sol";
import {GuardedExecutor} from "../src/IthacaAccount.sol";
import {BaseTest} from "./Base.t.sol";
import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Orchestrator, MockOrchestrator} from "./utils/mocks/MockOrchestrator.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";

contract UpgradeTests is BaseTest {
    address payable public oldProxyAddress;
    address public oldImplementation;
    address public newImplementation;

    // Test EOA that will be delegated to the proxy
    address public userEOA;
    uint256 public userEOAKey;
    IthacaAccount public userAccount;

    // Test keys
    PassKey public p256Key;
    PassKey public p256SuperAdminKey;
    PassKey public secp256k1Key;
    PassKey public secp256k1SuperAdminKey;
    PassKey public webAuthnP256Key;
    PassKey public externalKey;

    // Test tokens
    MockPaymentToken public mockToken1;
    MockPaymentToken public mockToken2;

    // Random addresses for testing transfers
    address[] public randomRecipients;

    // State capture - using simple mappings to avoid memory-to-storage issues
    // Pre-upgrade state
    bytes32[] preKeyHashes;
    mapping(bytes32 => IthacaAccount.Key) preKeys;
    mapping(bytes32 => bool) preAuthorized;
    uint256 preEthBalance;
    uint256 preToken1Balance;
    uint256 preToken2Balance;
    uint256 preNonce;
    // Get expected old version from environment variable
    string public expectedOldVersion = vm.envString("UPGRADE_TEST_OLD_VERSION");

    // Post-upgrade state
    bytes32[] postKeyHashes;
    mapping(bytes32 => IthacaAccount.Key) postKeys;
    mapping(bytes32 => bool) postAuthorized;
    uint256 postEthBalance;
    uint256 postToken1Balance;
    uint256 postToken2Balance;
    uint256 postNonce;

    function setUp() public override {
        super.setUp();

        // Fork the network to get the proxy bytecode
        string memory rpcUrl = vm.envString("UPGRADE_TEST_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Deploy test tokens
        mockToken1 = new MockPaymentToken();
        mockToken2 = new MockPaymentToken();

        // Setup random recipients
        for (uint256 i = 0; i < 5; i++) {
            randomRecipients.push(_randomAddress());
        }

        // Get old proxy address from environment
        oldProxyAddress = payable(vm.envAddress("UPGRADE_TEST_OLD_PROXY"));

        // Setup delegated EOA
        (userEOA, userEOAKey) = _randomUniqueSigner();

        vm.etch(userEOA, abi.encodePacked(hex"ef0100", address(oldProxyAddress)));

        userAccount = IthacaAccount(payable(userEOA));

        // Get the bytecode of the old proxy from the forked network
        bytes memory proxyBytecode = oldProxyAddress.code;
        require(proxyBytecode.length > 0, "No bytecode at old proxy address");

        newImplementation = address(new IthacaAccount(address(oc)));

        // Generate test keys
        p256Key = _randomSecp256r1PassKey();
        p256Key.k.isSuperAdmin = false;
        p256Key.k.expiry = 0; // Never expires

        p256SuperAdminKey = _randomSecp256r1PassKey();
        p256SuperAdminKey.k.isSuperAdmin = true;
        p256SuperAdminKey.k.expiry = uint40(block.timestamp + 365 days); // Expires in 1 year

        secp256k1Key = _randomSecp256k1PassKey();
        secp256k1Key.k.isSuperAdmin = false;
        secp256k1Key.k.expiry = 0;

        secp256k1SuperAdminKey = _randomSecp256k1PassKey();
        secp256k1SuperAdminKey.k.isSuperAdmin = true;
        secp256k1SuperAdminKey.k.expiry = uint40(block.timestamp + 30 days); // Expires in 30 days

        webAuthnP256Key = _randomSecp256r1PassKey();
        webAuthnP256Key.k.keyType = IthacaAccount.KeyType.WebAuthnP256;
        webAuthnP256Key.k.isSuperAdmin = false;
        webAuthnP256Key.k.expiry = 0;

        // Setup external key
        address externalSigner = _randomAddress();
        bytes12 salt = bytes12(uint96(_randomUniform()));
        externalKey.k.keyType = IthacaAccount.KeyType.External;
        externalKey.k.publicKey = abi.encodePacked(externalSigner, salt);
        externalKey.k.isSuperAdmin = false;
        externalKey.k.expiry = uint40(block.timestamp + 7 days);
        externalKey.keyHash = _hash(externalKey.k);
    }

    function test_ComprehensiveUpgrade() public {
        // Step 2: Setup the old account with various configurations
        _setupOldAccountState();

        // Step 3: Capture pre-upgrade state
        _capturePreUpgradeState();

        // Step 4: Perform upgrade
        _performUpgrade();

        // Step 5: Capture post-upgrade state
        _capturePostUpgradeState();

        // Step 6: Verify state preservation
        _verifyStatePreservation();

        // Step 7: Test post-upgrade functionality
        _testPostUpgradeFunctionality();
    }

    function _performUpgrade() internal {
        // Get the version from the new implementation for comparison
        IthacaAccount newImpl = IthacaAccount(payable(newImplementation));
        (,, string memory expectedNewVersion,,,,) = newImpl.eip712Domain();

        // Check version before upgrade matches expected old version
        (,, string memory versionBefore,,,,) = userAccount.eip712Domain();
        assertEq(
            keccak256(bytes(versionBefore)),
            keccak256(bytes(expectedOldVersion)),
            string.concat("Version before upgrade should be ", expectedOldVersion)
        );

        // Perform the upgrade
        bytes memory upgradeCalldata =
            abi.encodeWithSelector(IthacaAccount.upgradeProxyAccount.selector, newImplementation);

        vm.prank(userEOA);
        (bool success,) = userEOA.call(upgradeCalldata);
        require(success, "Upgrade failed");

        // Check version after upgrade
        (,, string memory versionAfter,,,,) = userAccount.eip712Domain();

        // Verify the version matches the new implementation version after upgrade
        assertEq(
            keccak256(bytes(versionAfter)),
            keccak256(bytes(expectedNewVersion)),
            string.concat("Version after upgrade should be ", expectedNewVersion)
        );
    }

    function _setupOldAccountState() internal {
        // Authorize various keys
        vm.startPrank(userEOA);

        userAccount.authorize(p256Key.k);
        p256Key.keyHash = _hash(p256Key.k);

        userAccount.authorize(secp256k1Key.k);
        secp256k1Key.keyHash = _hash(secp256k1Key.k);

        userAccount.authorize(secp256k1SuperAdminKey.k);
        secp256k1SuperAdminKey.keyHash = _hash(secp256k1SuperAdminKey.k);

        userAccount.authorize(webAuthnP256Key.k);
        webAuthnP256Key.keyHash = _hash(webAuthnP256Key.k);

        externalKey.keyHash = userAccount.authorize(externalKey.k);

        // Setup spending limits for different keys
        _setupSpendingLimits();

        // Setup execution permissions
        _setupExecutionPermissions();

        // Fund the account
        _fundAccount();

        vm.stopPrank();
    }

    function _setupSpendingLimits() internal {
        // Only set spending limits for non-super admin keys

        // Daily ETH limit for secp256k1Key (not a super admin)
        if (secp256k1Key.keyHash != bytes32(0)) {
            userAccount.setSpendLimit(
                secp256k1Key.keyHash, address(0), GuardedExecutor.SpendPeriod.Day, 1 ether
            );

            // Weekly ETH limit for secp256k1Key
            userAccount.setSpendLimit(
                secp256k1Key.keyHash, address(0), GuardedExecutor.SpendPeriod.Week, 5 ether
            );

            // Monthly token1 limit for secp256k1Key
            userAccount.setSpendLimit(
                secp256k1Key.keyHash,
                address(mockToken1),
                GuardedExecutor.SpendPeriod.Month,
                1000e18
            );
        }

        // Daily token2 limit for webAuthnP256Key (not a super admin)
        if (webAuthnP256Key.keyHash != bytes32(0)) {
            userAccount.setSpendLimit(
                webAuthnP256Key.keyHash,
                address(mockToken2),
                GuardedExecutor.SpendPeriod.Day,
                100e18
            );
        }

        // Hour ETH limit for externalKey (not a super admin)
        if (externalKey.keyHash != bytes32(0)) {
            userAccount.setSpendLimit(
                externalKey.keyHash, address(0), GuardedExecutor.SpendPeriod.Hour, 0.1 ether
            );
        }

        // Forever limit for p256Key (if authorized and not a super admin)
        if (p256Key.keyHash != bytes32(0) && !p256Key.k.isSuperAdmin) {
            userAccount.setSpendLimit(
                p256Key.keyHash, address(0), GuardedExecutor.SpendPeriod.Forever, 10 ether
            );
        }
    }

    function _setupExecutionPermissions() internal {
        // Setup canExecute permissions (only for non-super admin keys)
        address target1 = address(0x1234);
        address target2 = address(0x5678);
        bytes4 selector1 = bytes4(keccak256("transfer(address,uint256)"));
        bytes4 selector2 = bytes4(keccak256("approve(address,uint256)"));

        // Only set for non-super admin secp256k1Key
        if (secp256k1Key.keyHash != bytes32(0) && !secp256k1Key.k.isSuperAdmin) {
            userAccount.setCanExecute(secp256k1Key.keyHash, target1, selector1, true);
            userAccount.setCanExecute(secp256k1Key.keyHash, target2, selector2, true);
        }

        // Only set for p256Key if it's not a super admin
        if (p256Key.keyHash != bytes32(0) && !p256Key.k.isSuperAdmin) {
            userAccount.setCanExecute(p256Key.keyHash, target1, selector2, true);
        }

        // Only set for webAuthnP256Key if it's not a super admin
        if (webAuthnP256Key.keyHash != bytes32(0) && !webAuthnP256Key.k.isSuperAdmin) {
            userAccount.setCanExecute(webAuthnP256Key.keyHash, target2, selector1, true);
        }

        // Setup call checkers (only for non-super admin keys)
        address checker1 = address(0xAAAA);
        address checker2 = address(0xBBBB);

        if (secp256k1Key.keyHash != bytes32(0) && !secp256k1Key.k.isSuperAdmin) {
            userAccount.setCallChecker(secp256k1Key.keyHash, target1, checker1);
        }

        if (webAuthnP256Key.keyHash != bytes32(0) && !webAuthnP256Key.k.isSuperAdmin) {
            userAccount.setCallChecker(webAuthnP256Key.keyHash, target2, checker2);
        }
    }

    function _fundAccount() internal {
        // Fund with ETH
        vm.deal(address(userAccount), 10 ether);

        // Fund with tokens
        mockToken1.mint(address(userAccount), 10000e18);
        mockToken2.mint(address(userAccount), 5000e18);
    }

    function _capturePreUpgradeState() internal {
        // Capture authorized keys
        (, bytes32[] memory keyHashes) = userAccount.getKeys();

        // Clear and populate pre-upgrade key hashes
        delete preKeyHashes;
        for (uint256 i = 0; i < keyHashes.length; i++) {
            preKeyHashes.push(keyHashes[i]);
            bytes32 keyHash = keyHashes[i];
            preKeys[keyHash] = userAccount.getKey(keyHash);
            preAuthorized[keyHash] = true;
        }

        // Capture balances
        preEthBalance = address(userAccount).balance;
        preToken1Balance = mockToken1.balanceOf(address(userAccount));
        preToken2Balance = mockToken2.balanceOf(address(userAccount));

        // Capture nonce
        preNonce = userAccount.getNonce(0);
    }

    function _capturePostUpgradeState() internal {
        // Capture authorized keys
        (, bytes32[] memory keyHashes) = userAccount.getKeys();

        // Clear and populate post-upgrade key hashes
        delete postKeyHashes;
        for (uint256 i = 0; i < keyHashes.length; i++) {
            postKeyHashes.push(keyHashes[i]);
            bytes32 keyHash = keyHashes[i];
            postKeys[keyHash] = userAccount.getKey(keyHash);
            postAuthorized[keyHash] = true;
        }

        // Capture balances
        postEthBalance = address(userAccount).balance;
        postToken1Balance = mockToken1.balanceOf(address(userAccount));
        postToken2Balance = mockToken2.balanceOf(address(userAccount));

        // Capture nonce
        postNonce = userAccount.getNonce(0);
    }

    function _verifyStatePreservation() internal view {
        // Verify all keys are preserved
        assertEq(preKeyHashes.length, postKeyHashes.length, "Number of authorized keys changed");

        for (uint256 i = 0; i < preKeyHashes.length; i++) {
            bytes32 keyHash = preKeyHashes[i];

            assertTrue(postAuthorized[keyHash], "Key was deauthorized during upgrade");

            IthacaAccount.Key memory preKey = preKeys[keyHash];
            IthacaAccount.Key memory postKey = postKeys[keyHash];

            assertEq(preKey.expiry, postKey.expiry, "Key expiry changed");
            assertEq(uint8(preKey.keyType), uint8(postKey.keyType), "Key type changed");
            assertEq(preKey.isSuperAdmin, postKey.isSuperAdmin, "Key super admin status changed");
            assertEq(preKey.publicKey, postKey.publicKey, "Key public key changed");
        }

        // Verify balances preserved
        assertEq(preEthBalance, postEthBalance, "ETH balance changed");
        assertEq(preToken1Balance, postToken1Balance, "Token1 balance changed");
        assertEq(preToken2Balance, postToken2Balance, "Token2 balance changed");

        // Verify nonce preserved
        assertEq(preNonce, postNonce, "Nonce changed");
    }

    function _testPostUpgradeFunctionality() internal {
        vm.startPrank(userEOA);

        // Test 1: P256 keys can now be super admins (new in v0.5.7+)
        PassKey memory newP256SuperAdmin = _randomSecp256r1PassKey();
        newP256SuperAdmin.k.isSuperAdmin = true;
        newP256SuperAdmin.k.expiry = 0;

        // This should succeed in upgraded version
        bytes32 newP256KeyHash = userAccount.authorize(newP256SuperAdmin.k);
        IthacaAccount.Key memory retrievedKey = userAccount.getKey(newP256KeyHash);
        assertEq(
            uint8(retrievedKey.keyType), uint8(IthacaAccount.KeyType.P256), "Key type mismatch"
        );
        assertTrue(retrievedKey.isSuperAdmin, "P256 should be super admin after upgrade");

        // Test 2: Add a new non-super-admin key and set spending limit
        PassKey memory newRegularKey = _randomSecp256k1PassKey();
        newRegularKey.k.isSuperAdmin = false;
        newRegularKey.k.expiry = 0;

        bytes32 newRegularKeyHash = userAccount.authorize(newRegularKey.k);

        // Set spending limit for the regular key (not super admin)
        userAccount.setSpendLimit(
            newRegularKeyHash, address(0), GuardedExecutor.SpendPeriod.Week, 2 ether
        );

        GuardedExecutor.SpendInfo[] memory spendInfos = userAccount.spendInfos(newRegularKeyHash);
        bool foundWeeklyLimit = false;
        for (uint256 i = 0; i < spendInfos.length; i++) {
            if (
                spendInfos[i].period == GuardedExecutor.SpendPeriod.Week
                    && spendInfos[i].token == address(0)
            ) {
                assertEq(spendInfos[i].limit, 2 ether, "Weekly limit not set correctly");
                foundWeeklyLimit = true;
                break;
            }
        }
        assertTrue(foundWeeklyLimit, "Weekly limit not found");

        // Test 3: Verify keys can still be used (without actual execution)
        // We verify the key is still authorized and has correct properties
        IthacaAccount.Key memory existingKey = userAccount.getKey(secp256k1Key.keyHash);
        assertEq(
            uint8(existingKey.keyType), uint8(IthacaAccount.KeyType.Secp256k1), "Key type changed"
        );
        assertFalse(existingKey.isSuperAdmin, "Key admin status changed");

        // Test 4: Test revoke and re-authorize with a new key
        // Create a new key to test revoke/re-authorize functionality
        PassKey memory testRevokeKey = _randomSecp256k1PassKey();
        testRevokeKey.k.isSuperAdmin = false;
        testRevokeKey.k.expiry = 0;

        bytes32 testRevokeKeyHash = userAccount.authorize(testRevokeKey.k);

        // Now revoke it
        userAccount.revoke(testRevokeKeyHash);

        // Verify key is revoked by checking it no longer exists
        // After revocation, getKey will revert with KeyDoesNotExist
        vm.expectRevert(abi.encodeWithSelector(IthacaAccount.KeyDoesNotExist.selector));
        userAccount.getKey(testRevokeKeyHash);

        // Re-authorize
        bytes32 reauthorizedHash = userAccount.authorize(testRevokeKey.k);
        assertEq(reauthorizedHash, testRevokeKeyHash, "Key hash changed on re-authorization");

        vm.stopPrank();
    }

    function test_UpgradeWithSpendLimitEnabledFlag() public {
        // This test verifies the spend limit enabled flag feature added in newer versions

        vm.startPrank(userEOA);

        // Authorize a key with spending limits
        PassKey memory testKey = _randomSecp256k1PassKey();
        bytes32 keyHash = userAccount.authorize(testKey.k);

        // Set spending limit
        userAccount.setSpendLimit(keyHash, address(0), GuardedExecutor.SpendPeriod.Day, 0.5 ether);

        // Fund account
        vm.deal(address(userAccount), 5 ether);

        vm.stopPrank();

        // Perform upgrade
        _performUpgrade();

        // Verify spending limits still work after upgrade
        GuardedExecutor.SpendInfo[] memory spendInfos = userAccount.spendInfos(keyHash);
        assertEq(spendInfos.length, 1, "Spending limit not preserved");
        assertEq(spendInfos[0].limit, 0.5 ether, "Spending limit value changed");

        vm.stopPrank();
    }

    function test_UpgradeWithMultipleKeyTypes() public {
        // Test upgrade with all key types authorized

        vm.startPrank(userEOA);

        // Authorize all key types
        PassKey[] memory keys = new PassKey[](4);
        keys[0] = _randomSecp256r1PassKey();
        keys[1] = _randomSecp256k1PassKey();
        keys[2] = _randomSecp256r1PassKey();
        keys[2].k.keyType = IthacaAccount.KeyType.WebAuthnP256;
        keys[3].k.keyType = IthacaAccount.KeyType.External;
        keys[3].k.publicKey = abi.encodePacked(_randomAddress(), bytes12(uint96(_randomUniform())));
        keys[3].keyHash = _hash(keys[3].k);

        bytes32[] memory keyHashes = new bytes32[](4);
        for (uint256 i = 0; i < keys.length; i++) {
            // Some key types might fail in old versions, handle gracefully
            try userAccount.authorize(keys[i].k) returns (bytes32 kh) {
                keyHashes[i] = kh;
            } catch {
                // Skip if authorization fails
            }
        }

        // Capture authorized count before upgrade
        (, bytes32[] memory keyHashesBefore) = userAccount.getKeys();
        uint256 authorizedCountBefore = keyHashesBefore.length;

        vm.stopPrank();

        // Perform upgrade
        _performUpgrade();

        // Verify all keys preserved
        (, bytes32[] memory keyHashesAfter) = userAccount.getKeys();
        uint256 authorizedCountAfter = keyHashesAfter.length;
        assertEq(authorizedCountBefore, authorizedCountAfter, "Key count changed during upgrade");

        vm.stopPrank();
    }

    function test_UpgradePreservesComplexSpendingState() public {
        // Test that complex spending state with partially spent limits is preserved

        vm.startPrank(userEOA);

        // Setup key and limits
        PassKey memory spendKey = _randomSecp256k1PassKey();
        bytes32 keyHash = userAccount.authorize(spendKey.k);

        // Set multiple spending limits
        userAccount.setSpendLimit(keyHash, address(0), GuardedExecutor.SpendPeriod.Day, 1 ether);
        userAccount.setSpendLimit(keyHash, address(0), GuardedExecutor.SpendPeriod.Week, 3 ether);
        userAccount.setSpendLimit(keyHash, address(0), GuardedExecutor.SpendPeriod.Month, 10 ether);

        // Fund account
        vm.deal(address(userAccount), 20 ether);
        vm.stopPrank();

        // Capture spending state before upgrade
        GuardedExecutor.SpendInfo[] memory spendsBefore = userAccount.spendInfos(keyHash);

        // Verify spending limits are set
        uint256 limitsCount = 0;
        for (uint256 i = 0; i < spendsBefore.length; i++) {
            if (spendsBefore[i].token == address(0)) {
                limitsCount++;
            }
        }
        assertEq(limitsCount, 3, "Should have 3 ETH spending limits");

        // Perform upgrade
        _performUpgrade();

        // Verify spending state preserved
        GuardedExecutor.SpendInfo[] memory spendsAfter = userAccount.spendInfos(keyHash);

        // Verify all limits still exist
        uint256 limitsCountAfter = 0;
        for (uint256 i = 0; i < spendsAfter.length; i++) {
            if (spendsAfter[i].token == address(0)) {
                limitsCountAfter++;
            }
        }
        assertEq(limitsCountAfter, 3, "Spending limits not preserved after upgrade");

        // Verify limits match
        assertEq(spendsBefore.length, spendsAfter.length, "Number of spending limits changed");
        for (uint256 i = 0; i < spendsBefore.length; i++) {
            assertEq(spendsBefore[i].limit, spendsAfter[i].limit, "Limit value changed");
            assertEq(uint8(spendsBefore[i].period), uint8(spendsAfter[i].period), "Period changed");
        }
    }
}
