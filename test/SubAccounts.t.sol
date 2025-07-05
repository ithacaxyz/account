// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./Base.t.sol";
import {MockAccount} from "./utils/mocks/MockAccount.sol";
import {MockCounter} from "./utils/mocks/MockCounter.sol";
import {ICommon} from "../src/interfaces/ICommon.sol";

/// @title SubAccountsTest
/// @notice Tests for Porto account subAccount functionality
/// @dev Demonstrates how a subAccount can be created with an external key pointing to the main account
contract SubAccountsTest is BaseTest {
    DelegatedEOA mainAccount;
    DelegatedEOA subAccount;
    MockCounter counter;

    // Key for the main account
    PassKey mainKey;

    // AI agent key (non-super admin)
    PassKey dappSessionKey;

    function setUp() public override {
        super.setUp();

        mainAccount = _randomEIP7702DelegatedEOA();
        subAccount = _randomEIP7702DelegatedEOA();

        mainKey = _randomSecp256k1PassKey();
        mainKey.k.isSuperAdmin = true;

        vm.prank(mainAccount.eoa);
        mainAccount.d.authorize(mainKey.k);

        // Deploy a counter contract for testing function selectors
        counter = new MockCounter();
    }

    function testMovingFundsToAndFromSubAccount() public {
        // Create an external key for the subAccount that points to the main account
        IthacaAccount.Key memory externalKey = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true, // This external key is a super admin
            publicKey: abi.encodePacked(mainAccount.eoa, bytes12(0))
        });

        vm.prank(subAccount.eoa);
        subAccount.d.authorize(externalKey);

        // Verify the key was authorized
        IthacaAccount.Key memory retrievedKey = subAccount.d.getKey(_hash(externalKey));
        assertEq(uint8(retrievedKey.keyType), uint8(IthacaAccount.KeyType.External));
        assertEq(address(bytes20(retrievedKey.publicKey)), mainAccount.eoa);
        assertTrue(retrievedKey.isSuperAdmin);

        // Fund the main account
        vm.deal(mainAccount.eoa, 10 ether);
        assertEq(mainAccount.eoa.balance, 10 ether);

        // Main account sends money to the subAccount (signed by main account key)
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({to: subAccount.eoa, value: 1 ether, data: ""});

        ICommon.Intent memory intent;
        intent.eoa = mainAccount.eoa;
        intent.combinedGas = 300_000;
        intent.executionData = abi.encode(calls);

        // Sign with main account's key
        intent.signature = _sig(mainKey, intent);

        // Execute the transfer
        assertEq(oc.execute(false, abi.encode(intent)), 0);

        // Verify the transfer
        assertEq(subAccount.eoa.balance, 1 ether);
        assertEq(mainAccount.eoa.balance, 9 ether);

        // Example: SubAccount will send 0.5 ETH back using main account's signature via external key
        ERC7821.Call[] memory subAccountCalls = new ERC7821.Call[](1);
        subAccountCalls[0] = ERC7821.Call({to: mainAccount.eoa, value: 0.5 ether, data: ""});

        ICommon.Intent memory subAccountIntent;
        subAccountIntent.eoa = subAccount.eoa;
        subAccountIntent.combinedGas = 300_000;
        subAccountIntent.executionData = abi.encode(subAccountCalls);

        // The signature should be created with the main account's key
        // and wrapped with the external key hash
        bytes32 externalKeyHash = _hash(externalKey);

        // Create a signature using the main account's key for the subaccount's intent
        bytes memory mainAccountSig = _sig(mainKey, oc.computeDigest(subAccountIntent));

        // The signature format for the subaccount is: innerSignature + keyHash + prehash
        // where keyHash is the external key hash
        subAccountIntent.signature = abi.encodePacked(mainAccountSig, externalKeyHash, uint8(0));

        // This should fail because subAccount is not approved on the main account to use themainKey yet.
        assertEq(
            oc.execute(false, abi.encode(subAccountIntent)),
            bytes4(keccak256("VerificationError()"))
        );

        // Verify no transfer happened
        assertEq(subAccount.eoa.balance, 1 ether);
        assertEq(mainAccount.eoa.balance, 9 ether);

        // Now approve the subAccount to use the main account's key
        vm.prank(mainAccount.eoa);
        mainAccount.d.setSubAccountApproval(mainKey.keyHash, subAccount.eoa, true);

        // Execute the transfer from subAccount using main account's signature
        assertEq(oc.execute(false, abi.encode(subAccountIntent)), 0);

        // Verify the transfer happened
        assertEq(subAccount.eoa.balance, 0.5 ether);
        assertEq(mainAccount.eoa.balance, 9.5 ether);
    }

    function testDAppSessionKeyWithSubAccount() public {
        // Create an external key for the subAccount that points to the main account
        IthacaAccount.Key memory externalKey = IthacaAccount.Key({
            expiry: 0,
            keyType: IthacaAccount.KeyType.External,
            isSuperAdmin: true, // This external key is a super admin
            publicKey: abi.encodePacked(mainAccount.eoa, bytes12(0))
        });

        // Authorize the external key on the subaccount
        vm.prank(subAccount.eoa);
        subAccount.d.authorize(externalKey);

        // Main account approves the subAccount to use the main account's key
        vm.prank(mainAccount.eoa);
        mainAccount.d.setSubAccountApproval(mainKey.keyHash, subAccount.eoa, true);

        // Create a P256 session key for the DApp (non-super admin)
        dappSessionKey = _randomSecp256r1PassKey();
        dappSessionKey.k.isSuperAdmin = false;
        dappSessionKey.k.expiry = uint40(block.timestamp + 1 days); // Session key expires in 1 day

        // Atomically authorize the P256 session key and grant it permission to call increment
        // This is done via the main account's external key
        ERC7821.Call[] memory setupCalls = new ERC7821.Call[](2);

        // First call: authorize the P256 session key
        setupCalls[0] = ERC7821.Call({
            to: subAccount.eoa,
            value: 0,
            data: abi.encodeWithSelector(subAccount.d.authorize.selector, dappSessionKey.k)
        });

        // Second call: grant permission to only call increment on counter
        setupCalls[1] = ERC7821.Call({
            to: subAccount.eoa,
            value: 0,
            data: abi.encodeWithSelector(
                subAccount.d.setCanExecute.selector,
                dappSessionKey.keyHash,
                address(counter),
                MockCounter.increment.selector,
                true
            )
        });

        ICommon.Intent memory setupIntent;
        setupIntent.eoa = subAccount.eoa;
        setupIntent.combinedGas = 300_000;
        setupIntent.executionData = abi.encode(setupCalls);
        setupIntent.nonce = 0;

        // Sign with main account's key and wrap with external key hash
        bytes32 externalKeyHash = _hash(externalKey);
        bytes memory mainAccountSig = _sig(mainKey, oc.computeDigest(setupIntent));
        setupIntent.signature = abi.encodePacked(mainAccountSig, externalKeyHash, uint8(0));

        // Execute both authorization and permission grant atomically
        assertEq(oc.execute(false, abi.encode(setupIntent)), 0);

        // Verify initial counter state
        assertEq(counter.counter(), 0);

        // Create Dapp call to increment counter
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0] = ERC7821.Call({
            to: address(counter),
            value: 0,
            data: abi.encodeWithSelector(MockCounter.increment.selector)
        });

        // Create intent from subAccount
        ICommon.Intent memory intent;
        intent.eoa = subAccount.eoa;
        intent.combinedGas = 300_000;
        intent.executionData = abi.encode(calls);
        intent.nonce = 1;

        // DApp signs with the P256 session key
        intent.signature = _sig(dappSessionKey, intent);

        // Execute the increment call
        assertEq(oc.execute(false, abi.encode(intent)), 0);

        // Verify counter was incremented
        assertEq(counter.counter(), 1);

        // Verify the session key cannot call decrement (no permission)
        ERC7821.Call[] memory decrementCalls = new ERC7821.Call[](1);
        decrementCalls[0] = ERC7821.Call({
            to: address(counter),
            value: 0,
            data: abi.encodeWithSelector(MockCounter.decrement.selector)
        });

        ICommon.Intent memory decrementIntent;
        decrementIntent.eoa = subAccount.eoa;
        decrementIntent.combinedGas = 300_000;
        decrementIntent.executionData = abi.encode(decrementCalls);
        decrementIntent.nonce = 2;

        // Sign with the P256 session key
        decrementIntent.signature = _sig(dappSessionKey, decrementIntent);

        // This should fail as the session key doesn't have permission to call decrement
        assertEq(
            oc.execute(false, abi.encode(decrementIntent)),
            bytes4(keccak256("UnauthorizedCall(bytes32,address,bytes)"))
        );

        // Verify counter is still 1
        assertEq(counter.counter(), 1);

        // Verify the session key can call increment again
        intent.nonce = 3;
        intent.signature = _sig(dappSessionKey, intent);
        assertEq(oc.execute(false, abi.encode(intent)), 0);
        assertEq(counter.counter(), 2);
    }
}
