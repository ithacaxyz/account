// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFunder} from "./interfaces/IFunder.sol";
import {ICommon} from "./interfaces/ICommon.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";

contract SimpleFunder is Ownable, IFunder {
    error onlyOrchestrator();

    address public funder;
    address public orchestrator;

    constructor(address _funder, address _orchestrator, address _owner) {
        funder = _funder;
        orchestrator = _orchestrator;
        _initializeOwner(_owner);
    }

    function fund(
        address account,
        bytes32 digest,
        ICommon.Transfer[] memory transfers,
        bytes memory funderSignature
    ) external {
        if (msg.sender != orchestrator) {
            revert onlyOrchestrator();
        }

        SignatureCheckerLib.isValidSignatureNow(funder, digest, funderSignature);

        for (uint256 i; i < transfers.length; ++i) {
            TokenTransferLib.safeTransfer(transfers[i].token, account, transfers[i].amount);
        }
    }

    function setFunder(address newFunder) external onlyOwner {
        funder = newFunder;
    }

    function setOrchestrator(address newOrchestrator) external onlyOwner {
        orchestrator = newOrchestrator;
    }
}
