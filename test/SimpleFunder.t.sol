// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {ICommon} from "../src/interfaces/ICommon.sol";
import {MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";

contract SimpleFunderTest is Test {
    SimpleFunder public simpleFunder;
    address public orchestrator;
    address public funder;
    address public owner;
    address public recipient;
    MockPaymentToken public token;

    uint256 public funderPrivateKey = 0x1234;

    function setUp() public {
        orchestrator = address(this); // Test contract acts as orchestrator
        funder = vm.addr(funderPrivateKey);
        owner = makeAddr("owner");
        recipient = makeAddr("recipient");

        simpleFunder = new SimpleFunder(funder, orchestrator, owner);
        token = new MockPaymentToken();

        // Fund the SimpleFunder with tokens
        token.mint(address(simpleFunder), 1000 ether);
        vm.deal(address(simpleFunder), 10 ether);
    }

    function test_fund_withValidSignature() public {
        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(funderPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = token.balanceOf(recipient);

        simpleFunder.fund(recipient, digest, transfers, signature);

        assertEq(token.balanceOf(recipient), balanceBefore + 100 ether);
    }

    function test_fund_withInvalidSignature_reverts() public {
        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");
        bytes memory invalidSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        vm.expectRevert(bytes4(keccak256("InvalidFunderSignature()")));
        simpleFunder.fund(recipient, digest, transfers, invalidSignature);
    }

    function test_fund_simulationMode_bypasses_signatureValidation() public {
        // Set caller balance to max uint256 to simulate state override
        vm.deal(address(this), type(uint256).max);

        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");
        // Use invalid signature - should still work in simulation mode
        bytes memory invalidSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        uint256 balanceBefore = token.balanceOf(recipient);

        // Should not revert despite invalid signature
        simpleFunder.fund(recipient, digest, transfers, invalidSignature);

        assertEq(token.balanceOf(recipient), balanceBefore + 100 ether);
    }

    function test_fund_notOrchestrator_reverts() public {
        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");
        bytes memory signature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        vm.prank(makeAddr("notOrchestrator"));
        vm.expectRevert(bytes4(keccak256("OnlyOrchestrator()")));
        simpleFunder.fund(recipient, digest, transfers, signature);
    }

    function test_fund_multipleTransfers() public {
        MockPaymentToken token2 = new MockPaymentToken();
        token2.mint(address(simpleFunder), 500 ether);

        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](2);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});
        transfers[1] = ICommon.Transfer({token: address(token2), amount: 50 ether});

        bytes32 digest = keccak256("test digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(funderPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balance1Before = token.balanceOf(recipient);
        uint256 balance2Before = token2.balanceOf(recipient);

        simpleFunder.fund(recipient, digest, transfers, signature);

        assertEq(token.balanceOf(recipient), balance1Before + 100 ether);
        assertEq(token2.balanceOf(recipient), balance2Before + 50 ether);
    }

    function test_fund_nativeToken() public {
        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({
            token: address(0), // Native token (ETH)
            amount: 1 ether
        });

        bytes32 digest = keccak256("test digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(funderPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = recipient.balance;

        simpleFunder.fund(recipient, digest, transfers, signature);

        assertEq(recipient.balance, balanceBefore + 1 ether);
    }

    function testFuzz_fund_simulationMode_anySignature(bytes memory randomSignature) public {
        // Set caller balance to max uint256 to simulate state override
        vm.deal(address(this), type(uint256).max);

        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");

        uint256 balanceBefore = token.balanceOf(recipient);

        // Should not revert with any signature in simulation mode
        simpleFunder.fund(recipient, digest, transfers, randomSignature);

        assertEq(token.balanceOf(recipient), balanceBefore + 100 ether);
    }
}
