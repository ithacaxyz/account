// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISettler} from "./interfaces/ISettler.sol";

/// @title LayerZeroSettler
/// @notice Cross-chain settlement using LayerZero v2 with self-execution model
/// @dev Uses msg.value to pay for cross-chain messaging fees
contract LayerZeroSettler is OApp, ISettler {
    event Settled(address indexed sender, bytes32 indexed settlementId, uint256 senderChainId);

    error InvalidEndpointId();
    error InsufficientFee(uint256 provided, uint256 required);

    // Mapping: settlementId => sender => chainId => isSettled
    mapping(bytes32 => mapping(address => mapping(uint256 => bool))) public settled;

    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {}

    /// @notice Send settlement attestation to multiple chains
    /// @param settlementId The unique identifier for the settlement
    /// @param settlerContext Encoded context containing endpoint IDs
    /// @dev Requires msg.value to cover all LayerZero fees
    function send(bytes32 settlementId, bytes calldata settlerContext) external payable override {
        // Decode settlerContext as an array of LayerZero endpoint IDs
        uint32[] memory endpointIds = abi.decode(settlerContext, (uint32[]));

        uint256 totalFee = quoteSendByEndpoints(endpointIds);

        if (msg.value < totalFee) {
            revert InsufficientFee(msg.value, totalFee);
        }

        bytes memory payload = abi.encode(settlementId, msg.sender, block.chainid);
        bytes memory options = ""; // No executor options for self-execution

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
    /// @param settlementId The settlement to check
    /// @param attester The address that attested (orchestrator)
    /// @param chainId The chain ID where attestation originated
    function read(bytes32 settlementId, address attester, uint256 chainId)
        external
        view
        override
        returns (bool isSettled)
    {
        return settled[settlementId][attester][chainId];
    }

    /// @notice Quote the total fee for sending to multiple endpoints
    /// @param endpointIds Array of LayerZero endpoint IDs to send to
    /// @return totalFee The total native fee required
    function quoteSendByEndpoints(uint32[] memory endpointIds)
        public
        view
        returns (uint256 totalFee)
    {
        bytes memory payload = abi.encode(bytes32(0), address(0), uint256(0));
        bytes memory options = ""; // No executor options

        for (uint256 i = 0; i < endpointIds.length; i++) {
            if (endpointIds[i] == 0) continue;

            MessagingFee memory fee = _quote(endpointIds[i], payload, options, false);
            totalFee += fee.nativeFee;
        }
    }

    /// @notice Override to pay from msg.value instead of balance
    /// @param _nativeFee The native fee to be paid
    /// @return nativeFee The amount of native currency paid
    function _payNative(uint256 _nativeFee) internal pure override returns (uint256 nativeFee) {
        // Return the fee amount; the base contract will handle the actual payment
        return _nativeFee;
    }
}
