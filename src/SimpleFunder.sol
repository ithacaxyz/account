// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFunder} from "./interfaces/IFunder.sol";
import {ICommon} from "./interfaces/ICommon.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";

contract SimpleFunder is Ownable, IFunder {
    error OnlyOrchestrator();
    error OnlyGasWallet();

    address public immutable ORCHESTRATOR;

    address public funder;
    mapping(address => bool) public gasWallets;

    ////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////

    constructor(address _funder, address _orchestrator, address _owner) {
        funder = _funder;
        ORCHESTRATOR = _orchestrator;
        _initializeOwner(_owner);
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allows the owner to withdraw tokens from the funder.
    function withdrawTokens(address token, address recipient, uint256 amount) external onlyOwner {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev Allows the owner to set the funder address.
    function setFunder(address newFunder) external onlyOwner {
        funder = newFunder;
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

    /// @dev Allows the orchestrator to fund an account.
    function fund(
        address account,
        bytes32 digest,
        ICommon.Transfer[] memory transfers,
        bytes memory funderSignature
    ) external {
        if (msg.sender != ORCHESTRATOR) {
            revert OnlyOrchestrator();
        }

        SignatureCheckerLib.isValidSignatureNow(funder, digest, funderSignature);

        for (uint256 i; i < transfers.length; ++i) {
            TokenTransferLib.safeTransfer(transfers[i].token, account, transfers[i].amount);
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
}
