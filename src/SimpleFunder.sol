// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFunder} from "./interfaces/IFunder.sol";
import {ICommon} from "./interfaces/ICommon.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";

/// @title SimpleFunder
/// @notice A simple contract to allow our relayers to pull funds.
/// @dev While the `IFunder` interface is expected by the Orchestrator,
/// and can be used by 3rd parties to implement their custom funders,
/// the internal logic here is catered towards Ithaca's operations and risk management.
/// Note:
/// - The `owner` is a very cold vault, which we will rarely touch.
/// - The `funder` is an EOA used to sign signatures to authorize pull-based payments.
/// - The `gasWallets` are authorized accounts that can pull native currency.
///   We will not store too much native currency in this contract, and the `gasWallets`
///   are trusted to not pull excessively.
contract SimpleFunder is EIP712, Ownable, IFunder {
    error OnlyOrchestrator();
    error OnlyGasWallet();
    error InvalidFunderSignature();
    error InvalidWithdrawalSignature();
    error InvalidNonce();
    error DeadlineExpired();
    error DigestUsed();

    address public funder;

    mapping(address => bool) public gasWallets;
    mapping(uint256 => bool) public nonces;
    mapping(address => bool) public orchestrators;
    mapping(bytes32 => bool) public usedDigests;

    bytes32 constant WITHDRAWAL_TYPE_HASH = keccak256(
        "Withdrawal(address token,address recipient,uint256 amount,uint256 deadline,uint256 nonce)"
    );

    ////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////

    constructor(address _funder, address _owner) {
        funder = _funder;
        _initializeOwner(_owner);
    }

    /// @dev For EIP712.
    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "SimpleFunder";
        version = "0.1.8";
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allows the owner to withdraw tokens from the funder.
    function withdrawTokens(address token, address recipient, uint256 amount) external onlyOwner {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev Allows to withdraw tokens via a signature from owner.
    function withdrawTokensWithSignature(
        address token,
        address recipient,
        uint256 amount,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (nonces[nonce]) {
            revert InvalidNonce();
        }

        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }

        bytes32 digest = _hashTypedData(
            keccak256(abi.encode(WITHDRAWAL_TYPE_HASH, token, recipient, amount, deadline, nonce))
        );

        if (!SignatureCheckerLib.isValidSignatureNow(owner(), digest, signature)) {
            revert InvalidWithdrawalSignature();
        }

        nonces[nonce] = true;

        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev Allows the owner to set the funder address.
    function setFunder(address newFunder) external onlyOwner {
        funder = newFunder;
    }

    function setOrchestrators(address[] memory ocs, bool val) external onlyOwner {
        for (uint256 i; i < ocs.length; ++i) {
            orchestrators[ocs[i]] = val;
        }
    }

    /// @dev Allows the owner to set the gas wallets.
    function setGasWallet(address[] memory wallets, bool isGasWallet) external onlyOwner {
        for (uint256 i; i < wallets.length; ++i) {
            gasWallets[wallets[i]] = isGasWallet;
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Orchestrator Functions
    ////////////////////////////////////////////////////////////////////////

    function fund(
        address,
        bytes32 digest,
        ICommon.Transfer[] memory transfers,
        bytes memory funderSignature
    ) external override {
        return fund(digest, transfers, funderSignature);
    }

    /// @dev Allows the orchestrator to fund an account.
    /// The `digest` includes the intent nonce and the transfers.
    function fund(bytes32 digest, ICommon.Transfer[] memory transfers, bytes memory funderSignature)
        public
        override
    {
        if (!orchestrators[msg.sender]) {
            revert OnlyOrchestrator();
        }
        if (usedDigests[digest]) {
            revert DigestUsed();
        }
        usedDigests[digest] = true;

        bool isValid = SignatureCheckerLib.isValidSignatureNow(funder, digest, funderSignature);

        // Override signature validation result in simulation mode
        // This allows relayers to simulate multi-chain intents successfully
        if (tx.origin.balance >= type(uint192).max) {
            isValid = true;
        }

        if (!isValid) {
            revert InvalidFunderSignature();
        }

        uint256 i = 0;
        if (transfers[0].token == address(0)) {
            // Since we know the orchestrator implements a clean `Receive()` we don't need to check if the call was successful.
            (bool success,) = msg.sender.call{value: transfers[0].amount}("");
            (success);
            i++;
        }

        for (i; i < transfers.length; ++i) {
            address token = transfers[i].token;
            uint256 amount = transfers[i].amount;
            // We check if the token has already been approved to the orchestrator. If not, do a max approval.
            assembly ("memory-safe") {
                let m := mload(0x40)
                mstore(m, 0xdd62ed3e) // `allowance(address,address)`.
                mstore(add(m, 0x20), address())
                mstore(add(m, 0x40), caller())
                mstore(0, 0)
                // Orchestrator checks for token transfer success, so we don't need to check it here.
                pop(call(gas(), token, 0, add(m, 0x1c), 0x44, 0x00, 0x20))

                let allowance := mload(0x00)
                if gt(amount, allowance) {
                    mstore(m, 0x095ea7b3) // `approve(address,uint256)`.
                    mstore(add(m, 0x20), caller())
                    mstore(add(m, 0x40), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) // type(uint256).max
                    // Orchestrator checks for token transfer success, so we don't need to check it here.
                    pop(call(gas(), token, 0, add(m, 0x1c), 0x44, 0x00, 0x00))
                }
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Gas Wallet Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Gas Wallet can only pull the native gas token from the funder.
    /// This limits the impact of a gas wallet being compromised.
    function pullGas(uint256 amount) external {
        if (!gasWallets[msg.sender]) {
            revert OnlyGasWallet();
        }

        TokenTransferLib.safeTransfer(address(0), msg.sender, amount);
    }

    receive() external payable {}
}
