// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";
import {MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";

contract EscrowTest is BaseTest {
    Escrow escrow;
    SimpleSettler settler;
    MockPaymentToken token;

    address depositor = makeAddr("DEPOSITOR");
    address recipient = makeAddr("RECIPIENT");
    address sender = makeAddr("SENDER");
    address settlerOwner = makeAddr("SETTLER_OWNER");
    address attacker = makeAddr("ATTACKER");
    address randomUser = makeAddr("RANDOM_USER");

    event EscrowCreated(bytes32 escrowId);
    event EscrowRefundedDepositor(bytes32 escrowId);
    event EscrowRefundedRecipient(bytes32 escrowId);
    event EscrowSettled(bytes32 escrowId);

    function setUp() public override {
        super.setUp();

        escrow = new Escrow();
        settler = new SimpleSettler(settlerOwner);
        token = new MockPaymentToken();

        // Fund depositor
        token.mint(depositor, 10000);
        vm.deal(depositor, 10 ether);
    }

    // ========== Basic Positive Tests ==========

    function testBasicEscrowCreation() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = keccak256(abi.encode(escrowData));

        vm.startPrank(depositor);
        token.approve(address(escrow), 1000);

        vm.expectEmit(true, false, false, false);
        emit EscrowCreated(escrowId);

        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
        escrows[0] = escrowData;
        escrow.escrow(escrows);
        vm.stopPrank();

        // Verify state
        assertEq(token.balanceOf(address(escrow)), 1000);
        assertEq(token.balanceOf(depositor), 9000);
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.CREATED));
    }

    function testSettleWithinDeadline() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        // Mark as settled
        vm.prank(settlerOwner);
        settler.write(sender, escrowData.settlementId, 1);

        // Settle within deadline
        vm.expectEmit(true, false, false, false);
        emit EscrowSettled(escrowId);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;
        escrow.settle(escrowIds);

        // Verify full amount goes to recipient
        assertEq(token.balanceOf(recipient), 1000);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.FINALIZED));
    }

    // ========== Refund Flow Tests ==========

    function testDepositorRefundAfterDeadline() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Anyone can call refundDepositor
        vm.prank(randomUser);
        vm.expectEmit(true, false, false, false);
        emit EscrowRefundedDepositor(escrowId);
        escrow.refundDepositor(escrowIds);

        // Verify depositor got refund
        assertEq(token.balanceOf(depositor), 9800); // 10000 - 1000 + 800
        assertEq(token.balanceOf(address(escrow)), 200); // 1000 - 800
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.REFUND_DEPOSIT));
    }

    function testRecipientRefundAfterDeadline() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Anyone can call refundRecipient
        vm.prank(randomUser);
        vm.expectEmit(true, false, false, false);
        emit EscrowRefundedRecipient(escrowId);
        escrow.refundRecipient(escrowIds);

        // Verify recipient got remainder
        assertEq(token.balanceOf(recipient), 200); // 1000 - 800
        assertEq(token.balanceOf(address(escrow)), 800); // Depositor's portion still there
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.REFUND_RECIPIENT));
    }

    function testIndependentRefundsDepositorFirst() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Step 1: Depositor refunds first
        vm.prank(attacker);
        escrow.refundDepositor(escrowIds);
        assertEq(token.balanceOf(depositor), 9800);
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.REFUND_DEPOSIT));

        // Step 2: Recipient can still refund
        vm.prank(randomUser);
        escrow.refundRecipient(escrowIds);
        assertEq(token.balanceOf(recipient), 200);
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.FINALIZED));

        // Verify all funds distributed
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testIndependentRefundsRecipientFirst() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Step 1: Recipient refunds first
        vm.prank(attacker);
        escrow.refundRecipient(escrowIds);
        assertEq(token.balanceOf(recipient), 200);
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.REFUND_RECIPIENT));

        // Step 2: Depositor can still refund
        vm.prank(randomUser);
        escrow.refundDepositor(escrowIds);
        assertEq(token.balanceOf(depositor), 9800);
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.FINALIZED));

        // Verify all funds distributed
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testRefundBothPartiesInOneCall() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Initial balances
        assertEq(token.balanceOf(depositor), 9000);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(escrow)), 1000);

        // Expect both refund events
        vm.expectEmit(true, false, false, false);
        emit EscrowRefundedDepositor(escrowId);
        vm.expectEmit(true, false, false, false);
        emit EscrowRefundedRecipient(escrowId);

        // Call the new refund function that refunds both parties
        vm.prank(randomUser);
        escrow.refund(escrowIds);

        // Verify both parties received their funds
        assertEq(token.balanceOf(depositor), 9800); // 9000 + 800 refund
        assertEq(token.balanceOf(recipient), 200); // 1000 - 800
        assertEq(token.balanceOf(address(escrow)), 0);

        // Verify status is FINALIZED since both refunds happened
        assertEq(uint256(escrow.statuses(escrowId)), uint256(IEscrow.EscrowStatus.FINALIZED));
    }

    // ========== Negative Tests - Timing ==========

    function testCannotRefundBeforeDeadline() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Try depositor refund before deadline
        vm.expectRevert(bytes4(keccak256("RefundInvalid()")));
        escrow.refundDepositor(escrowIds);

        // Try recipient refund before deadline
        vm.expectRevert(bytes4(keccak256("RefundInvalid()")));
        escrow.refundRecipient(escrowIds);

        // Try combined refund before deadline
        vm.expectRevert(bytes4(keccak256("RefundInvalid()")));
        escrow.refund(escrowIds);

        // Verify funds still locked
        assertEq(token.balanceOf(address(escrow)), 1000);
    }

    // ========== Negative Tests - State Machine ==========

    function testCannotDoubleRefundDepositor() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // First refund works
        escrow.refundDepositor(escrowIds);

        // Second refund fails
        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.refundDepositor(escrowIds);
    }

    function testCannotDoubleRefundRecipient() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // First refund works
        escrow.refundRecipient(escrowIds);

        // Second refund fails
        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.refundRecipient(escrowIds);
    }

    function testCannotRefundAfterSettlement() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        // Settle first
        vm.prank(settlerOwner);
        settler.write(sender, escrowData.settlementId, 1);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;
        escrow.settle(escrowIds);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        // Cannot refund after settlement
        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.refundDepositor(escrowIds);

        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.refundRecipient(escrowIds);
    }

    function testCannotRefundFromFinalizedState() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Get to FINALIZED state
        escrow.refundDepositor(escrowIds);
        escrow.refundRecipient(escrowIds);

        // Cannot refund from FINALIZED
        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.refundDepositor(escrowIds);

        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.refundRecipient(escrowIds);
    }

    // ========== Security Tests ==========

    function testRefundAmountGreaterThanEscrowAmount() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 1500); // refund > escrow!

        vm.startPrank(depositor);
        token.approve(address(escrow), 1000);
        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
        escrows[0] = escrowData;

        vm.expectRevert(bytes4(keccak256("InvalidEscrow()")));
        escrow.escrow(escrows);
        vm.stopPrank();
    }

    function testAnyoneCanTriggerRefunds() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Attacker can trigger depositor refund
        vm.prank(attacker);
        escrow.refundDepositor(escrowIds);

        // Random user can trigger recipient refund
        vm.prank(randomUser);
        escrow.refundRecipient(escrowIds);

        // Funds went to correct addresses despite attackers calling
        assertEq(token.balanceOf(depositor), 9800);
        assertEq(token.balanceOf(recipient), 200);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(randomUser), 0);
    }

    function testSettleAfterDeadlineAndRefundBlocking() public {
        // Test 1: CAN settle after deadline if no refunds have occurred
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        vm.prank(settlerOwner);
        settler.write(sender, escrowData.settlementId, 1);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Settlement SHOULD SUCCEED after deadline if no refunds have occurred
        escrow.settle(escrowIds);
        assertEq(token.balanceOf(recipient), 1000);

        // Test 2: Cannot settle after partial refund (depositor only)
        escrowData.salt = bytes12(uint96(2));
        escrowId = _createAndFundEscrow(escrowData);

        vm.prank(settlerOwner);
        settler.write(sender, escrowData.settlementId, 1);

        escrowIds[0] = escrowId;
        escrow.refundDepositor(escrowIds);

        // Settlement should fail after depositor refund
        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.settle(escrowIds);

        // Test 3: Cannot settle after partial refund (recipient only)
        escrowData.salt = bytes12(uint96(3));
        escrowId = _createAndFundEscrow(escrowData);

        vm.prank(settlerOwner);
        settler.write(sender, escrowData.settlementId, 1);

        escrowIds[0] = escrowId;
        escrow.refundRecipient(escrowIds);

        // Settlement should fail after recipient refund
        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.settle(escrowIds);
    }

    // ========== Edge Cases ==========

    function testZeroRefundAmount() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 0);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Depositor gets nothing
        escrow.refundDepositor(escrowIds);
        assertEq(token.balanceOf(depositor), 9000); // No refund

        // Recipient gets everything
        escrow.refundRecipient(escrowIds);
        assertEq(token.balanceOf(recipient), 1000);
    }

    function testFullRefundAmount() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 1000);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Depositor gets everything
        escrow.refundDepositor(escrowIds);
        assertEq(token.balanceOf(depositor), 10000); // Full refund

        // Recipient gets nothing
        escrow.refundRecipient(escrowIds);
        assertEq(token.balanceOf(recipient), 0);
    }

    function testMultipleEscrowsInOneCall() public {
        // Create 3 escrows with different amounts
        bytes32[] memory escrowIds = new bytes32[](3);

        for (uint256 i = 0; i < 3; i++) {
            IEscrow.Escrow memory escrowData = IEscrow.Escrow({
                salt: bytes12(uint96(i)),
                depositor: depositor,
                recipient: recipient,
                token: address(token),
                settler: address(settler),
                sender: sender,
                settlementId: keccak256(abi.encode("settlement", i)),
                senderChainId: 1,
                escrowAmount: 1000 * (i + 1),
                refundAmount: 800 * (i + 1),
                refundTimestamp: block.timestamp + 1 hours
            });

            vm.startPrank(depositor);
            token.approve(address(escrow), escrowData.escrowAmount);
            IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
            escrows[0] = escrowData;
            escrow.escrow(escrows);
            vm.stopPrank();

            escrowIds[i] = keccak256(abi.encode(escrowData));
        }

        // Total escrowed: 1000 + 2000 + 3000 = 6000
        assertEq(token.balanceOf(address(escrow)), 6000);

        vm.warp(block.timestamp + 2 hours);

        // Refund all depositors at once
        escrow.refundDepositor(escrowIds);

        // Total refunded: 800 + 1600 + 2400 = 4800
        assertEq(token.balanceOf(depositor), 10000 - 6000 + 4800);

        // Refund all recipients at once
        escrow.refundRecipient(escrowIds);

        // Total to recipients: 200 + 400 + 600 = 1200
        assertEq(token.balanceOf(recipient), 1200);

        // All funds distributed
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testDuplicateEscrowCreation() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);

        vm.startPrank(depositor);
        token.approve(address(escrow), 2000);

        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
        escrows[0] = escrowData;
        escrow.escrow(escrows);

        // Try to create same escrow again
        vm.expectRevert(bytes4(keccak256("InvalidStatus()")));
        escrow.escrow(escrows);
        vm.stopPrank();
    }

    // ========== Native ETH Tests ==========

    function testEscrowNativeETH_CreateAndSettle() public {
        // Setup
        uint256 escrowAmount = 1 ether;
        uint256 refundAmount = 0.8 ether;
        bytes32 settlementId = keccak256("ETH_SETTLEMENT_ID");

        // Create escrow
        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
        escrows[0] = IEscrow.Escrow({
            salt: bytes12(uint96(1234)),
            depositor: depositor,
            recipient: recipient,
            token: address(0), // Native ETH
            settler: address(settler),
            sender: sender,
            settlementId: settlementId,
            senderChainId: 1,
            escrowAmount: escrowAmount,
            refundAmount: refundAmount,
            refundTimestamp: block.timestamp + 1 hours
        });

        bytes32 escrowId = keccak256(abi.encode(escrows[0]));

        // Execute escrow creation
        vm.expectEmit(true, false, false, false);
        emit EscrowCreated(escrowId);

        vm.prank(depositor);
        escrow.escrow{value: escrowAmount}(escrows);

        // Verify escrow was created
        assertEq(address(escrow).balance, escrowAmount);
        assertEq(uint8(escrow.statuses(escrowId)), uint8(IEscrow.EscrowStatus.CREATED));

        // Settle the escrow
        vm.prank(settlerOwner);
        settler.write(sender, settlementId, 1);

        uint256 recipientBalanceBefore = recipient.balance;

        vm.expectEmit(true, false, false, false);
        emit EscrowSettled(escrowId);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;
        escrow.settle(escrowIds);

        // Verify settlement
        assertEq(recipient.balance, recipientBalanceBefore + escrowAmount);
        assertEq(address(escrow).balance, 0);
        assertEq(uint8(escrow.statuses(escrowId)), uint8(IEscrow.EscrowStatus.FINALIZED));
    }

    function testEscrowNativeETH_RefundFlow() public {
        // Setup
        uint256 escrowAmount = 1 ether;
        uint256 refundAmount = 0.8 ether;

        // Create escrow
        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
        escrows[0] = IEscrow.Escrow({
            salt: bytes12(uint96(1234)),
            depositor: depositor,
            recipient: recipient,
            token: address(0), // Native ETH
            settler: address(settler),
            sender: sender,
            settlementId: keccak256("SETTLEMENT_ID"),
            senderChainId: 1,
            escrowAmount: escrowAmount,
            refundAmount: refundAmount,
            refundTimestamp: block.timestamp + 1 hours
        });

        bytes32 escrowId = keccak256(abi.encode(escrows[0]));

        vm.prank(depositor);
        escrow.escrow{value: escrowAmount}(escrows);

        // Advance time past refund timestamp
        vm.warp(block.timestamp + 2 hours);

        uint256 depositorBalanceBefore = depositor.balance;
        uint256 recipientBalanceBefore = recipient.balance;

        // Refund
        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        vm.expectEmit(true, false, false, false);
        emit EscrowRefundedDepositor(escrowId);
        vm.expectEmit(true, false, false, false);
        emit EscrowRefundedRecipient(escrowId);

        escrow.refund(escrowIds);

        // Verify refunds
        assertEq(depositor.balance, depositorBalanceBefore + refundAmount);
        assertEq(recipient.balance, recipientBalanceBefore + (escrowAmount - refundAmount));
        assertEq(address(escrow).balance, 0);
        assertEq(uint8(escrow.statuses(escrowId)), uint8(IEscrow.EscrowStatus.FINALIZED));
    }

    function testEscrowNativeETH_IncorrectValue() public {
        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
        escrows[0] = IEscrow.Escrow({
            salt: bytes12(uint96(1234)),
            depositor: depositor,
            recipient: recipient,
            token: address(0), // Native ETH
            settler: address(settler),
            sender: sender,
            settlementId: keccak256("SETTLEMENT_ID"),
            senderChainId: 1,
            escrowAmount: 1 ether,
            refundAmount: 0.8 ether,
            refundTimestamp: block.timestamp + 1 hours
        });

        vm.startPrank(depositor);

        // Test insufficient value
        vm.expectRevert(Escrow.InvalidEscrow.selector);
        escrow.escrow{value: 0.5 ether}(escrows);

        // Test excess value
        vm.expectRevert(Escrow.InvalidEscrow.selector);
        escrow.escrow{value: 2 ether}(escrows);

        vm.stopPrank();
    }

    function testEscrowNativeETH_MixedWithERC20() public {
        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](3);

        // First escrow with native ETH - 1 ether
        escrows[0] = IEscrow.Escrow({
            salt: bytes12(uint96(1234)),
            depositor: depositor,
            recipient: recipient,
            token: address(0), // Native ETH
            settler: address(settler),
            sender: sender,
            settlementId: keccak256("SETTLEMENT_ID"),
            senderChainId: 1,
            escrowAmount: 1 ether,
            refundAmount: 0.8 ether,
            refundTimestamp: block.timestamp + 1 hours
        });

        // Second escrow with native ETH - 0.5 ether
        escrows[1] = IEscrow.Escrow({
            salt: bytes12(uint96(5678)),
            depositor: depositor,
            recipient: recipient,
            token: address(0), // Native ETH
            settler: address(settler),
            sender: sender,
            settlementId: keccak256("SETTLEMENT_ID_2"),
            senderChainId: 1,
            escrowAmount: 0.5 ether,
            refundAmount: 0.4 ether,
            refundTimestamp: block.timestamp + 1 hours
        });

        // Third escrow with ERC20
        escrows[2] = IEscrow.Escrow({
            salt: bytes12(uint96(9999)),
            depositor: depositor,
            recipient: recipient,
            token: address(token),
            settler: address(settler),
            sender: sender,
            settlementId: keccak256("SETTLEMENT_ID_3"),
            senderChainId: 1,
            escrowAmount: 2000,
            refundAmount: 1500,
            refundTimestamp: block.timestamp + 1 hours
        });

        // Approve ERC20
        vm.startPrank(depositor);
        token.approve(address(escrow), 2000);

        // Test 1: Incorrect ETH amount (less than required)
        vm.expectRevert(Escrow.InvalidEscrow.selector);
        escrow.escrow{value: 1 ether}(escrows); // Sending 1 ETH but need 1.5 ETH

        // Test 2: Incorrect ETH amount (more than required)
        vm.expectRevert(Escrow.InvalidEscrow.selector);
        escrow.escrow{value: 2 ether}(escrows); // Sending 2 ETH but need 1.5 ETH

        // Test 3: Correct ETH amount - should succeed
        uint256 totalNativeAmount = 1 ether + 0.5 ether; // 1.5 ETH total
        escrow.escrow{value: totalNativeAmount}(escrows);
        vm.stopPrank();

        // Verify balances
        assertEq(address(escrow).balance, totalNativeAmount);
        assertEq(token.balanceOf(address(escrow)), 2000);

        // Verify each escrow was created
        bytes32 escrowId1 = keccak256(abi.encode(escrows[0]));
        bytes32 escrowId2 = keccak256(abi.encode(escrows[1]));
        bytes32 escrowId3 = keccak256(abi.encode(escrows[2]));

        assertEq(uint8(escrow.statuses(escrowId1)), uint8(IEscrow.EscrowStatus.CREATED));
        assertEq(uint8(escrow.statuses(escrowId2)), uint8(IEscrow.EscrowStatus.CREATED));
        assertEq(uint8(escrow.statuses(escrowId3)), uint8(IEscrow.EscrowStatus.CREATED));
    }

    // ========== Helper Functions ==========

    function _createEscrowData(uint256 escrowAmount, uint256 refundAmount)
        internal
        view
        returns (IEscrow.Escrow memory)
    {
        return IEscrow.Escrow({
            salt: bytes12(uint96(1)),
            depositor: depositor,
            recipient: recipient,
            token: address(token),
            settler: address(settler),
            sender: sender,
            settlementId: keccak256("settlement"),
            senderChainId: 1,
            escrowAmount: escrowAmount,
            refundAmount: refundAmount,
            refundTimestamp: block.timestamp + 1 hours
        });
    }

    function _createAndFundEscrow(IEscrow.Escrow memory escrowData)
        internal
        returns (bytes32 escrowId)
    {
        escrowId = keccak256(abi.encode(escrowData));

        vm.startPrank(depositor);
        token.approve(address(escrow), escrowData.escrowAmount);
        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
        escrows[0] = escrowData;
        escrow.escrow(escrows);
        vm.stopPrank();
    }
}
