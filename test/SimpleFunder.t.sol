// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {ICommon} from "../src/interfaces/ICommon.sol";
import {MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";
import {EIP712} from "solady/utils/EIP712.sol";

contract SimpleFunderTest is Test {
    SimpleFunder public simpleFunder;
    address public orchestrator;
    address public funder;
    address public owner;
    address public recipient;
    MockPaymentToken public token;

    uint256 public funderPrivateKey = 0x1234;
    uint256 public ownerPrivateKey = 0x5678;

    address internal constant _ORIGIN_ADDRESS = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    // EIP712 constants
    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant WITHDRAWAL_TYPE_HASH = keccak256(
        "Withdrawal(address token,address recipient,uint256 amount,uint256 deadline,uint256 nonce)"
    );

    function setUp() public {
        orchestrator = address(this); // Test contract acts as orchestrator
        funder = vm.addr(funderPrivateKey);
        owner = vm.addr(ownerPrivateKey);
        recipient = makeAddr("recipient");

        simpleFunder = new SimpleFunder(funder, owner);
        vm.prank(owner);
        address[] memory ocs = new address[](1);
        ocs[0] = orchestrator;
        simpleFunder.setOrchestrators(ocs, true);
        token = new MockPaymentToken();

        // Fund the SimpleFunder with tokens
        token.mint(address(simpleFunder), 1000 ether);
        vm.deal(address(simpleFunder), 10 ether);
    }

    // Helper function to compute EIP712 digest
    function computeWithdrawalDigest(
        address _token,
        address _recipient,
        uint256 amount,
        uint256 deadline,
        uint256 nonce
    ) internal view returns (bytes32) {
        (,, string memory version,,,,) = simpleFunder.eip712Domain();

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("SimpleFunder")),
                keccak256(bytes(version)),
                block.chainid,
                address(simpleFunder)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(WITHDRAWAL_TYPE_HASH, _token, _recipient, amount, deadline, nonce)
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function test_receive() public {
        (bool success,) = address(simpleFunder).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(simpleFunder).balance, 11 ether);
    }

    function test_fund_withValidSignature() public {
        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(funderPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 allowanceBefore = token.allowance(address(simpleFunder), orchestrator);

        simpleFunder.fund(digest, transfers, signature);

        assertGt(token.allowance(address(simpleFunder), orchestrator), allowanceBefore + 100 ether);
    }

    function test_fund_withInvalidSignature_reverts() public {
        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");
        bytes memory invalidSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        vm.expectRevert(bytes4(keccak256("InvalidFunderSignature()")));
        simpleFunder.fund(digest, transfers, invalidSignature);
    }

    function test_fund_simulationMode_bypasses_signatureValidation() public {
        // Set caller balance to max uint256 to simulate state override
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");
        // Use invalid signature - should still work in simulation mode
        bytes memory invalidSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        uint256 allowanceBefore = token.allowance(address(simpleFunder), orchestrator);

        // Should not revert despite invalid signature
        simpleFunder.fund(digest, transfers, invalidSignature);

        assertGt(token.allowance(address(simpleFunder), orchestrator), allowanceBefore + 100 ether);
    }

    function test_fund_notOrchestrator_reverts() public {
        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");
        bytes memory signature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        vm.prank(makeAddr("notOrchestrator"));
        vm.expectRevert(bytes4(keccak256("OnlyOrchestrator()")));
        simpleFunder.fund(digest, transfers, signature);
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

        uint256 allowance1Before = token.allowance(address(simpleFunder), orchestrator);
        uint256 allowance2Before = token2.allowance(address(simpleFunder), orchestrator);

        simpleFunder.fund(digest, transfers, signature);

        assertGt(token.allowance(address(simpleFunder), orchestrator), allowance1Before + 100 ether);
        assertGt(token2.allowance(address(simpleFunder), orchestrator), allowance2Before + 50 ether);
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

        uint256 orchestratorBalanceBefore = orchestrator.balance;

        simpleFunder.fund(digest, transfers, signature);

        // For native token, the orchestrator should receive ETH directly
        assertEq(orchestrator.balance, orchestratorBalanceBefore + 1 ether);
    }

    function testFuzz_fund_simulationMode_anySignature(bytes memory randomSignature) public {
        // Set caller balance to max uint256 to simulate state override
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);

        ICommon.Transfer[] memory transfers = new ICommon.Transfer[](1);
        transfers[0] = ICommon.Transfer({token: address(token), amount: 100 ether});

        bytes32 digest = keccak256("test digest");

        uint256 allowanceBefore = token.allowance(address(simpleFunder), orchestrator);

        // Should not revert with any signature in simulation mode
        simpleFunder.fund(digest, transfers, randomSignature);

        assertGt(token.allowance(address(simpleFunder), orchestrator), allowanceBefore + 100 ether);
    }

    ////////////////////////////////////////////////////////////////////////
    // Withdrawal Signature Tests
    ////////////////////////////////////////////////////////////////////////

    function test_withdrawTokensWithSignature_validSignature() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 1;

        bytes32 digest = computeWithdrawalDigest(address(token), recipient, amount, deadline, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = token.balanceOf(recipient);

        simpleFunder.withdrawTokensWithSignature(
            address(token), recipient, amount, deadline, nonce, signature
        );

        assertEq(token.balanceOf(recipient), balanceBefore + amount);
        assertTrue(simpleFunder.nonces(nonce));
    }

    function test_withdrawTokensWithSignature_invalidSignature_reverts() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 1;

        // Create signature with wrong private key
        bytes32 digest = computeWithdrawalDigest(address(token), recipient, amount, deadline, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(funderPrivateKey, digest); // Wrong key
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(SimpleFunder.InvalidWithdrawalSignature.selector));
        simpleFunder.withdrawTokensWithSignature(
            address(token), recipient, amount, deadline, nonce, signature
        );
    }

    function test_withdrawTokensWithSignature_invalidNonce_reverts() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 1;

        bytes32 digest = computeWithdrawalDigest(address(token), recipient, amount, deadline, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First withdrawal should succeed
        simpleFunder.withdrawTokensWithSignature(
            address(token), recipient, amount, deadline, nonce, signature
        );

        // Second withdrawal with same nonce should fail
        vm.expectRevert(abi.encodeWithSelector(SimpleFunder.InvalidNonce.selector));
        simpleFunder.withdrawTokensWithSignature(
            address(token), recipient, amount, deadline, nonce, signature
        );
    }

    function test_withdrawTokensWithSignature_expiredDeadline_reverts() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp - 1; // Already expired
        uint256 nonce = 1;

        bytes32 digest = computeWithdrawalDigest(address(token), recipient, amount, deadline, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(SimpleFunder.DeadlineExpired.selector));
        simpleFunder.withdrawTokensWithSignature(
            address(token), recipient, amount, deadline, nonce, signature
        );
    }

    function test_withdrawTokensWithSignature_nativeToken() public {
        uint256 amount = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 1;

        bytes32 digest = computeWithdrawalDigest(address(0), recipient, amount, deadline, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = recipient.balance;

        simpleFunder.withdrawTokensWithSignature(
            address(0), recipient, amount, deadline, nonce, signature
        );

        assertEq(recipient.balance, balanceBefore + amount);
    }

    function testFuzz_withdrawTokensWithSignature_differentAmounts(
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) public {
        amount = bound(amount, 1, token.balanceOf(address(simpleFunder)));
        deadline = bound(deadline, block.timestamp + 1, type(uint256).max);

        bytes32 digest = computeWithdrawalDigest(address(token), recipient, amount, deadline, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = token.balanceOf(recipient);

        simpleFunder.withdrawTokensWithSignature(
            address(token), recipient, amount, deadline, nonce, signature
        );

        assertEq(token.balanceOf(recipient), balanceBefore + amount);
        assertTrue(simpleFunder.nonces(nonce));
    }

    function testFuzz_withdrawTokensWithSignature_invalidSignatures(
        bytes memory randomSignature,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        deadline = bound(deadline, block.timestamp + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(SimpleFunder.InvalidWithdrawalSignature.selector));
        simpleFunder.withdrawTokensWithSignature(
            address(token), recipient, amount, deadline, nonce, randomSignature
        );
    }

    function test_withdrawTokensWithSignature_zeroAmount() public {
        uint256 amount = 0;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = 1;

        bytes32 digest = computeWithdrawalDigest(address(token), recipient, amount, deadline, nonce);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = token.balanceOf(recipient);

        // Should succeed even with zero amount
        simpleFunder.withdrawTokensWithSignature(
            address(token), recipient, amount, deadline, nonce, signature
        );

        assertEq(token.balanceOf(recipient), balanceBefore); // No change
        assertTrue(simpleFunder.nonces(nonce)); // Nonce still consumed
    }

    receive() external payable {}
}
