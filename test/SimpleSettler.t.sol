// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

// Helper extension to access the digest calculation
contract SimpleSettlerTestHelper is SimpleSettler {
    constructor(address _owner) SimpleSettler(_owner) {}

    function getDigest(address sender, bytes32 settlementId, uint256 chainId)
        public
        view
        returns (bytes32)
    {
        return _hashTypedData(
            keccak256(abi.encode(SETTLEMENT_WRITE_TYPE_HASH, sender, settlementId, chainId))
        );
    }
}

contract SimpleSettlerTest is Test {
    SimpleSettlerTestHelper public settler;

    address owner;
    uint256 ownerPrivateKey;
    address sender = address(0x1234);
    address randomSigner = address(0x5678);
    uint256 randomSignerPrivateKey = 0xBEEF;

    bytes32 constant settlementId = keccak256("test-settlement");
    uint256 constant chainId = 1;

    event Sent(address indexed sender, bytes32 indexed settlementId, uint256 receiverChainId);

    function setUp() public {
        ownerPrivateKey = 0xDEAD;
        owner = vm.addr(ownerPrivateKey);

        settler = new SimpleSettlerTestHelper(owner);
    }

    function testWriteWithValidSignature() public {
        // Create the digest
        bytes32 digest = settler.getDigest(sender, settlementId, chainId);

        // Sign with owner's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Anyone can call write with valid signature
        vm.prank(randomSigner);
        settler.write(sender, settlementId, chainId, signature);

        // Verify the settlement was written
        assertTrue(settler.read(settlementId, sender, chainId));
    }

    function testWriteWithInvalidSignature() public {
        // Create the digest
        bytes32 digest = settler.getDigest(sender, settlementId, chainId);

        // Sign with wrong private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomSignerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Should revert with invalid signature
        vm.expectRevert(SimpleSettler.InvalidSettlementSignature.selector);
        settler.write(sender, settlementId, chainId, signature);

        // Verify nothing was written
        assertFalse(settler.read(settlementId, sender, chainId));
    }

    function testReplayIsHarmless() public {
        // Create the digest
        bytes32 digest = settler.getDigest(sender, settlementId, chainId);

        // Sign with owner's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First write
        settler.write(sender, settlementId, chainId, signature);
        assertTrue(settler.read(settlementId, sender, chainId));

        // Replay the same signature - should not revert
        settler.write(sender, settlementId, chainId, signature);

        // Still true
        assertTrue(settler.read(settlementId, sender, chainId));
    }

    function testOwnerCanWriteDirectly() public {
        // Owner can write directly without signature
        vm.prank(owner);
        settler.write(sender, settlementId, chainId);

        // Verify the settlement was written
        assertTrue(settler.read(settlementId, sender, chainId));
    }

    function testNonOwnerCannotWriteDirectly() public {
        // Non-owner cannot use the direct write function
        vm.prank(randomSigner);
        vm.expectRevert(); // Ownable revert
        settler.write(sender, settlementId, chainId);

        // Verify nothing was written
        assertFalse(settler.read(settlementId, sender, chainId));
    }

    function testSendFunction() public {
        uint256[] memory inputChains = new uint256[](3);
        inputChains[0] = 1;
        inputChains[1] = 137;
        inputChains[2] = 42161;

        bytes memory settlerContext = abi.encode(inputChains);

        // Expect events for each chain
        vm.expectEmit(true, true, false, true);
        emit Sent(sender, settlementId, 1);
        vm.expectEmit(true, true, false, true);
        emit Sent(sender, settlementId, 137);
        vm.expectEmit(true, true, false, true);
        emit Sent(sender, settlementId, 42161);

        // Call send
        vm.prank(sender);
        settler.send(settlementId, settlerContext);
    }
}
