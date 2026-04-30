// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {TokenTransferLib} from "../../../src/libraries/TokenTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {ICommon} from "../../../src/interfaces/ICommon.sol";
import {IOrchestrator} from "../../../src/interfaces/IOrchestrator.sol";
/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.

contract MockPayerWithSignature is Ownable {
    error InvalidSignature();
    /// @dev The paymaster nonce has already been used.
    error PaymasterNonceError();

    address public signer;

    mapping(address => bool) public isApprovedOrchestrator;

    /// @dev Nonce management when acting as paymaster.
    mapping(bytes32 => bool) public paymasterNonces;

    event Compensated(
        address indexed paymentToken,
        address indexed paymentRecipient,
        uint256 paymentAmount,
        address indexed eoa,
        bytes32 keyHash
    );

    constructor() {
        _initializeOwner(msg.sender);
    }

    function setSigner(address newSinger) public onlyOwner {
        signer = newSinger;
    }

    function setApprovedOrchestrator(address orchestrator, bool approved) public onlyOwner {
        isApprovedOrchestrator[orchestrator] = approved;
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
    /// @param paymentAmount The amount to pay
    /// @param keyHash The hash of the key used to authorize the operation
    /// @param intentDigest The digest of the user operation
    /// @param eoa The EOA address
    /// @param payer The payer address
    /// @param paymentToken The token to pay with
    /// @param paymentRecipient The recipient of the payment
    /// @param paymentSignature The payment signature
    function pay(
        uint256 paymentAmount,
        bytes32 keyHash,
        bytes32 intentDigest,
        address eoa,
        address payer,
        address paymentToken,
        address paymentRecipient,
        bytes calldata paymentSignature
    ) public virtual {
        if (!isApprovedOrchestrator[msg.sender]) revert Unauthorized();

        // Check and set nonce to prevent replay attacks
        if (paymasterNonces[intentDigest]) {
            revert PaymasterNonceError();
        }
        paymasterNonces[intentDigest] = true;

        bytes32 signatureDigest = computeSignatureDigest(intentDigest);

        if (ECDSA.recover(signatureDigest, paymentSignature) != signer) {
            revert InvalidSignature();
        }

        TokenTransferLib.safeTransfer(paymentToken, paymentRecipient, paymentAmount);

        emit Compensated(paymentToken, paymentRecipient, paymentAmount, eoa, keyHash);

        // Unused parameters
        payer;
    }

    function computeSignatureDigest(bytes32 intentDigest) public view returns (bytes32) {
        // We shall just use this simplified hash instead of EIP712.
        return keccak256(abi.encode(intentDigest, block.chainid, address(this)));
    }

    receive() external payable {}
}
