// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title PauseAuthority
/// @notice A mixin for that turns a contract to a pause beacon.
/// @dev This is intended to be inherited by the Orchestrator, and serves as a
/// training wheels until we are more certain of the correctness.
abstract contract PauseAuthority {
    /// @dev Unauthorized to perform this action.
    error Unauthorized();

    /// @dev The pause flag has been updated.
    event PauseSet(bool indexed isPaused);

    /// @dev The pause admin has been set to `pauseAdmin`.
    event PauseAdminSet(address indexed pauseAdmin);

    /// @dev Time period after which the contract can be unpaused by anyone.
    uint256 public constant PAUSE_TIMEOUT = 4 weeks;

    /// @dev The pause flag.
    uint256 public pauseFlag;

    /// @dev The pause configuration.
    /// - The lower 160 bits store the pause admin.
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
        (address admin, uint40 lastPaused) = getPauseConfig();
        uint256 timeout = lastPaused + PAUSE_TIMEOUT;

        if (isPause) {
            // Account owners, can use this 1 week buffer, to migrate,
            // if they don't trust the pauseAuthority.
            if (msg.sender != admin || block.timestamp < timeout + 1 weeks || pauseFlag == 1) {
                revert Unauthorized();
            }

            // Set the pause flag.
            pauseFlag = 1;
            _pauseConfig = (block.timestamp << 160) | uint256(uint160(admin));
        } else {
            if (msg.sender == admin || block.timestamp > timeout) {
                // Unpause the contract.
                pauseFlag = 0;
            } else {
                revert Unauthorized();
            }
        }

        emit PauseSet(isPause);
    }

    /// @dev Returns the pause admin and the last pause timestamp.
    function getPauseConfig() public view virtual returns (address, uint40) {
        return (address(uint160(_pauseConfig)), uint40(_pauseConfig >> 160));
    }

    function setPauseAuthority(address newPauseAdmin) public virtual {
        (address authority, uint40 lastPaused) = getPauseConfig();
        if (msg.sender != authority) {
            revert Unauthorized();
        }

        _pauseConfig = (uint256(lastPaused) << 160) | uint160(newPauseAdmin);

        emit PauseAdminSet(newPauseAdmin);
    }
}
