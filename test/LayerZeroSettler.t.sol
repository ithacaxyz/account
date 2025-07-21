// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";
import {ISettler} from "../src/interfaces/ISettler.sol";
import {MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";
import {EndpointV2Mock} from
    "lib/devtools/packages/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";
import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {
    Origin,
    MessagingParams,
    MessagingFee
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SendLibMock} from "./mocks/SendLibMock.sol";

contract LayerZeroSettlerTest is Test {
    SendLibMock public sendLib;
    LayerZeroSettler public settlerA;
    LayerZeroSettler public settlerB;
    LayerZeroSettler public settlerC;

    EndpointV2Mock public endpointA;
    EndpointV2Mock public endpointB;
    EndpointV2Mock public endpointC;

    Escrow public escrowA;
    Escrow public escrowB;
    MockPaymentToken public token;

    uint32 public constant EID_A = 1;
    uint32 public constant EID_B = 2;
    uint32 public constant EID_C = 3;

    address public owner;
    address public depositor;
    address public recipient;
    address public orchestrator;

    event Settled(address indexed sender, bytes32 indexed settlementId, uint256 senderChainId);

    function setUp() public {
        owner = makeAddr("owner");
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        orchestrator = makeAddr("orchestrator");

        // Deploy send library
        sendLib = new SendLibMock();

        // Deploy mock endpoints
        endpointA = new EndpointV2Mock(EID_A, address(this));
        endpointB = new EndpointV2Mock(EID_B, address(this));
        endpointC = new EndpointV2Mock(EID_C, address(this));

        // Register and set default send and receive libraries
        endpointA.registerLibrary(address(sendLib));
        endpointA.setDefaultSendLibrary(EID_B, address(sendLib));
        endpointA.setDefaultSendLibrary(EID_C, address(sendLib));
        endpointA.setDefaultReceiveLibrary(EID_B, address(sendLib), 0);
        endpointA.setDefaultReceiveLibrary(EID_C, address(sendLib), 0);

        endpointB.registerLibrary(address(sendLib));
        endpointB.setDefaultSendLibrary(EID_A, address(sendLib));
        endpointB.setDefaultSendLibrary(EID_C, address(sendLib));
        endpointB.setDefaultReceiveLibrary(EID_A, address(sendLib), 0);
        endpointB.setDefaultReceiveLibrary(EID_C, address(sendLib), 0);

        endpointC.registerLibrary(address(sendLib));
        endpointC.setDefaultSendLibrary(EID_A, address(sendLib));
        endpointC.setDefaultSendLibrary(EID_B, address(sendLib));
        endpointC.setDefaultReceiveLibrary(EID_A, address(sendLib), 0);
        endpointC.setDefaultReceiveLibrary(EID_B, address(sendLib), 0);

        // Deploy settlers
        settlerA = new LayerZeroSettler(address(endpointA), owner);
        settlerB = new LayerZeroSettler(address(endpointB), owner);
        settlerC = new LayerZeroSettler(address(endpointC), owner);

        // Set peers for each settler
        vm.prank(owner);
        settlerA.setPeer(EID_B, bytes32(uint256(uint160(address(settlerB)))));
        vm.prank(owner);
        settlerA.setPeer(EID_C, bytes32(uint256(uint160(address(settlerC)))));

        vm.prank(owner);
        settlerB.setPeer(EID_A, bytes32(uint256(uint160(address(settlerA)))));
        vm.prank(owner);
        settlerB.setPeer(EID_C, bytes32(uint256(uint160(address(settlerC)))));

        vm.prank(owner);
        settlerC.setPeer(EID_A, bytes32(uint256(uint160(address(settlerA)))));
        vm.prank(owner);
        settlerC.setPeer(EID_B, bytes32(uint256(uint160(address(settlerB)))));

        // Deploy escrows
        escrowA = new Escrow();
        escrowB = new Escrow();

        // Deploy token
        token = new MockPaymentToken();

        // Fund test accounts
        vm.deal(depositor, 100 ether);
        vm.deal(orchestrator, 100 ether);
        token.mint(depositor, 1000 ether);
    }

    // Helper function to calculate total fee for multiple endpoints
    function _quoteFeeForEndpoints(LayerZeroSettler, uint32[] memory endpointIds)
        internal
        pure
        returns (uint256 totalFee)
    {
        // LayerZero's mock doesn't have a fixed fee, we'll use a reasonable test amount
        for (uint256 i = 0; i < endpointIds.length; i++) {
            if (endpointIds[i] != 0) {
                totalFee += 0.001 ether;
            }
        }
    }

    // Helper to simulate cross-chain message delivery using proper LayerZero flow
    function _deliverCrossChainMessage(
        uint32 srcEid,
        uint32 dstEid,
        address srcSettler,
        address payable dstSettler,
        bytes32 settlementId,
        address sender,
        uint256 senderChainId
    ) internal {
        EndpointV2Mock srcEndpoint;
        if (srcEid == EID_A) srcEndpoint = endpointA;
        else if (srcEid == EID_B) srcEndpoint = endpointB;
        else if (srcEid == EID_C) srcEndpoint = endpointC;
        else revert("Invalid source EID");

        EndpointV2Mock dstEndpoint;
        if (dstEid == EID_A) dstEndpoint = endpointA;
        else if (dstEid == EID_B) dstEndpoint = endpointB;
        else if (dstEid == EID_C) dstEndpoint = endpointC;
        else revert("Invalid destination EID");

        // Get the nonce from the source endpoint
        uint64 nonce = srcEndpoint.outboundNonce(
            srcSettler, dstEid, bytes32(uint256(uint160(address(dstSettler))))
        );

        // Message payload that was sent
        bytes memory message = abi.encode(settlementId, sender, senderChainId);

        // Step 1: Verify the message (as the receive library would)
        Origin memory origin =
            Origin({srcEid: srcEid, sender: bytes32(uint256(uint160(srcSettler))), nonce: nonce});

        // Step 2: Generate GUID same way as the endpoint
        bytes32 guid = keccak256(
            abi.encodePacked(
                nonce,
                srcEid,
                bytes32(uint256(uint160(srcSettler))),
                dstEid,
                bytes32(uint256(uint160(address(dstSettler))))
            )
        );

        // The payload hash includes both the guid and the message
        bytes32 payloadHash = keccak256(abi.encodePacked(guid, message));

        // The send library acts as the receive library for verification
        vm.prank(address(sendLib));
        dstEndpoint.verify(origin, dstSettler, payloadHash);

        // Anyone can call lzReceive after verification
        dstEndpoint.lzReceive(origin, dstSettler, guid, message, bytes(""));
    }

    function test_send_validSettlement() public {
        bytes32 settlementId = keccak256("test-settlement");
        uint32[] memory endpointIds = new uint32[](1);
        endpointIds[0] = EID_B;
        bytes memory settlerContext = abi.encode(endpointIds);

        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        // Verify the send was recorded with the correct key
        bytes32 sendKey = keccak256(abi.encode(orchestrator, settlementId, settlerContext));
        assertTrue(settlerA.validSend(sendKey));
    }

    function test_executeSend_singleDestination_success() public {
        bytes32 settlementId = keccak256("test-settlement");
        uint32[] memory endpointIds = new uint32[](1);
        endpointIds[0] = EID_B;
        bytes memory settlerContext = abi.encode(endpointIds);

        // First, orchestrator calls send to authorize
        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        // Calculate the fee
        uint256 fee = _quoteFeeForEndpoints(settlerA, endpointIds);

        // Now anyone can execute with proper fee
        address randomCaller = makeAddr("randomCaller");
        vm.deal(randomCaller, fee);

        vm.prank(randomCaller);
        settlerA.executeSend{value: fee}(orchestrator, settlementId, settlerContext);

        // Verify message was sent through the send library
        assertEq(sendLib.getPacketCount(), 1);

        // Simulate cross-chain message delivery
        _deliverCrossChainMessage(
            EID_A,
            EID_B,
            address(settlerA),
            payable(address(settlerB)),
            settlementId,
            orchestrator,
            block.chainid
        );

        // Check that settlement was recorded on destination
        assertTrue(settlerB.read(settlementId, orchestrator, block.chainid));
    }

    function test_executeSend_multipleDestinations_success() public {
        bytes32 settlementId = keccak256("test-settlement-multi");
        uint32[] memory endpointIds = new uint32[](2);
        endpointIds[0] = EID_B;
        endpointIds[1] = EID_C;
        bytes memory settlerContext = abi.encode(endpointIds);

        // Orchestrator authorizes the settlement
        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        // Calculate the fee
        uint256 fee = _quoteFeeForEndpoints(settlerA, endpointIds);

        // Different caller executes with proper fee
        address executor = makeAddr("executor");
        vm.deal(executor, fee);

        vm.prank(executor);
        settlerA.executeSend{value: fee}(orchestrator, settlementId, settlerContext);

        // Verify messages were sent to both destinations
        assertEq(sendLib.getPacketCount(), 2);

        // Simulate cross-chain message delivery
        _deliverCrossChainMessage(
            EID_A,
            EID_B,
            address(settlerA),
            payable(address(settlerB)),
            settlementId,
            orchestrator,
            block.chainid
        );
        _deliverCrossChainMessage(
            EID_A,
            EID_C,
            address(settlerA),
            payable(address(settlerC)),
            settlementId,
            orchestrator,
            block.chainid
        );

        // Check that settlements were recorded
        assertTrue(settlerB.read(settlementId, orchestrator, block.chainid));
        assertTrue(settlerC.read(settlementId, orchestrator, block.chainid));
    }

    function test_executeSend_invalidSettlementId_reverts() public {
        bytes32 settlementId = keccak256("test-settlement");
        uint32[] memory endpointIds = new uint32[](1);
        endpointIds[0] = EID_B;
        bytes memory settlerContext = abi.encode(endpointIds);

        // Try to execute without calling send first
        vm.expectRevert(abi.encodeWithSelector(LayerZeroSettler.InvalidSettlementId.selector));
        settlerA.executeSend{value: 1 ether}(orchestrator, settlementId, settlerContext);
    }

    function test_executeSend_invalidEndpointId_reverts() public {
        bytes32 settlementId = keccak256("test-settlement");
        uint32[] memory endpointIds = new uint32[](1);
        endpointIds[0] = 0; // Invalid endpoint ID
        bytes memory settlerContext = abi.encode(endpointIds);

        // First call send to validate
        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        // Try to execute with invalid endpoint
        vm.expectRevert(abi.encodeWithSelector(LayerZeroSettler.InvalidEndpointId.selector));
        settlerA.executeSend{value: 1 ether}(orchestrator, settlementId, settlerContext);
    }

    function test_executeSend_insufficientFee_reverts() public {
        bytes32 settlementId = keccak256("test-settlement");
        uint32[] memory endpointIds = new uint32[](1);
        endpointIds[0] = EID_B;
        bytes memory settlerContext = abi.encode(endpointIds);

        // First call send to validate
        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        // Calculate the fee
        uint256 fee = _quoteFeeForEndpoints(settlerA, endpointIds);

        // Try to execute with insufficient fee - will revert with OutOfFunds
        vm.expectRevert();
        settlerA.executeSend{value: fee / 2}(orchestrator, settlementId, settlerContext);
    }

    function test_executeSend_orchestratorCanExecute() public {
        bytes32 settlementId = keccak256("test-settlement");
        uint32[] memory endpointIds = new uint32[](1);
        endpointIds[0] = EID_B;
        bytes memory settlerContext = abi.encode(endpointIds);

        // Orchestrator calls send
        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        // Calculate the fee
        uint256 fee = _quoteFeeForEndpoints(settlerA, endpointIds);

        // Orchestrator can also execute
        vm.prank(orchestrator);
        settlerA.executeSend{value: fee}(orchestrator, settlementId, settlerContext);

        // Simulate cross-chain message delivery and check settlement
        _deliverCrossChainMessage(
            EID_A,
            EID_B,
            address(settlerA),
            payable(address(settlerB)),
            settlementId,
            orchestrator,
            block.chainid
        );
        assertTrue(settlerB.read(settlementId, orchestrator, block.chainid));
    }

    function test_lzReceive_recordsSettlement() public {
        bytes32 settlementId = keccak256("test-settlement");
        uint32[] memory endpointIds = new uint32[](1);
        endpointIds[0] = EID_B;
        bytes memory settlerContext = abi.encode(endpointIds);

        // Send from A to B
        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        uint256 fee = _quoteFeeForEndpoints(settlerA, endpointIds);

        vm.prank(orchestrator);
        settlerA.executeSend{value: fee}(orchestrator, settlementId, settlerContext);

        // Simulate cross-chain message delivery
        _deliverCrossChainMessage(
            EID_A,
            EID_B,
            address(settlerA),
            payable(address(settlerB)),
            settlementId,
            orchestrator,
            block.chainid
        );

        // Verify the settlement was recorded
        assertTrue(settlerB.read(settlementId, orchestrator, block.chainid));
    }

    function test_withdraw_nativeToken_onlyOwner() public {
        // Send some ETH to the settler
        vm.deal(address(settlerA), 10 ether);

        uint256 balanceBefore = recipient.balance;

        // Owner can withdraw native token
        vm.prank(owner);
        settlerA.withdraw(address(0), recipient, 5 ether);

        assertEq(recipient.balance, balanceBefore + 5 ether);
        assertEq(address(settlerA).balance, 5 ether);
    }

    function test_withdraw_erc20Token_onlyOwner() public {
        // Send some tokens to the settler
        token.mint(address(settlerA), 100 ether);

        uint256 balanceBefore = token.balanceOf(recipient);

        // Owner can withdraw ERC20 token
        vm.prank(owner);
        settlerA.withdraw(address(token), recipient, 50 ether);

        assertEq(token.balanceOf(recipient), balanceBefore + 50 ether);
        assertEq(token.balanceOf(address(settlerA)), 50 ether);
    }

    function test_withdraw_nonOwner_reverts() public {
        vm.deal(address(settlerA), 10 ether);

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, makeAddr("notOwner"))); // OwnableUnauthorizedAccount selector
        settlerA.withdraw(address(0), recipient, 5 ether);
    }

    function test_escrowIntegration_successfulSettlement() public {
        bytes32 settlementId = keccak256("escrow-settlement");
        uint256 escrowAmount = 100 ether;
        uint256 refundAmount = 10 ether;
        uint256 refundTimestamp = block.timestamp + 1 days;

        // Create escrow on chain B
        IEscrow.Escrow memory escrowData = IEscrow.Escrow({
            salt: bytes12(0),
            depositor: depositor,
            recipient: recipient,
            token: address(token),
            escrowAmount: escrowAmount,
            refundAmount: refundAmount,
            refundTimestamp: refundTimestamp,
            settler: payable(address(settlerB)),
            sender: orchestrator,
            settlementId: settlementId,
            senderChainId: block.chainid
        });

        IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
        escrows[0] = escrowData;

        vm.startPrank(depositor);
        token.approve(address(escrowB), escrowAmount);
        escrowB.escrow(escrows);
        vm.stopPrank();

        // Send settlement from chain A to chain B
        uint32[] memory endpointIds = new uint32[](1);
        endpointIds[0] = EID_B;
        bytes memory settlerContext = abi.encode(endpointIds);

        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        uint256 fee = _quoteFeeForEndpoints(settlerA, endpointIds);

        vm.prank(orchestrator);
        settlerA.executeSend{value: fee}(orchestrator, settlementId, settlerContext);

        // Simulate cross-chain message delivery
        _deliverCrossChainMessage(
            EID_A,
            EID_B,
            address(settlerA),
            payable(address(settlerB)),
            settlementId,
            orchestrator,
            block.chainid
        );

        // Now settle the escrow
        bytes32 escrowId = keccak256(abi.encode(escrowData));
        bytes32[] memory escrowIds = new bytes32[](1);
        escrowIds[0] = escrowId;

        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        escrowB.settle(escrowIds);

        assertEq(token.balanceOf(recipient), recipientBalanceBefore + escrowAmount);
        assertEq(uint8(escrowB.statuses(escrowId)), uint8(IEscrow.EscrowStatus.FINALIZED));
    }

    function test_quoteFee_multipleEndpoints() public view {
        uint32[] memory endpointIds = new uint32[](2);
        endpointIds[0] = EID_B;
        endpointIds[1] = EID_C;

        uint256 totalFee = _quoteFeeForEndpoints(settlerA, endpointIds);
        assertEq(totalFee, 0.001 ether * 2);
    }

    function test_quoteFee_emptyArray() public view {
        uint32[] memory endpointIds = new uint32[](0);
        uint256 totalFee = _quoteFeeForEndpoints(settlerA, endpointIds);
        assertEq(totalFee, 0);
    }

    function test_quoteFee_withInvalidEndpoint() public view {
        uint32[] memory endpointIds = new uint32[](3);
        endpointIds[0] = EID_B;
        endpointIds[1] = 0; // Invalid, will be skipped
        endpointIds[2] = EID_C;

        uint256 totalFee = _quoteFeeForEndpoints(settlerA, endpointIds);

        // Should only include fees for valid endpoints
        assertEq(totalFee, 0.001 ether * 2);
    }

    function test_receive_externalEthTransfer() public {
        uint256 balanceBefore = address(settlerA).balance;

        vm.deal(makeAddr("alice"), 5 ether);
        vm.prank(makeAddr("alice"));
        (bool success,) = payable(address(settlerA)).call{value: 5 ether}("");

        assertTrue(success);
        assertEq(address(settlerA).balance, balanceBefore + 5 ether);
    }

    function testFuzz_send_differentSettlementIds(bytes32 settlementId, uint8 numEndpoints)
        public
    {
        vm.assume(numEndpoints > 0 && numEndpoints <= 3);

        uint32[] memory endpointIds = new uint32[](numEndpoints);
        for (uint8 i = 0; i < numEndpoints; i++) {
            // Use valid endpoint IDs
            if (i == 0) endpointIds[i] = EID_B;
            else if (i == 1) endpointIds[i] = EID_C;
            else endpointIds[i] = EID_A; // Send back to A for testing
        }
        bytes memory settlerContext = abi.encode(endpointIds);

        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        bytes32 sendKey = keccak256(abi.encode(orchestrator, settlementId, settlerContext));
        assertTrue(settlerA.validSend(sendKey));
    }

    function testFuzz_executeSend_fullFlow(
        bytes32 settlementId,
        address executor,
        bool includeB,
        bool includeC
    ) public {
        vm.assume(executor != address(0));
        vm.assume(includeB || includeC); // At least one destination

        // Build endpoint IDs based on fuzz inputs
        uint8 count = 0;
        if (includeB) count++;
        if (includeC) count++;

        uint32[] memory endpointIds = new uint32[](count);
        uint8 idx = 0;
        if (includeB) endpointIds[idx++] = EID_B;
        if (includeC) endpointIds[idx++] = EID_C;

        bytes memory settlerContext = abi.encode(endpointIds);

        // Orchestrator authorizes
        vm.prank(orchestrator);
        settlerA.send(settlementId, settlerContext);

        // Quote and fund executor
        uint256 totalFee = _quoteFeeForEndpoints(settlerA, endpointIds);
        vm.deal(executor, totalFee);

        // Any address can execute
        vm.prank(executor);
        settlerA.executeSend{value: totalFee}(orchestrator, settlementId, settlerContext);

        // Verify and deliver messages
        if (includeB) {
            _deliverCrossChainMessage(
                EID_A,
                EID_B,
                address(settlerA),
                payable(address(settlerB)),
                settlementId,
                orchestrator,
                block.chainid
            );
            assertTrue(settlerB.read(settlementId, orchestrator, block.chainid));
        }
        if (includeC) {
            _deliverCrossChainMessage(
                EID_A,
                EID_C,
                address(settlerA),
                payable(address(settlerC)),
                settlementId,
                orchestrator,
                block.chainid
            );
            assertTrue(settlerC.read(settlementId, orchestrator, block.chainid));
        }
    }
}
