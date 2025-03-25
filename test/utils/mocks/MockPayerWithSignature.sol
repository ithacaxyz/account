// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {TokenTransferLib} from "../../../src/TokenTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockPayerWithSignature is Ownable {
    error InvalidSignature();

    address public signer;

    mapping(address => bool) public isApprovedEntryPoint;

    event Compensated(
        address paymentToken,
        address paymentRecipient,
        uint256 paymentAmount,
        address eoa,
        bytes32 userOpDigest,
        bytes paymentSignature
    );

    constructor() {
        _initializeOwner(msg.sender);
    }

    function setSigner(address newSinger) public onlyOwner {
        signer = newSinger;
    }

    function setApprovedEntryPoint(address entryPoint, bool approved) public onlyOwner {
        isApprovedEntryPoint[entryPoint] = approved;
    }

    /// @dev `address(0)` denote native token (i.e. Ether).
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
        bytes32 digest = computeSignatureDigest(userOpDigest);
        if (ECDSA.recoverCalldata(digest, paymentSignature) != signer) {
            revert InvalidSignature();
        }
        // Emit the event for debugging.
        // The `eoa` is not used.
        emit Compensated(
            paymentToken, paymentRecipient, paymentAmount, eoa, userOpDigest, paymentSignature
        );
    }

    function computeSignatureDigest(bytes32 userOpDigest) public view returns (bytes32) {
        // We shall just use this simplified hash instead of EIP712.
        return keccak256(abi.encode(userOpDigest, block.chainid, address(this)));
    }

    receive() external payable {}
}
