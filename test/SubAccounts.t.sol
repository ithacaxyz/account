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

    function testJITPullFromMainWithERC20() public {
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

        // Create a non-super admin key for the main account with spend limit
        PassKey memory spendLimitKey = _randomSecp256k1PassKey();
        spendLimitKey.k.isSuperAdmin = false;
        spendLimitKey.k.expiry = uint40(block.timestamp + 1 days);

        // Main account authorizes the spend limit key
        vm.prank(mainAccount.eoa);
        mainAccount.d.authorize(spendLimitKey.k);

        // Set 1000 token spend limit for ERC20 token
        vm.prank(mainAccount.eoa);
        mainAccount.d.setSpendLimit(
            spendLimitKey.keyHash,
            address(paymentToken),
            GuardedExecutor.SpendPeriod.Day,
            1000e18 // 1000 tokens with 18 decimals
        );

        // Main account approves the subAccount to use the spend limit key
        vm.prank(mainAccount.eoa);
        mainAccount.d.setSubAccountApproval(spendLimitKey.keyHash, subAccount.eoa, true);

        // Grant the spend limit key permission to transfer tokens to subaccount
        vm.prank(mainAccount.eoa);
        mainAccount.d.setCanExecute(
            spendLimitKey.keyHash, address(paymentToken), ERC20.transfer.selector, true
        );

        // Fund the main account with tokens
        paymentToken.mint(mainAccount.eoa, 10000e18); // 10,000 tokens
        assertEq(paymentToken.balanceOf(mainAccount.eoa), 10000e18);
        assertEq(paymentToken.balanceOf(subAccount.eoa), 0);

        // Create a P256 session key for the DApp
        PassKey memory dappKey = _randomSecp256r1PassKey();
        dappKey.k.isSuperAdmin = false;
        dappKey.k.expiry = uint40(block.timestamp + 1 days);

        // Create a DApp address to receive funds
        address dappAddress = address(0xDABB);

        // SubAccount atomically:
        // 1. Authorizes the P256 session key
        // 2. Grants permission to call execute on main account (needed for JIT pull)
        // 3. Grants permission to transfer tokens
        // 4. Set spend limit for the DApp key to allow token transfers
        ERC7821.Call[] memory subAccountSetupCalls = new ERC7821.Call[](4);

        subAccountSetupCalls[0] = ERC7821.Call({
            to: subAccount.eoa,
            value: 0,
            data: abi.encodeWithSelector(subAccount.d.authorize.selector, dappKey.k)
        });

        subAccountSetupCalls[1] = ERC7821.Call({
            to: subAccount.eoa,
            value: 0,
            data: abi.encodeWithSelector(
                subAccount.d.setCanExecute.selector,
                dappKey.keyHash,
                mainAccount.eoa,
                ERC7821.execute.selector,
                true
            )
        });

        subAccountSetupCalls[2] = ERC7821.Call({
            to: subAccount.eoa,
            value: 0,
            data: abi.encodeWithSelector(
                subAccount.d.setCanExecute.selector,
                dappKey.keyHash,
                address(paymentToken),
                ERC20.transfer.selector,
                true
            )
        });

        subAccountSetupCalls[3] = ERC7821.Call({
            to: subAccount.eoa,
            value: 0,
            data: abi.encodeWithSelector(
                subAccount.d.setSpendLimit.selector,
                dappKey.keyHash,
                address(paymentToken),
                GuardedExecutor.SpendPeriod.Day,
                1000e18 // 1000 tokens
            )
        });

        ICommon.Intent memory setupIntent;
        setupIntent.eoa = subAccount.eoa;
        setupIntent.combinedGas = 500_000;
        setupIntent.executionData = abi.encode(subAccountSetupCalls);
        setupIntent.nonce = 0;

        // Sign with main account's key and wrap with external key hash
        bytes32 externalKeyHash = _hash(externalKey);
        bytes memory setupSig = _sig(mainKey, oc.computeDigest(setupIntent));
        setupIntent.signature = abi.encodePacked(setupSig, externalKeyHash, uint8(0));

        // Execute the setup
        assertEq(oc.execute(false, abi.encode(setupIntent)), 0);

        // Now the DApp wants to deposit 500 tokens somewhere
        // The subaccount will JIT pull tokens from main account and then deposit

        // First, create the inner call for main account to transfer tokens to subaccount
        ERC7821.Call[] memory mainAccountCalls = new ERC7821.Call[](1);
        mainAccountCalls[0] = ERC7821.Call({
            to: address(paymentToken),
            value: 0,
            data: abi.encodeWithSelector(ERC20.transfer.selector, subAccount.eoa, 500e18)
        });

        // Encode the main account execute call with nonce and signature
        // NOTE: In this case, for complete protection this requires 2 signatures.
        // There are alternatives where the dapp session key is given direct transfer permission
        // to the sub account. But this requires a session key that can check the calldata.
        bytes memory mainAccountExecuteData = abi.encodePacked(
            uint256(0), // nonce for main account
            _sig(spendLimitKey, mainAccount.d.computeDigest(mainAccountCalls, 0))
        );

        // Create the subaccount's execution bundle
        ERC7821.Call[] memory subAccountCalls = new ERC7821.Call[](2);

        // First call: Pull funds from main account using the spend limit key
        subAccountCalls[0] = ERC7821.Call({
            to: mainAccount.eoa,
            value: 0,
            data: abi.encodeWithSelector(
                ERC7821.execute.selector,
                _ERC7821_BATCH_EXECUTION_MODE, // mode
                abi.encode(mainAccountCalls, mainAccountExecuteData) // executionData
            )
        });

        // Second call: Transfer tokens to DApp
        subAccountCalls[1] = ERC7821.Call({
            to: address(paymentToken),
            value: 0,
            data: abi.encodeWithSelector(ERC20.transfer.selector, dappAddress, 500e18)
        });

        ICommon.Intent memory depositIntent;
        depositIntent.eoa = subAccount.eoa;
        depositIntent.combinedGas = 500_000;
        depositIntent.executionData = abi.encode(subAccountCalls);
        depositIntent.nonce = 1;

        // DApp signs with its P256 session key
        depositIntent.signature = _sig(dappKey, depositIntent);

        // Execute the JIT pull and deposit
        assertEq(oc.execute(false, abi.encode(depositIntent)), 0);

        // Verify the tokens moved correctly
        assertEq(paymentToken.balanceOf(mainAccount.eoa), 9500e18); // 10000 - 500
        assertEq(paymentToken.balanceOf(subAccount.eoa), 0);
        assertEq(paymentToken.balanceOf(dappAddress), 500e18);

        // Try to pull more than the spend limit (should fail)
        mainAccountCalls[0] = ERC7821.Call({
            to: address(paymentToken),
            value: 0,
            data: abi.encodeWithSelector(ERC20.transfer.selector, subAccount.eoa, 600e18) // Exceeds remaining daily limit
        });

        mainAccountExecuteData = abi.encodePacked(
            uint256(1), // nonce for main account
            _sig(spendLimitKey, mainAccount.d.computeDigest(mainAccountCalls, 1))
        );

        subAccountCalls[0] = ERC7821.Call({
            to: mainAccount.eoa,
            value: 0,
            data: abi.encodeWithSelector(
                ERC7821.execute.selector,
                _ERC7821_BATCH_EXECUTION_MODE,
                abi.encode(mainAccountCalls, mainAccountExecuteData)
            )
        });

        subAccountCalls[1] = ERC7821.Call({
            to: address(paymentToken),
            value: 0,
            data: abi.encodeWithSelector(ERC20.transfer.selector, dappAddress, 600e18)
        });

        depositIntent.executionData = abi.encode(subAccountCalls);
        depositIntent.nonce = 2;
        depositIntent.signature = _sig(dappKey, depositIntent);

        // This should fail due to exceeding spend limit
        assertEq(
            oc.execute(false, abi.encode(depositIntent)),
            bytes4(keccak256("ExceededSpendLimit(address)"))
        );

        // Verify no additional tokens were moved
        assertEq(paymentToken.balanceOf(mainAccount.eoa), 9500e18);
        assertEq(paymentToken.balanceOf(subAccount.eoa), 0);
        assertEq(paymentToken.balanceOf(dappAddress), 500e18);
    }
}
