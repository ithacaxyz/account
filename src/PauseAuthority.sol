// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

abstract contract PauseAuthority {
    /// @dev Unauthorized to perform this action.
    error Unauthorized();

    /// @dev Timelock delay has not passed yet.
    error TimelockNotExpired();

    /// @dev The pause flag has been updated.
    event PauseSet(bool indexed isPaused);

    /// @dev The pause authority has been set to `pauseAuthority`.
    event PauseAuthoritySet(address indexed pauseAuthority);

    /// @dev A new pause authority change has been proposed.
    event PauseAuthorityProposed(address indexed newPauseAuthority);

    /// @dev Time period after which the contract can be unpaused by anyone.
    uint256 public constant PAUSE_TIMEOUT = 4 weeks;

    /// @dev Cooldown period before the contract can be paused again.
    uint256 public constant PAUSE_COOLDOWN = 48 hours;

    /// @dev Timelock delay for changing pause authority.
    uint256 public constant PAUSE_AUTHORITY_TIMELOCK = 48 hours;

    /// @dev The pause flag.
    uint256 public pauseFlag;

    /// @dev The pause configuration.
    /// - The lower 160 bits store the pause authority.
    /// - The 40 bits after that store the last unpaused timestamp.
    uint256 internal _pauseConfig;

    /// @dev Proposed pause authority change.
    /// - The lower 160 bits store the proposed pause authority.
    /// - The 40 bits after that store the effective timestamp.
    uint256 internal _proposedPauseAuthorityChange;

    /// @dev Can be used to pause/unpause the contract, in case of emergencies.
    /// - Pausing the contract will make all signature validations fail,
    ///   effectively blocking all pay, execute, isValidSignature attempts.
    /// - The `pauseAuthority` can unpause the contract at any time.
    /// - Anyone can unpause the contract after the PAUSE_TIMEOUT has passed.
    /// - Note: Contracts CANNOT be paused again until PAUSE_COOLDOWN has passed.
    ///   This is done to prevent griefing attacks, where a malicious pauseAuthority,
    ///   keeps censoring the user.
    function pause(bool isPause) public virtual {
        (address authority, uint40 lastUnpaused) = getPauseConfig();
        uint256 timeout = lastUnpaused + PAUSE_TIMEOUT;

        if (isPause) {
            // Account owners can use this buffer to migrate,
            // if they don't trust the pauseAuthority.
            if (msg.sender != authority || block.timestamp < lastUnpaused + PAUSE_COOLDOWN || pauseFlag == 1) {
                revert Unauthorized();
            }

            // Set the pause flag.
            pauseFlag = 1;
            // Don't update lastUnpaused timestamp when pausing
        } else {
            if (msg.sender == authority || block.timestamp > timeout) {
                // Unpause the contract and update lastUnpaused timestamp.
                pauseFlag = 0;
                _pauseConfig = (block.timestamp << 160) | uint256(uint160(authority));
            } else {
                revert Unauthorized();
            }
        }

        emit PauseSet(isPause);
    }

    /// @dev Returns the pause authority and the last unpaused timestamp.
    function getPauseConfig() public view virtual returns (address, uint40) {
        return (address(uint160(_pauseConfig)), uint40(_pauseConfig >> 160));
    }

    /// @dev Returns the proposed pause authority change details.
    function getProposedAuthority() public view virtual returns (address, uint40) {
        return (address(uint160(_proposedPauseAuthorityChange)), uint40(_proposedPauseAuthorityChange >> 160));
    }

    /// @dev Proposes a new pause authority with a timelock delay.
    function proposeNewAuthority(address newPauseAuthority) public virtual {
        (address authority,) = getPauseConfig();
        if (msg.sender != authority) {
            revert Unauthorized();
        }

        uint256 effectiveTime = block.timestamp + PAUSE_AUTHORITY_TIMELOCK;
        _proposedPauseAuthorityChange = (effectiveTime << 160) | uint160(newPauseAuthority);

        emit PauseAuthorityProposed(newPauseAuthority);
    }

    /// @dev Executes a previously proposed pause authority change after the timelock has expired.
    function executeNewAuthority() public virtual {
        (address currentAuthority, uint40 lastUnpaused) = getPauseConfig();
        if (msg.sender != currentAuthority) {
            revert Unauthorized();
        }

        (address proposedAuthority, uint40 effectiveTime) = getProposedAuthority();
        
        if (proposedAuthority == address(0) || block.timestamp < effectiveTime) {
            revert TimelockNotExpired();
        }

        // Update the pause authority
        _pauseConfig = (uint256(lastUnpaused) << 160) | uint160(proposedAuthority);
        
        // Clear the proposed change
        _proposedPauseAuthorityChange = 0;

        emit PauseAuthoritySet(proposedAuthority);
    }
}
