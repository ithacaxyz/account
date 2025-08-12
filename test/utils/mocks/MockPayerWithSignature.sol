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

    address public signer;

    mapping(address => bool) public isApprovedOrchestrator;

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
    /// The EOA and token details are extracted from the `encodedIntent`.
    /// Reverts if the specified Orchestrator (`msg.sender`) is not approved.
    /// NOTE: This mock no longer verifies signatures within the pay function itself,
    /// aligning with the Account/Orchestrator pattern where verification happens before payment.
    /// @param paymentAmount The amount to pay.
    /// @param keyHash The key hash associated with the operation (not used in this mock's logic but kept for signature compatibility).
    /// @param encodedIntent ABI encoded Intent struct.
    function pay(
        uint256 paymentAmount,
        bytes32 keyHash,
        bytes32 digest,
        bytes calldata encodedIntent
    ) public virtual {
        if (!isApprovedOrchestrator[msg.sender]) revert Unauthorized();

        ICommon.Intent memory u = abi.decode(encodedIntent, (ICommon.Intent));

        bytes32 signatureDigest = computeSignatureDigest(digest);

        if (ECDSA.recover(signatureDigest, u.paymentSignature) != signer) {
            revert InvalidSignature();
        }

        TokenTransferLib.safeTransfer(u.paymentToken, u.paymentRecipient, paymentAmount);

        emit Compensated(u.paymentToken, u.paymentRecipient, paymentAmount, u.eoa, keyHash);
    }

    function computeSignatureDigest(bytes32 intentDigest) public view returns (bytes32) {
        // We shall just use this simplified hash instead of EIP712.
        return keccak256(abi.encode(intentDigest, block.chainid, address(this)));
    }

    receive() external payable {}
}
