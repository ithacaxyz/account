// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISettler} from "./interfaces/ISettler.sol";
import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";

/// @title LayerZeroSettler
/// @notice Cross-chain settlement using LayerZero v2 with self-execution model
/// @dev Uses msg.value to pay for cross-chain messaging fees
contract LayerZeroSettler is OApp, ISettler {
    event Settled(address indexed sender, bytes32 indexed settlementId, uint256 senderChainId);

    error InvalidEndpointId();
    error InsufficientFee(uint256 provided, uint256 required);
    error InvalidSettlementId();

    // Mapping: settlementId => sender => chainId => isSettled
    mapping(bytes32 => mapping(address => mapping(uint256 => bool))) public settled;
    mapping(bytes32 => bool) public validSend;

    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {}

    ////////////////////////////////////////////////////////////////////////
    // EIP-5267 Support
    ////////////////////////////////////////////////////////////////////////

    /// @dev See: https://eips.ethereum.org/EIPS/eip-5267
    /// Returns the fields and values that describe the domain separator used for signing.
    /// Note: This is just for labelling and offchain verification purposes.
    /// This contract does not use EIP712 signatures anywhere else.
    function eip712Domain()
        public
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        fields = hex"0f"; // `0b01111` - has name, version, chainId, verifyingContract
        name = "LayerZeroSettler";
        version = "0.0.1";
        chainId = block.chainid;
        verifyingContract = address(this);
        salt = bytes32(0);
        extensions = new uint256[](0);
    }

    /// @notice Mark the settlement as valid to be sent
    function send(bytes32 settlementId, bytes calldata settlerContext) external payable override {
        validSend[keccak256(abi.encode(msg.sender, settlementId, settlerContext))] = true;
    }

    /// @notice Execute the settlement send to multiple chains
    /// @dev `send` must have been called with the exact same parameters, before calling this function.
    /// @dev Requires msg.value to cover all LayerZero fees.
    function executeSend(address sender, bytes32 settlementId, bytes calldata settlerContext)
        external
        payable
    {
        if (!validSend[keccak256(abi.encode(sender, settlementId, settlerContext))]) {
            revert InvalidSettlementId();
        }

        // Decode settlerContext as an array of LayerZero endpoint IDs
        uint32[] memory endpointIds = abi.decode(settlerContext, (uint32[]));

        bytes memory payload = abi.encode(settlementId, sender, block.chainid);
        bytes memory options = ""; // No executor options for self-execution

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

    /// @notice Receive settlement attestation from another chain
    /// @dev Called by LayerZero endpoint after message verification
    function _lzReceive(
        Origin calldata, /*_origin*/
        bytes32, /*_guid*/
        bytes calldata _payload,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) internal override {
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

    /// @notice We override this function, because multiple L0 messages are sent in a single transaction.
    function _payNative(uint256 _nativeFee) internal pure override returns (uint256 nativeFee) {
        // Return the fee amount; the base contract will handle the actual payment
        return _nativeFee;
    }

    /// @notice Allow contract to receive ETH from refunds
    receive() external payable {}
}
