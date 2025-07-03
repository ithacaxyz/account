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

        // Verify funds still locked
        assertEq(token.balanceOf(address(escrow)), 1000);
    }

    function testCannotSettleAfterDeadline() public {
        IEscrow.Escrow memory escrowData = _createEscrowData(1000, 800);
        bytes32 escrowId = _createAndFundEscrow(escrowData);

        // Mark as settled
        vm.prank(settlerOwner);
        settler.write(sender, escrowData.settlementId, 1);

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        // Cannot settle after deadline
        vm.expectRevert(bytes4(keccak256("SettlementExpired()")));
        escrow.settle(escrowIds);
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
                settleDeadline: block.timestamp + 1 hours
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
            settleDeadline: block.timestamp + 1 hours
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
