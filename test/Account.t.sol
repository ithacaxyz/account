// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";

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

    function testAddDisallowedSuperAdminKeyTypeReverts() public {
        address orchestrator = address(new Orchestrator(address(this)));
        address accountImplementation = address(new IthacaAccount(address(orchestrator)));
        address accountProxy = address(LibEIP7702.deployProxy(accountImplementation, address(0)));
        account = MockAccount(payable(accountProxy));

        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        PassKey memory k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;

        vm.startPrank(d.eoa);

        d.d.authorize(k.k);

        k = _randomSecp256r1PassKey();
        k.k.isSuperAdmin = true;
        vm.expectRevert(bytes4(keccak256("KeyTypeCannotBeSuperAdmin()")));
        d.d.authorize(k.k);

        vm.stopPrank();
    }

    function testPause() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);
        address pauseAuthority = _randomAddress();
        oc.setPauseAuthority(pauseAuthority);

        (address ocPauseAuthority, uint40 lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, 0);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);

        // Pause authority is always the EP
        calls[0].to = address(d.d);
        calls[0].data = abi.encodeWithSignature("setPauseAuthority(address)", pauseAuthority);
        uint256 nonce = d.d.getNonce(0);
        bytes memory opData = abi.encodePacked(nonce, _sig(d, d.d.computeDigest(calls, nonce)));
        bytes memory executionData = abi.encode(calls, opData);

        // Setup a mock call
        calls[0] = _transferCall(address(0), address(0x1234), 1 ether);
        nonce = d.d.getNonce(0);
        bytes32 digest = d.d.computeDigest(calls, nonce);
        bytes memory signature = _sig(d, digest);

        opData = abi.encodePacked(nonce, signature);
        executionData = abi.encode(calls, opData);

        // Check that execution can pass before pause.
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        // The block timestamp needs to be realistic
        vm.warp(6 weeks + 1 days);

        // Only the pause authority can pause.
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.setPauseAuthority(pauseAuthority);

        vm.startPrank(pauseAuthority);
        oc.pause(true);

        assertEq(oc.pauseFlag(), 1);
        (ocPauseAuthority, lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, block.timestamp);
        vm.stopPrank();

        // Check that execute fails
        nonce = d.d.getNonce(0);
        digest = d.d.computeDigest(calls, nonce);
        signature = _sig(d, digest);
        opData = abi.encodePacked(nonce, signature);
        executionData = abi.encode(calls, opData);

        vm.expectRevert(bytes4(keccak256("Paused()")));
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        // Check that intent fails
        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.nonce = d.d.getNonce(0);
        u.combinedGas = 1000000;
        u.executionData = _transferExecutionData(address(0), address(0xabcd), 1 ether);
        u.signature = _eoaSig(d.privateKey, u);

        assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("VerificationError()")));

        vm.startPrank(pauseAuthority);
        // Try to pause already paused account.
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.pause(true);

        oc.pause(false);
        assertEq(oc.pauseFlag(), 0);
        (ocPauseAuthority, lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, block.timestamp);

        // Cannot immediately repause again.
        vm.warp(lastPaused + 4 weeks + 1 days);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.pause(true);
        vm.stopPrank();

        // Intent should now succeed.
        assertEq(oc.execute(abi.encode(u)), 0);

        // Can pause again, after the cooldown period.
        vm.warp(lastPaused + 5 weeks + 1);
        vm.startPrank(pauseAuthority);
        oc.pause(true);
        vm.stopPrank();

        assertEq(oc.pauseFlag(), 1);
        (ocPauseAuthority, lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, block.timestamp);

        // Anyone can unpause after 4 weeks.
        vm.warp(lastPaused + 4 weeks + 1);
        oc.pause(false);
        assertEq(oc.pauseFlag(), 0);
        (ocPauseAuthority, lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, block.timestamp - 4 weeks - 1);

        address orchestratorAddress = address(oc);

        // Try setting pauseAuthority with dirty bits.
        assembly ("memory-safe") {
            mstore(0x00, 0x4b90364f) // `setPauseAuthority(address)`
            mstore(0x20, 0xffffffffffffffffffffffffffffffffffffffff)

            let success := call(gas(), orchestratorAddress, 0x00, 0x1c, 0x24, 0x00, 0x00)
            if success { revert(0, 0) }
        }
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

    ////////////////////////////////////////////////////////////////////////
    // Timelock Tests
    ////////////////////////////////////////////////////////////////////////

    struct _TestTimelockBasicFlowTemps {
        PassKey timelockKey;
        IthacaAccount.Key key;
        ERC7821.Call[] authCalls;
        ERC7821.Call[] timelockCalls;
        uint256 nonce;
        uint256 timelockNonce;
        bytes32 keyHash;
        uint256 preTimelockCount;
        IthacaAccount.Timelocker timelocker;
    }

    function testTimelockBasicFlow() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        _TestTimelockBasicFlowTemps memory t;
        
        // Create a key with timelock
        t.timelockKey = _randomSecp256r1PassKey();
        // Set the timelock field in the generated key
        t.timelockKey.k.timelock = 3600; // 1 hour timelock
        t.key = t.timelockKey.k;

        // Authorize the timelock key
        t.authCalls = new ERC7821.Call[](1);
        t.authCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.authorize.selector, t.key)
        });

        t.nonce = d.d.getNonce(0);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(t.authCalls, abi.encodePacked(t.nonce, _sig(d, d.d.computeDigest(t.authCalls, t.nonce)))));

        // Verify key was added
        assertEq(d.d.keyCount(), 1, "Key should be added");
        t.keyHash = d.d.hash(t.key);
        IthacaAccount.Key memory retrievedKey = d.d.getKey(t.keyHash);
        assertEq(retrievedKey.timelock, 3600, "Timelock should be set");

        // Now try to execute with the timelock key - should create timelock
        t.timelockCalls = new ERC7821.Call[](1);
        t.timelockCalls[0] = _thisTargetFunctionCall(0.1 ether, "timelock test");

        t.timelockNonce = d.d.getNonce(0);
        t.preTimelockCount = d.d.timelockCount();
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(t.timelockCalls, abi.encodePacked(t.timelockNonce, _sig(t.timelockKey, d.d.computeDigest(t.timelockCalls, t.timelockNonce)))));
        
        // Verify timelock was created
        assertEq(d.d.timelockCount(), t.preTimelockCount + 1, "Timelock should be created");
        
        // Get the created timelock
        bytes32 timelockDigest = d.d.computeDigest(t.timelockCalls, t.timelockNonce);
        t.timelocker = d.d.getTimelock(timelockDigest);
        // The keyHash should be computed based on keyType and publicKey only (not timelock field)
        assertEq(t.timelocker.keyHash, t.keyHash, "Timelock should reference correct key");
        assertEq(t.timelocker.executed, false, "Timelock should not be executed yet");
        assertEq(t.timelocker.readyTimestamp, block.timestamp + 3600, "Ready timestamp should be set correctly");
    }

    function testTimelockExecution() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        // Create a key with short timelock for testing
        PassKey memory timelockKey = _randomSecp256k1PassKey();
        timelockKey.k.isSuperAdmin = true; // Super admin to bypass call restrictions
        timelockKey.k.timelock = 10; // 10 seconds timelock
        IthacaAccount.Key memory key = timelockKey.k;

        // Authorize the key
        ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
        authCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.authorize.selector, key)
        });

        uint256 nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(authCalls, nonce));
        bytes memory opData = abi.encodePacked(nonce, signature);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(authCalls, opData));

        // Create a timelock
        ERC7821.Call[] memory timelockCalls = new ERC7821.Call[](1);
        timelockCalls[0] = _thisTargetFunctionCall(0.1 ether, "timelock execution test");

        uint256 timelockNonce = d.d.getNonce(0);
        bytes memory timelockSignature = _sig(timelockKey, d.d.computeDigest(timelockCalls, timelockNonce));
        bytes memory timelockOpData = abi.encodePacked(timelockNonce, timelockSignature);
        
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(timelockCalls, timelockOpData));
        
        // Verify timelock was created
        assertEq(d.d.timelockCount(), 1, "Timelock should be created");
        
        // Get timelock digest
        bytes32 timelockDigest = d.d.computeDigest(timelockCalls, timelockNonce);
        IthacaAccount.Timelocker memory timelocker = d.d.getTimelock(timelockDigest);
        
        // Try to execute before timelock is ready - should fail
        vm.expectRevert(IthacaAccount.TimelockNotReady.selector);
        d.d.executeTimelock(timelockCalls, timelockNonce);
        
        // Fast forward time to make timelock ready
        vm.warp(block.timestamp + 11);
        
        // Now execution should work
        uint256 preBalance = address(this).balance;
        d.d.executeTimelock(timelockCalls, timelockNonce);
        
        // Verify execution occurred
        assertEq(address(this).balance - preBalance, 0.1 ether, "Execution should transfer value");
        
        // Verify timelock is marked as executed
        timelocker = d.d.getTimelock(timelockDigest);
        assertEq(timelocker.executed, true, "Timelock should be marked as executed");
    }

    function testTimelockErrors() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        
        // Test: Get non-existent timelock
        bytes32 nonExistentDigest = keccak256("non-existent");
        vm.expectRevert(IthacaAccount.TimelockDoesNotExist.selector);
        d.d.getTimelock(nonExistentDigest);
        
        // Test: Execute non-existent timelock with dummy calls
        ERC7821.Call[] memory dummyCalls = new ERC7821.Call[](1);
        dummyCalls[0] = _thisTargetFunctionCall(0.1 ether, "dummy");
        vm.expectRevert(IthacaAccount.TimelockDoesNotExist.selector);
        d.d.executeTimelock(dummyCalls, 12345);
    }

    function testTimelockDoubleExecution() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        // Create and authorize timelock key
        PassKey memory timelockKey = _randomSecp256k1PassKey();
        timelockKey.k.isSuperAdmin = true; // Super admin to bypass call restrictions
        timelockKey.k.timelock = 1; // 1 second for quick test
        IthacaAccount.Key memory key = timelockKey.k;

        ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
        authCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.authorize.selector, key)
        });

        uint256 nonce = d.d.getNonce(0);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(authCalls, abi.encodePacked(nonce, _sig(d, d.d.computeDigest(authCalls, nonce)))));

        // Create timelock
        ERC7821.Call[] memory timelockCalls = new ERC7821.Call[](1);
        timelockCalls[0] = _thisTargetFunctionCall(0.1 ether, "double execution test");

        uint256 timelockNonce = d.d.getNonce(0);
        bytes memory timelockSig = _sig(timelockKey, d.d.computeDigest(timelockCalls, timelockNonce));
        
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(timelockCalls, abi.encodePacked(timelockNonce, timelockSig)));
        
        bytes32 digest = d.d.computeDigest(timelockCalls, timelockNonce);
        
        // Wait for timelock to be ready and execute once
        vm.warp(block.timestamp + 2);
        d.d.executeTimelock(timelockCalls, timelockNonce);
        
        // Try to execute again - should fail
        vm.expectRevert(IthacaAccount.TimelockAlreadyExecuted.selector);
        d.d.executeTimelock(timelockCalls, timelockNonce);
    }

    function testTimelockEnumeration() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        // Create timelock key
        PassKey memory timelockKey = _randomSecp256r1PassKey();
        IthacaAccount.Key memory key = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.P256,
            isSuperAdmin: false,
            timelock: 3600,
            publicKey: timelockKey.k.publicKey
        });

        // Authorize key
        ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
        authCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.authorize.selector, key)
        });

        uint256 nonce = d.d.getNonce(0);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(authCalls, abi.encodePacked(nonce, _sig(d, d.d.computeDigest(authCalls, nonce)))));

        // Create multiple timelocks
        uint256 numTimelocks = 3;
        for (uint256 i = 0; i < numTimelocks; i++) {
            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _thisTargetFunctionCall(0.01 ether, abi.encodePacked("timelock", i));

            uint256 tlNonce = d.d.getNonce(0);
            bytes memory tlSig = _sig(timelockKey, d.d.computeDigest(calls, tlNonce));
            
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
                abi.encode(calls, abi.encodePacked(tlNonce, tlSig)));
        }

        // Verify timelock count
        assertEq(d.d.timelockCount(), numTimelocks, "Should have created correct number of timelocks");

        // Test enumeration
        for (uint256 i = 0; i < numTimelocks; i++) {
            IthacaAccount.Timelocker memory timelocker = d.d.timelockAt(i);
            assertEq(timelocker.executed, false, "All timelocks should be unexecuted");
            assertEq(timelocker.keyHash, d.d.hash(key), "All timelocks should reference same key");
        }
    }

    function testZeroTimelockExecutesImmediately() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        // Create key with zero timelock  
        PassKey memory key = _randomSecp256k1PassKey();
        key.k.isSuperAdmin = true; // Super admin to bypass call restrictions
        key.k.timelock = 0; // No timelock
        IthacaAccount.Key memory zeroTimelockKey = key.k;

        // Authorize key
        ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
        authCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.authorize.selector, zeroTimelockKey)
        });

        uint256 nonce = d.d.getNonce(0);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(authCalls, abi.encodePacked(nonce, _sig(d, d.d.computeDigest(authCalls, nonce)))));

        // Execute with zero timelock key - should execute immediately
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = _thisTargetFunctionCall(0.1 ether, "immediate execution");

        uint256 executionNonce = d.d.getNonce(0);
        bytes memory sig = _sig(key, d.d.computeDigest(calls, executionNonce));
        
        uint256 preBalance = address(this).balance;
        uint256 preTimelockCount = d.d.timelockCount();
        
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(calls, abi.encodePacked(executionNonce, sig)));
        
        // Verify immediate execution (no timelock created)
        assertEq(address(this).balance - preBalance, 0.1 ether, "Should execute immediately");
        assertEq(d.d.timelockCount(), preTimelockCount, "No timelock should be created");
    }

    function testTimelockWithExpiredKey() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        // Create key that will expire soon
        PassKey memory timelockKey = _randomSecp256k1PassKey();
        timelockKey.k.expiry = uint40(block.timestamp + 5); // Expires in 5 seconds
        timelockKey.k.isSuperAdmin = true; // Super admin to bypass call restrictions
        timelockKey.k.timelock = 10; // 10 second timelock
        IthacaAccount.Key memory key = timelockKey.k;

        // Authorize the key
        ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
        authCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.authorize.selector, key)
        });

        uint256 nonce = d.d.getNonce(0);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(authCalls, abi.encodePacked(nonce, _sig(d, d.d.computeDigest(authCalls, nonce)))));

        // Create timelock before key expires
        ERC7821.Call[] memory timelockCalls = new ERC7821.Call[](1);
        timelockCalls[0] = _thisTargetFunctionCall(0.1 ether, "expired key timelock");

        uint256 timelockNonce = d.d.getNonce(0);
        bytes memory timelockSig = _sig(timelockKey, d.d.computeDigest(timelockCalls, timelockNonce));
        
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(timelockCalls, abi.encodePacked(timelockNonce, timelockSig)));
        
        assertEq(d.d.timelockCount(), 1, "Timelock should be created");
        
        bytes32 digest = d.d.computeDigest(timelockCalls, timelockNonce);
        
        // Wait for key to expire but timelock to be ready
        vm.warp(block.timestamp + 12);
        
        // Timelock should still be executable even though key expired after creation
        d.d.executeTimelock(timelockCalls, timelockNonce);
        
        IthacaAccount.Timelocker memory timelocker = d.d.getTimelock(digest);
        assertEq(timelocker.executed, true, "Timelock should execute successfully");
    }

    function testTimelockContextKeyHash() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        // Create timelock key
        PassKey memory timelockKey = _randomSecp256k1PassKey();
        timelockKey.k.isSuperAdmin = true; // Super admin to bypass call restrictions
        timelockKey.k.timelock = 1; // 1 second for quick test
        IthacaAccount.Key memory key = timelockKey.k;

        // Authorize key
        ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
        authCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.authorize.selector, key)
        });

        uint256 nonce = d.d.getNonce(0);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(authCalls, abi.encodePacked(nonce, _sig(d, d.d.computeDigest(authCalls, nonce)))));

        bytes32 expectedKeyHash = d.d.hash(key);

        // Create a call that checks the context key hash
        ERC7821.Call[] memory contextCalls = new ERC7821.Call[](1);
        contextCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.getContextKeyHash.selector)
        });

        uint256 contextNonce = d.d.getNonce(0);
        bytes memory contextSig = _sig(timelockKey, d.d.computeDigest(contextCalls, contextNonce));
        
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(contextCalls, abi.encodePacked(contextNonce, contextSig)));
        
        bytes32 digest = d.d.computeDigest(contextCalls, contextNonce);
        
        // Wait for timelock and execute
        vm.warp(block.timestamp + 2);
        d.d.executeTimelock(contextCalls, contextNonce);
        
        // Verify timelock execution
        IthacaAccount.Timelocker memory timelocker = d.d.getTimelock(digest);
        assertEq(timelocker.executed, true, "Timelock should be executed");
        assertEq(timelocker.keyHash, expectedKeyHash, "Timelock should store correct key hash");
    }

    function testFuzz_TimelockValues(uint40 timelockSeconds) public {
        vm.assume(timelockSeconds > 0 && timelockSeconds <= 365 days); // Reasonable timelock range
        
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        // Create key with fuzzed timelock
        PassKey memory timelockKey = _randomSecp256k1PassKey();
        timelockKey.k.isSuperAdmin = true; // Super admin to bypass call restrictions
        timelockKey.k.timelock = timelockSeconds;
        IthacaAccount.Key memory key = timelockKey.k;

        // Authorize key
        ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
        authCalls[0] = ERC7821.Call({
            to: address(d.d),
            value: 0,
            data: abi.encodeWithSelector(IthacaAccount.authorize.selector, key)
        });

        uint256 nonce = d.d.getNonce(0);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(authCalls, abi.encodePacked(nonce, _sig(d, d.d.computeDigest(authCalls, nonce)))));

        // Create timelock
        ERC7821.Call[] memory timelockCalls = new ERC7821.Call[](1);
        timelockCalls[0] = _thisTargetFunctionCall(0.01 ether, "fuzz test");

        uint256 timelockNonce = d.d.getNonce(0);
        bytes memory timelockSig = _sig(timelockKey, d.d.computeDigest(timelockCalls, timelockNonce));
        
        uint256 creationTime = block.timestamp;
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, 
            abi.encode(timelockCalls, abi.encodePacked(timelockNonce, timelockSig)));
        
        // Verify timelock created with correct ready timestamp
        bytes32 digest = d.d.computeDigest(timelockCalls, timelockNonce);
        IthacaAccount.Timelocker memory timelocker = d.d.getTimelock(digest);
        
        assertEq(timelocker.executed, false, "Timelock should not be executed yet");
        assertEq(timelocker.readyTimestamp, creationTime + timelockSeconds, "Ready timestamp should match timelock delay");
        
        // Try to execute before ready - should fail
        vm.expectRevert(IthacaAccount.TimelockNotReady.selector);
        d.d.executeTimelock(timelockCalls, timelockNonce);
        
        // Fast forward to exactly ready time
        vm.warp(creationTime + timelockSeconds);
        
        // Should succeed at exact ready time
        d.d.executeTimelock(timelockCalls, timelockNonce);
        
        timelocker = d.d.getTimelock(digest);
        assertEq(timelocker.executed, true, "Timelock should be executed");
    }
}
