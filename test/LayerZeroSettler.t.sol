// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./utils/SoladyTest.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";
import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";
import {Origin, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

// Mock LayerZero endpoint for testing
contract MockLZEndpoint {
    mapping(address => bool) public delegates;

    struct StoredMessage {
        uint32 dstEid;
        bytes32 sender;
        bytes payload;
        address receiver;
    }

    StoredMessage[] public messages;

    function setDelegate(address delegate) external {
        delegates[msg.sender] = true;
    }

    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        messages.push(
            StoredMessage({
                dstEid: params.dstEid,
                sender: bytes32(uint256(uint160(msg.sender))),
                payload: params.message,
                receiver: address(uint160(uint256(params.receiver)))
            })
        );

        receipt.guid = keccak256(abi.encode(messages.length));
        receipt.nonce = 0;
        receipt.fee = MessagingFee(msg.value, 0);

        // Refund excess
        if (msg.value > 0.0005 ether) {
            (bool success,) = refundAddress.call{value: msg.value - 0.0005 ether}("");
            require(success, "Refund failed");
        }
    }

    function quote(MessagingParams calldata params, address sender)
        external
        pure
        returns (MessagingFee memory fee)
    {
        // Mock fee: 0.0005 ETH per message (lower for self-execution)
        fee.nativeFee = 0.0005 ether;
        fee.lzTokenFee = 0;
    }

    // Helper to simulate message delivery (anyone can call - self execution)
    function deliverMessage(address target, uint256 messageIndex) external {
        require(messageIndex < messages.length, "Invalid message");
        StoredMessage memory m = messages[messageIndex];

        // We need to find the source chain ID based on the sender
        uint32 srcEid = 30101; // Default mainnet
        if (m.sender == bytes32(uint256(uint160(0xc7183455a4C133Ae270771860664b6B7ec320bB1)))) {
            srcEid = 30110; // Arbitrum
        } else if (
            m.sender == bytes32(uint256(uint160(0xa0Cb889707d426A7A386870A03bc70d1b0697598)))
        ) {
            srcEid = 30184; // Base
        }

        Origin memory origin = Origin({srcEid: srcEid, sender: m.sender, nonce: 0});

        // The endpoint (this contract) calls lzReceive on the target OApp
        LayerZeroSettler(payable(target)).lzReceive(
            origin,
            keccak256(abi.encode(messageIndex)),
            m.payload,
            address(this), // executor
            ""
        );
    }
}

contract LayerZeroSettlerTest is SoladyTest {
    LayerZeroSettler settler1; // Mainnet
    LayerZeroSettler settler2; // Arbitrum
    LayerZeroSettler settler3; // Base

    MockLZEndpoint endpoint1;
    MockLZEndpoint endpoint2;
    MockLZEndpoint endpoint3;

    Escrow escrow2; // Arbitrum escrow
    Escrow escrow3; // Base escrow

    MockPaymentToken token2;
    MockPaymentToken token3;

    address orchestrator = makeAddr("ORCHESTRATOR");
    address user = makeAddr("USER");
    address relay = makeAddr("RELAY");

    // Allow test contract to receive ETH
    receive() external payable {}

    function setUp() public {
        // Deploy mock endpoints
        endpoint1 = new MockLZEndpoint();
        endpoint2 = new MockLZEndpoint();
        endpoint3 = new MockLZEndpoint();

        // Deploy settlers on each "chain"
        vm.chainId(1); // Mainnet
        settler1 = new LayerZeroSettler(address(endpoint1), address(this));

        vm.chainId(42161); // Arbitrum
        settler2 = new LayerZeroSettler(address(endpoint2), address(this));

        vm.chainId(8453); // Base
        settler3 = new LayerZeroSettler(address(endpoint3), address(this));

        // Set peers using LayerZero endpoint IDs
        settler1.setPeer(30101, bytes32(uint256(uint160(address(settler1))))); // Self
        settler1.setPeer(30110, bytes32(uint256(uint160(address(settler2))))); // Arbitrum
        settler1.setPeer(30184, bytes32(uint256(uint160(address(settler3))))); // Base

        settler2.setPeer(30101, bytes32(uint256(uint160(address(settler1))))); // Mainnet
        settler2.setPeer(30110, bytes32(uint256(uint160(address(settler2))))); // Self
        settler2.setPeer(30184, bytes32(uint256(uint160(address(settler3))))); // Base

        settler3.setPeer(30101, bytes32(uint256(uint160(address(settler1))))); // Mainnet
        settler3.setPeer(30110, bytes32(uint256(uint160(address(settler2))))); // Arbitrum
        settler3.setPeer(30184, bytes32(uint256(uint160(address(settler3))))); // Self

        // Deploy escrows and tokens
        escrow2 = new Escrow();
        escrow3 = new Escrow();

        token2 = new MockPaymentToken();
        token3 = new MockPaymentToken();

        // Fund settlers for operation
        vm.deal(address(settler1), 1 ether);
        vm.deal(address(settler2), 1 ether);
        vm.deal(address(settler3), 1 ether);
    }

    function testLayerZeroSettlement() public {
        // Setup: User has funds on Arbitrum and Base
        vm.chainId(42161);
        token2.mint(user, 500);

        vm.chainId(8453);
        token3.mint(user, 600);

        // 1. Create escrows on input chains
        bytes32 settlementId = keccak256("TEST_SETTLEMENT");

        // Arbitrum escrow
        vm.chainId(42161);
        IEscrow.Escrow memory escrowArb = IEscrow.Escrow({
            salt: bytes12(uint96(1)),
            depositor: user,
            recipient: relay,
            token: address(token2),
            settler: address(settler2),
            sender: orchestrator,
            settlementId: settlementId,
            senderChainId: 1, // Mainnet
            escrowAmount: 500,
            refundAmount: 500,
            refundTimestamp: block.timestamp + 1 hours
        });

        vm.startPrank(user);
        token2.approve(address(escrow2), 500);
        IEscrow.Escrow[] memory escrowsArb = new IEscrow.Escrow[](1);
        escrowsArb[0] = escrowArb;
        escrow2.escrow(escrowsArb);
        vm.stopPrank();

        // Base escrow
        vm.chainId(8453);
        IEscrow.Escrow memory escrowBase = IEscrow.Escrow({
            salt: bytes12(uint96(2)),
            depositor: user,
            recipient: relay,
            token: address(token3),
            settler: address(settler3),
            sender: orchestrator,
            settlementId: settlementId,
            senderChainId: 1, // Mainnet
            escrowAmount: 600,
            refundAmount: 600,
            refundTimestamp: block.timestamp + 1 hours
        });

        vm.startPrank(user);
        token3.approve(address(escrow3), 600);
        IEscrow.Escrow[] memory escrowsBase = new IEscrow.Escrow[](1);
        escrowsBase[0] = escrowBase;
        escrow3.escrow(escrowsBase);
        vm.stopPrank();

        // 2. Execute output intent on mainnet and send settlement
        vm.chainId(1);

        uint256[] memory inputChains = new uint256[](2);
        inputChains[0] = 42161; // Arbitrum
        inputChains[1] = 8453; // Base

        // Check quote
        uint256 fee = settler1.quoteSend(inputChains);
        assertEq(fee, 0.001 ether); // 0.0005 ETH per chain

        // Check settler has sufficient balance
        assertGe(address(settler1).balance, fee);

        // Send settlement notification
        vm.prank(orchestrator);
        settler1.send(settlementId, inputChains);

        // 3. Self-execute message delivery to Arbitrum
        vm.chainId(42161);
        vm.prank(address(endpoint2)); // Endpoint2 is the Arbitrum endpoint
        settler2.lzReceive(
            Origin({srcEid: 30101, sender: bytes32(uint256(uint160(address(settler1)))), nonce: 0}),
            keccak256(abi.encode(0)),
            abi.encode(settlementId, orchestrator, uint256(1)),
            address(this),
            ""
        );

        // Verify settlement is recorded
        assertTrue(settler2.read(settlementId, orchestrator, 1));

        // Settle the Arbitrum escrow
        bytes32 escrowIdArb = keccak256(abi.encode(escrowArb));
        escrow2.settle(escrowIdArb);
        assertEq(token2.balanceOf(relay), 500);

        // 4. Self-execute message delivery to Base
        vm.chainId(8453);
        vm.prank(address(endpoint3)); // Endpoint3 is the Base endpoint
        settler3.lzReceive(
            Origin({srcEid: 30101, sender: bytes32(uint256(uint160(address(settler1)))), nonce: 0}),
            keccak256(abi.encode(1)),
            abi.encode(settlementId, orchestrator, uint256(1)),
            address(this),
            ""
        );

        // Verify settlement is recorded
        assertTrue(settler3.read(settlementId, orchestrator, 1));

        // Settle the Base escrow
        bytes32 escrowIdBase = keccak256(abi.encode(escrowBase));
        escrow3.settle(escrowIdBase);
        assertEq(token3.balanceOf(relay), 600);
    }

    function testInsufficientBalance() public {
        vm.chainId(1);

        // Drain settler balance
        vm.prank(address(this));
        settler1.withdraw(address(settler1).balance);

        uint256[] memory chains = new uint256[](2);
        chains[0] = 42161;
        chains[1] = 8453;

        vm.expectRevert(
            abi.encodeWithSelector(LayerZeroSettler.InsufficientBalance.selector, 0, 0.001 ether)
        );
        vm.prank(orchestrator);
        settler1.send(bytes32(0), chains);
    }

    function testInvalidChainId() public {
        vm.chainId(1);

        uint256[] memory invalidChains = new uint256[](1);
        invalidChains[0] = 999; // Invalid chain

        vm.expectRevert(LayerZeroSettler.InvalidChainId.selector);
        vm.prank(orchestrator);
        settler1.send(bytes32(0), invalidChains);
    }

    function testWithdraw() public {
        vm.chainId(1);

        uint256 balanceBefore = address(this).balance;
        uint256 settlerBalance = address(settler1).balance;

        // Owner withdraws half
        settler1.withdraw(settlerBalance / 2);

        assertEq(address(settler1).balance, settlerBalance / 2);
        assertEq(address(this).balance, balanceBefore + settlerBalance / 2);
    }

    function testWithdrawInsufficientBalance() public {
        vm.chainId(1);

        uint256 settlerBalance = address(settler1).balance;

        vm.expectRevert(
            abi.encodeWithSelector(
                LayerZeroSettler.InsufficientBalance.selector, settlerBalance, settlerBalance + 1
            )
        );
        settler1.withdraw(settlerBalance + 1);
    }

    function testReceiveETH() public {
        vm.chainId(1);

        uint256 balanceBefore = address(settler1).balance;

        // Send ETH to settler
        vm.deal(address(this), 5 ether);
        (bool success,) = address(settler1).call{value: 2 ether}("");
        assertTrue(success);

        assertEq(address(settler1).balance, balanceBefore + 2 ether);
    }

    function testQuoteSend() public {
        vm.chainId(1);

        // Test various chain combinations
        uint256[] memory chains1 = new uint256[](1);
        chains1[0] = 42161;
        assertEq(settler1.quoteSend(chains1), 0.0005 ether);

        uint256[] memory chains2 = new uint256[](3);
        chains2[0] = 42161;
        chains2[1] = 8453;
        chains2[2] = 1; // Self
        assertEq(settler1.quoteSend(chains2), 0.0015 ether);

        // Invalid chain is skipped
        uint256[] memory chains3 = new uint256[](2);
        chains3[0] = 42161;
        chains3[1] = 999; // Invalid
        assertEq(settler1.quoteSend(chains3), 0.0005 ether);
    }

    function testRefundMechanism() public {
        vm.chainId(1);

        // Overfund the settler
        vm.deal(address(settler1), 10 ether);
        uint256 balanceBefore = address(settler1).balance;

        uint256[] memory chains = new uint256[](1);
        chains[0] = 42161;

        // Send with overfunded balance
        vm.prank(orchestrator);
        settler1.send(bytes32("REFUND_TEST"), chains);

        // Should have refunded excess back to settler
        assertApproxEqAbs(address(settler1).balance, balanceBefore - 0.0005 ether, 0.0001 ether);
    }
}
