// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./Base.t.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";

/// @title SubAccounts Test Suite
/// @notice Tests the parent-child account architecture with spending permissions
contract SubAccountsTest is BaseTest {
    using SafeTransferLib for address;

    // Main account (parent) - controlled by user
    DelegatedEOA mainAccount;
    PassKey mainAccountKey;

    // Sub account (child) - controlled by DApp
    DelegatedEOA subAccount;
    PassKey dappKey;

    // Test tokens
    MockPaymentToken usdc;
    MockPaymentToken dai;

    // DApp that controls the sub account
    address dappAddress;
    address constant dappRecipient = address(0xDA99);

    // Spend IDs for tracking permissions
    uint256 constant PARENT_SWEEP_SPEND_ID = 1;
    uint256 constant CHILD_PULL_SPEND_ID = 2;

    function setUp() public override {
        super.setUp();

        // Setup tokens
        usdc = new MockPaymentToken();
        dai = new MockPaymentToken();

        // Setup main account (parent)
        mainAccount = _randomEIP7702DelegatedEOA();
        mainAccountKey = _randomPassKey();
        mainAccountKey.k.isSuperAdmin = true; // Main account key needs to be super admin to call setSpend
        vm.prank(address(mainAccount.d));
        mainAccount.d.authorize(mainAccountKey.k);

        // Setup sub account (controlled by DApp)
        subAccount = _randomEIP7702DelegatedEOA();
        dappKey = _randomPassKey();
        dappKey.k.isSuperAdmin = true; // DApp has full control of sub account
        vm.prank(address(subAccount.d));
        subAccount.d.authorize(dappKey.k);

        // Setup DApp address
        dappAddress = vm.addr(uint256(keccak256("dapp")));
    }

    /// @notice Tests the complete subaccount flow with DApp integration
    /// Flow:
    /// 1. Create main account with funds
    /// 2. Create sub account (controlled by DApp, no initial funds needed)
    /// 3. Sub account grants parent sweep permission
    /// 4. Main account grants sub account limited pull permission
    /// 5. DApp executes bundle: pulls funds from main, sends to DApp
    /// 6. Parent can sweep remaining funds back
    function test_CompleteSubAccountFlowWithDApp() public {
        // ============================================
        // STEP 1: Fund the main account
        // ============================================
        uint256 mainAccountInitialBalance = 1000e6; // 1000 USDC
        usdc.mint(address(mainAccount.eoa), mainAccountInitialBalance);
        dai.mint(address(mainAccount.eoa), 500e18); // 500 DAI

        assertEq(usdc.balanceOf(address(mainAccount.eoa)), mainAccountInitialBalance);
        assertEq(dai.balanceOf(address(mainAccount.eoa)), 500e18);

        // Sub account starts with 0 funds (DApp pays for gas)
        assertEq(usdc.balanceOf(address(subAccount.eoa)), 0);

        // ============================================
        // STEP 2: Sub account grants parent sweep permission
        // This allows parent to recover any funds from sub account
        // ============================================
        {
            // Create setSpend call to grant parent sweep permission
            ERC7821.Call[] memory calls = new ERC7821.Call[](1);

            calls[0] = ERC7821.Call({
                to: address(subAccount.d), // Call to self
                value: 0,
                data: abi.encodeWithSelector(
                    IthacaAccount.setSpend.selector,
                    PARENT_SWEEP_SPEND_ID,
                    true, // isParent = true (can sweep everything)
                    uint32(0), // No expiry for parent
                    address(mainAccount.eoa), // Parent is the spender
                    new address[](0), // Tokens are ignored, because parent can sweep everything
                    new uint256[](0) // Limits are ignored, because parent can sweep everything
                )
            });

            // Execute as the subAccount EOA directly (no signature needed)
            vm.prank(subAccount.eoa);
            subAccount.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls));
        }

        // ============================================
        // STEP 3: Main account grants sub account limited pull permission
        // This allows sub account to pull up to 100 USDC and 50 DAI
        // ============================================
        {
            // Create setSpend call to grant sub account limited permission
            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            address[] memory tokens = new address[](2);
            tokens[0] = address(usdc);
            tokens[1] = address(dai);
            uint256[] memory limits = new uint256[](2);
            limits[0] = 100e6; // 100 USDC limit
            limits[1] = 50e18; // 50 DAI limit

            calls[0] = ERC7821.Call({
                to: address(mainAccount.d), // Call to self
                value: 0,
                data: abi.encodeWithSelector(
                    IthacaAccount.setSpend.selector,
                    CHILD_PULL_SPEND_ID,
                    false, // isParent = false (limited permissions)
                    uint32(block.timestamp + 30 days), // 30 day expiry
                    address(subAccount.eoa), // Sub account is the spender
                    tokens,
                    limits
                )
            });

            // Execute as the mainAccount EOA directly (no signature needed)
            vm.prank(mainAccount.eoa);
            mainAccount.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls));
        }

        // ============================================
        // STEP 4: Test direct spend call from subAccount to mainAccount
        // ============================================
        uint256 amountToPull = 50e6; // 50 USDC
        {
            // SubAccount calls spend on mainAccount directly
            address[] memory pullTokens = new address[](1);
            pullTokens[0] = address(usdc);
            uint256[] memory pullAmounts = new uint256[](1);
            pullAmounts[0] = amountToPull;

            vm.prank(subAccount.eoa);
            mainAccount.d.spend(
                CHILD_PULL_SPEND_ID, pullTokens, pullAmounts, address(subAccount.eoa)
            );

            // Verify the transfer worked
            assertEq(
                usdc.balanceOf(address(mainAccount.eoa)), mainAccountInitialBalance - amountToPull
            );
            assertEq(usdc.balanceOf(address(subAccount.eoa)), amountToPull);
        }

        // ============================================
        // STEP 5: DApp executes bundle via sub account
        // - Pulls more funds from main account
        // - Then sends to DApp recipient
        // ============================================
        uint256 secondPullAmount = 30e6; // 30 USDC
        {
            Orchestrator.Intent memory intent;
            intent.eoa = address(subAccount.eoa);
            intent.nonce = subAccount.d.getNonce(0);
            intent.expiry = block.timestamp + 1 days;
            intent.paymentToken = address(paymentToken);
            intent.paymentAmount = 0 ether;
            intent.paymentRecipient = address(0xfee);
            intent.combinedGas = 1000000;

            // Create bundle: pull from main, then send to DApp
            ERC7821.Call[] memory calls = new ERC7821.Call[](2);

            address[] memory pullTokens = new address[](1);
            pullTokens[0] = address(usdc);
            uint256[] memory pullAmounts = new uint256[](1);
            pullAmounts[0] = secondPullAmount;

            calls[0] = ERC7821.Call({
                to: address(mainAccount.d),
                value: 0,
                data: abi.encodeWithSelector(
                    IthacaAccount.spend.selector,
                    CHILD_PULL_SPEND_ID,
                    pullTokens,
                    pullAmounts,
                    address(subAccount.eoa)
                )
            });

            // Send all funds to DApp (first pull + second pull)
            calls[1] = ERC7821.Call({
                to: address(usdc),
                value: 0,
                data: abi.encodeWithSelector(
                    ERC20.transfer.selector, dappRecipient, amountToPull + secondPullAmount
                )
            });

            intent.executionData = abi.encode(calls);
            intent.signature = _sig(dappKey, intent);

            // Execute the bundle
            assertEq(oc.execute(abi.encode(intent)), 0);

            // Verify balances
            assertEq(
                usdc.balanceOf(address(mainAccount.eoa)),
                mainAccountInitialBalance - amountToPull - secondPullAmount
            );
            assertEq(usdc.balanceOf(address(subAccount.eoa)), 0);
            assertEq(usdc.balanceOf(dappRecipient), amountToPull + secondPullAmount);
        }

        // ============================================
        // STEP 6: Test that sub account cannot exceed limits (should fail)
        // ============================================
        {
            // Try to pull 21 more USDC (total would be 50+30+21 = 101, exceeding 100 limit)
            address[] memory pullTokens = new address[](1);
            pullTokens[0] = address(usdc);
            uint256[] memory pullAmounts = new uint256[](1);
            pullAmounts[0] = 21e6; // This would exceed the 100 USDC limit

            // Should revert due to exceeding limit
            vm.prank(subAccount.eoa);
            vm.expectRevert();
            mainAccount.d.spend(
                CHILD_PULL_SPEND_ID, pullTokens, pullAmounts, address(subAccount.eoa)
            );
        }

        // // ============================================
        // // STEP 7: Parent sweeps funds back from sub account
        // // ============================================
        {
            // Parent can sweep everything from sub account
            address[] memory sweepTokens = new address[](1);
            sweepTokens[0] = address(usdc);
            uint256[] memory sweepAmounts = new uint256[](1);
            sweepAmounts[0] = usdc.balanceOf(address(subAccount.eoa));

            uint256 mainAccountPreBalance = usdc.balanceOf(address(mainAccount.eoa));

            // Parent directly calls spend on sub account
            vm.prank(mainAccount.eoa);
            subAccount.d.spend(
                PARENT_SWEEP_SPEND_ID,
                sweepTokens,
                sweepAmounts,
                address(mainAccount.eoa) // Sweep back to parent
            );

            // Verify parent recovered all the funds
            assertEq(usdc.balanceOf(address(subAccount.eoa)), 0);
            assertEq(
                usdc.balanceOf(address(mainAccount.eoa)), mainAccountPreBalance + sweepAmounts[0]
            );
        }
    }
}
