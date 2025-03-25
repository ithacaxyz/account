// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {TokenTransferLib} from "../../../src/TokenTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockSignaturePayer is Ownable {
    error InvalidSignature();

    address public signer;

    mapping(address => bool) public isApprovedEntryPoint;

    constructor() {
        _initializeOwner(msg.sender);
    }

    function setSigner(address newSinger) public onlyOwner {
        signer = newSinger;
    }

    function setApprovedEntryPoint(address entryPoint, bool approved) public onlyOwner {
        isApprovedEntryPoint[entryPoint] = approved;
    }

    function withdrawTokens(address token, address recipient, uint256 amount)
        public
        virtual
        onlyOwner
    {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev Pays `paymentAmount` of `paymentToken` to the `paymentRecipient`.
    function compensate(
        address paymentToken,
        address paymentRecipient,
        uint256 paymentAmount,
        address eoa,
        bytes32 userOpDigest,
        bytes calldata paymentSignature
    ) public virtual {
        if (!isApprovedEntryPoint[msg.sender]) revert Unauthorized();
        TokenTransferLib.safeTransfer(paymentToken, paymentRecipient, paymentAmount);
        if (ECDSA.recoverCalldata(computeSignatureDigest(userOpDigest), paymentSignature) != signer)
        {
            revert InvalidSignature();
        }
        // Silence unused variables warning.
        eoa = eoa; // The EOA is already hashed into `userOpDigest`.
            // Note that paymentSignature already includes a nonce which is
            // guaranteed to be invalidated the the payment is not reverted.
    }

    function computeSignatureDigest(bytes32 userOpDigest) public view returns (bytes32) {
        // We shall just use this simplified hash instead of EIP712.
        return keccak256(abi.encode(userOpDigest, block.chainid, address(this)));
    }
}
