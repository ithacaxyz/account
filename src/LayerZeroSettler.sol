// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISettler} from "./interfaces/ISettler.sol";

/// @title LayerZeroSettler
/// @notice Cross-chain settlement using LayerZero v2 with self-execution model
/// @dev Overfunds and uses refunds to handle dynamic fees across chains
contract LayerZeroSettler is OApp, ISettler {
    event Sent(address indexed sender, bytes32 indexed settlementId, uint256 receiverChainId);
    event Settled(address indexed sender, bytes32 indexed settlementId, uint256 senderChainId);

    error InvalidChainId();
    error InsufficientBalance(uint256 balance, uint256 required);

    // Mapping: settlementId => sender => chainId => isSettled
    mapping(bytes32 => mapping(address => mapping(uint256 => bool))) public settled;

    // LayerZero endpoint IDs
    // NOTE: Currently stored as constants to avoid SLOAD gas costs. As we add more chains,
    // we may need to switch to a mapping(uint256 => uint32) which would incur a cold
    // storage read cost but provide more flexibility for chain additions.
    uint32 private constant MAINNET_EID = 30101;
    uint32 private constant ARBITRUM_EID = 30110;
    uint32 private constant BASE_EID = 30184;

    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {}

    /// @notice Allow contract to receive ETH for fee payments
    receive() external payable {}

    /// @notice Send settlement attestation to multiple chains
    /// @param settlementId The unique identifier for the settlement
    /// @param inputChains Array of chain IDs to notify about the settlement
    /// @dev Uses contract balance to pay for LayerZero fees
    function send(bytes32 settlementId, uint256[] memory inputChains) external override {
        uint256 totalFee = quoteSend(inputChains);

        if (address(this).balance < totalFee) {
            revert InsufficientBalance(address(this).balance, totalFee);
        }

        bytes memory payload = abi.encode(settlementId, msg.sender, block.chainid);
        bytes memory options = ""; // No executor options for self-execution

        for (uint256 i = 0; i < inputChains.length; i++) {
            uint32 dstEid = _chainIdToEid(inputChains[i]);
            if (dstEid == 0) revert InvalidChainId();

            // Quote individual fee for this destination
            MessagingFee memory fee = _quote(dstEid, payload, options, false);

            // Send with exact fee, refund to this contract
            _lzSend(
                dstEid, payload, options, MessagingFee(fee.nativeFee, 0), payable(address(this))
            );

            emit Sent(msg.sender, settlementId, inputChains[i]);
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

    /// @notice Quote the total fee for sending to multiple chains
    /// @param inputChains Array of chain IDs to send to
    /// @return totalFee The total native fee required
    function quoteSend(uint256[] memory inputChains) public view returns (uint256 totalFee) {
        bytes memory payload = abi.encode(bytes32(0), address(0), uint256(0));
        bytes memory options = ""; // No executor options

        for (uint256 i = 0; i < inputChains.length; i++) {
            uint32 dstEid = _chainIdToEid(inputChains[i]);
            if (dstEid == 0) continue;

            MessagingFee memory fee = _quote(dstEid, payload, options, false);
            totalFee += fee.nativeFee;
        }
    }

    /// @notice Owner can withdraw excess funds
    /// @param amount Amount to withdraw
    function withdraw(uint256 amount) external onlyOwner {
        if (address(this).balance < amount) {
            revert InsufficientBalance(address(this).balance, amount);
        }

        (bool success,) = payable(owner()).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// @notice Convert chain ID to LayerZero endpoint ID
    /// @param chainId The EVM chain ID
    /// @return eid The LayerZero endpoint ID
    function _chainIdToEid(uint256 chainId) internal pure returns (uint32 eid) {
        if (chainId == 1) return MAINNET_EID;
        if (chainId == 42161) return ARBITRUM_EID;
        if (chainId == 8453) return BASE_EID;
        return 0;
    }

    /// @notice Override to pay from contract balance instead of msg.value
    /// @param _nativeFee The native fee to be paid
    /// @return nativeFee The amount of native currency paid
    function _payNative(uint256 _nativeFee) internal override returns (uint256 nativeFee) {
        // We pay from contract balance, not msg.value
        return _nativeFee;
    }
}
