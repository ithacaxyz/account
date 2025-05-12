// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

abstract contract PauseAuthority {
    /// @dev Unauthorized to perform this action.
    error Unauthorized();

    /// @dev The pause flag has been updated.
    event PauseSet(bool indexed isPaused);

    /// @dev The pause authority has been set to `pauseAuthority`.
    event PauseAuthoritySet(address indexed pauseAuthority);

    /// @dev Time period after which the contract can be unpaused by anyone.
    uint256 public constant PAUSE_TIMEOUT = 4 weeks;

    /// @dev The pause flag.
    uint256 public pauseFlag;

    /// @dev The pause configuration.
    /// - The lower 160 bits store the pause authority.
    /// - The 40 bits after that store the last paused timestamp.
    uint256 internal _pauseConfig;

    /// @dev Can be used to pause/unpause the contract, in case of emergencies.
    /// - Pausing the contract will make all signature validations fail,
    ///   effectively blocking all pay, execute, isValidSignature attempts.
    /// - The `pauseAuthority` can unpause the contract at any time.
    /// - Anyone can unpause the contract after the PAUSE_TIMEOUT has passed.
    /// - Note: Contracts CANNOT be paused again until PAUSE_TIMEOUT + 1 week has passed.
    ///   This is done to prevent griefing attacks, where a malicious pauseAuthority,
    ///   keeps censoring the user.
    function pause(bool isPause) public virtual {
        (address authority, uint40 lastPaused) = getPauseConfig();
        uint256 timeout = lastPaused + PAUSE_TIMEOUT;

        if (isPause) {
            // Account owners, can use this 1 week buffer, to migrate,
            // if they don't trust the pauseAuthority.
            if (msg.sender != authority || block.timestamp < timeout + 1 weeks || pauseFlag == 1) {
                revert Unauthorized();
            }

            // Set the pause flag.
            pauseFlag = 1;
            _pauseConfig = (block.timestamp << 160) | uint256(uint160(authority));
        } else {
            if (msg.sender == authority || block.timestamp > timeout) {
                // Unpause the contract.
                pauseFlag = 0;
            } else {
                revert Unauthorized();
            }
        }

        emit PauseSet(isPause);
    }

    /// @dev Returns the pause authority and the last pause timestamp.
    function getPauseConfig() public view virtual returns (address, uint40) {
        return (address(uint160(_pauseConfig)), uint40(_pauseConfig >> 160));
    }

    function setPauseAuthority(address newPauseAuthority) public virtual {
        (address authority, uint40 lastPaused) = getPauseConfig();
        if (msg.sender != authority) {
            revert Unauthorized();
        }

        _pauseConfig = (uint256(lastPaused) << 160) | uint160(newPauseAuthority);

        emit PauseAuthoritySet(newPauseAuthority);
    }
}
