// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OApp, MessagingFee, Origin} from "./vendor/layerzero/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISettler} from "./interfaces/ISettler.sol";
import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

/// @title LayerZeroSettler
/// @notice Cross-chain settlement using LayerZero v2 with self-execution model
/// @dev Uses msg.value to pay for cross-chain messaging fees
contract LayerZeroSettler is OApp, ISettler, EIP712 {
    event Settled(address indexed sender, bytes32 indexed settlementId, uint256 senderChainId);

    error InvalidEndpointId();
    error InsufficientFee(uint256 provided, uint256 required);
    error InvalidSettlementId();
    error InvalidL0SettlerSignature();

    // Mapping: settlementId => sender => chainId => isSettled
    mapping(bytes32 => mapping(address => mapping(uint256 => bool))) public settled;
    mapping(bytes32 => bool) public validSend;

    // L0SettlerSigner role for authorizing executeSend
    address public l0SettlerSigner;

    // EIP-712 type hash for executeSend authorization
    bytes32 constant EXECUTE_SEND_TYPE_HASH =
        keccak256("ExecuteSend(address sender,bytes32 settlementId,bytes settlerContext)");

    constructor(address _owner, address _l0SettlerSigner) OApp(_owner) Ownable(_owner) {
        l0SettlerSigner = _l0SettlerSigner;
    }

    /// @dev For EIP712 domain name and version
    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "LayerZeroSettler";
        version = "0.1.1";
    }

    /// @notice Mark the settlement as valid to be sent
    function send(bytes32 settlementId, bytes calldata settlerContext) external payable override {
        validSend[keccak256(abi.encode(msg.sender, settlementId, settlerContext))] = true;
    }

    /// @notice Execute the settlement send to multiple chains
    /// @dev Requires BOTH: 1) Prior `send()` call to set validSend[key] = true, AND 2) Valid L0SettlerSigner signature
    /// @dev Requires msg.value to cover all LayerZero fees.
    /// @param sender The original sender of the settlement
    /// @param settlementId The unique settlement identifier
    /// @param settlerContext Encoded array of LayerZero endpoint IDs
    /// @param signature EIP-712 signature from the L0SettlerSigner
    function executeSend(
        address sender,
        bytes32 settlementId,
        bytes calldata settlerContext,
        bytes calldata signature
    ) external payable {
        bytes32 key = keccak256(abi.encode(sender, settlementId, settlerContext));

        // Check that send() was called first
        if (!validSend[key]) {
            revert InvalidSettlementId();
        }

        // Verify L0SettlerSigner signature
        bytes32 digest = computeExecuteSendDigest(sender, settlementId, settlerContext);

        if (!SignatureCheckerLib.isValidSignatureNow(l0SettlerSigner, digest, signature)) {
            revert InvalidL0SettlerSignature();
        }

        // Clear the authorization to prevent replay
        validSend[key] = false;

        // Decode settlerContext as an array of LayerZero endpoint IDs
        uint32[] memory endpointIds = abi.decode(settlerContext, (uint32[]));

        bytes memory payload = abi.encode(settlementId, sender, block.chainid);

        // Type 3 options with minimal executor configuration for self-execution
        bytes memory options = hex"0003";

        // If the fee sent as msg.value is incorrect, then one of these _lzSends will revert.
        for (uint256 i = 0; i < endpointIds.length; i++) {
            uint32 dstEid = endpointIds[i];
            if (dstEid == 0) revert InvalidEndpointId();

            // Quote individual fee for this destination
            MessagingFee memory fee = _quote(dstEid, payload, options, false);

            // Send with exact fee, refund to msg.sender
            _lzSend(dstEid, payload, options, MessagingFee(fee.nativeFee, 0), payable(msg.sender));
        }
    }

    function _getPeerOrRevert(
        uint32 /* _eid */
    )
        internal
        view
        virtual
        override
        returns (bytes32)
    {
        // The peer address for all chains is automatically set to `address(this)`
        return bytes32(uint256(uint160(address(this))));
    }

    /// @notice Allow initialization path from configured peers
    /// @dev Checks if the origin sender matches the configured peer for that endpoint
    /// @param _origin The origin information containing the source endpoint and sender address
    /// @return True if origin sender is the configured peer, false otherwise
    function allowInitializePath(Origin calldata _origin)
        public
        view
        virtual
        override
        returns (bool)
    {
        bytes32 peer = _getPeerOrRevert(_origin.srcEid);

        // Allow initialization if the sender matches the configured peer
        return _origin.sender == peer;
    }

    /// @notice Receive settlement attestation from another chain
    /// @dev Called by LayerZero endpoint after message verification

    function _lzReceive(
        Origin calldata, /*_origin*/
        bytes32, /*_guid*/
        bytes calldata _payload,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    )
        internal
        override
    {
        // Decode the settlement data
        (bytes32 settlementId, address sender, uint256 senderChainId) =
            abi.decode(_payload, (bytes32, address, uint256));

        // Record the settlement
        settled[settlementId][sender][senderChainId] = true;

        emit Settled(sender, settlementId, senderChainId);
    }

    /// @notice Check if a settlement has been attested
    /// @dev In the case of IthacAccount interop, the sender will always be the orchestrator.
    function read(bytes32 settlementId, address sender, uint256 chainId)
        external
        view
        override
        returns (bool isSettled)
    {
        return settled[settlementId][sender][chainId];
    }

    /// @notice Owner can withdraw excess funds
    /// @dev Allows recovery of any assets that might accumulate from overpayments
    function withdraw(address token, address recipient, uint256 amount) external onlyOwner {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @notice Owner can update the L0SettlerSigner address
    /// @param newL0SettlerSigner The new address authorized to sign executeSend operations
    function setL0SettlerSigner(address newL0SettlerSigner) external onlyOwner {
        l0SettlerSigner = newL0SettlerSigner;
    }

    /// @notice Compute the EIP-712 digest for executeSend
    /// @dev Useful for external signature generation and testing
    /// @param sender The original sender of the settlement
    /// @param settlementId The unique settlement identifier
    /// @param settlerContext Encoded array of LayerZero endpoint IDs
    /// @return The EIP-712 digest ready for signing
    function computeExecuteSendDigest(
        address sender,
        bytes32 settlementId,
        bytes memory settlerContext
    ) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(EXECUTE_SEND_TYPE_HASH, sender, settlementId, keccak256(settlerContext))
            )
        );
    }

    /// @notice We override this function, because multiple L0 messages are sent in a single transaction.
    function _payNative(uint256 _nativeFee) internal pure override returns (uint256 nativeFee) {
        // Return the fee amount; the base contract will handle the actual payment
        return _nativeFee;
    }

    /// @notice Allow contract to receive ETH from refunds
    receive() external payable {}

    // ========================================================
    // ULN302 Executor Functions
    // ========================================================
    function assignJob(uint32, address, uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function getFee(uint32, address, uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    /// @notice Override the peers getter to always return this contract's address
    /// @dev This ensures all cross-chain messages are self-executed
    /// @param _eid The endpoint ID (unused as we always return the same value)
    /// @return peer The address of this contract as bytes32
    function peers(uint32 _eid) public view virtual override returns (bytes32 peer) {
        // Always return this contract's address for all endpoints
        // This enables self-execution model where the same contract address is used across all chains
        _eid; // Silence unused parameter warning
        return bytes32(uint256(uint160(address(this))));
    }
}
