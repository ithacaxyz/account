// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ECDSA} from "solady/utils/ECDSA.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";

/// @title AccountRegistry
/// @dev This is a simple on-chain storage for user accounts in a form of mapping
/// ID -> (Data, Address[]). To avoid front-running, the ID is not an arbitrary value, but
/// an address that needs to sign the payload mapping is initialized with.
///
/// Once the ID is occupied, the only way it can be modified is by appending a new account.
/// The only way to append an account is by invoking `appendAccount` method from an already
/// registered account.
contract AccountRegistry {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @dev The ID has already been registered.
    error IDOccupied();

    /// @dev Caller is not authorized to modify the ID.
    error InvalidCaller();

    /// @dev Account is already registered in the ID.
    error AlreadyRegistered();

    /// @dev Contents of an ID. Each ID is associated with an arbitrary
    /// user-defined data blob and a list of accounts.
    struct StoredAccounts {
        /// @dev Arbitrary data associated with the ID.
        bytes data;
        /// @dev Accounts associated with the ID.
        EnumerableSetLib.AddressSet accounts;
    }

    /// @dev The storage of the contract.
    struct AccountRegistryStorage {
        /// @dev Mapping of ID to the stored accounts.
        mapping(address id => StoredAccounts) accounts;
    }

    /// @dev Returns the storage pointer.
    function _getAccountRegistryStorage()
        internal
        pure
        returns (AccountRegistryStorage storage $)
    {
        // Truncate to 9 bytes to reduce bytecode size.
        uint256 s = uint72(bytes9(keccak256("PORTO_ACCOUNT_REGISTRY_STORAGE")));
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    /// @dev Returns the state of given IDs, including the data and accounts.
    /// @param ids Array of IDs to lookup.
    function idInfos(address[] calldata ids)
        public
        view
        returns (bytes[] memory datas, address[][] memory accounts)
    {
        datas = new bytes[](ids.length);
        accounts = new address[][](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            StoredAccounts storage storedAccounts = _getAccountRegistryStorage().accounts[ids[i]];
            datas[i] = storedAccounts.data;
            accounts[i] = storedAccounts.accounts.values();
        }
    }

    /// @dev Registers a new ID with the given `data` and `account`.
    /// @param signature Signature over `keccak256(abi.encode(data, account))`. The recovered signer
    /// is the ID.
    /// @param data Arbitrary data blob to associate with the ID.
    /// @param account First account to associate with the ID.
    function register(bytes calldata signature, bytes calldata data, address account) external {
        address id = ECDSA.recoverCalldata(keccak256(abi.encode(data, account)), signature);
        StoredAccounts storage accounts = _getAccountRegistryStorage().accounts[id];

        if (accounts.accounts.length() > 0) revert IDOccupied();

        accounts.data = data;
        accounts.accounts.add(account);
    }

    /// @dev Appends a new account to the ID. This is useful when a user wants to associate a key with multiple accounts.
    /// We require the caller of this method to be an already registered account.
    /// @param id Inititalized ID to append the account to.
    /// @param account Account to append to the ID.
    function appendAccount(address id, address account) external {
        StoredAccounts storage accounts = _getAccountRegistryStorage().accounts[id];

        if (!accounts.accounts.contains(msg.sender)) revert InvalidCaller();
        if (accounts.accounts.contains(account)) revert AlreadyRegistered();

        accounts.accounts.add(account);
    }

    /// @dev Removes the account from the ID. This is useful when a user wants to disassociate a key from an account.
    /// Must be invoked by the account itself.
    function removeAccount(address id) external {
        AccountRegistryStorage storage $ = _getAccountRegistryStorage();

        if (!$.accounts[id].accounts.contains(msg.sender)) revert InvalidCaller();
        $.accounts[id].accounts.remove(msg.sender);

        if ($.accounts[id].accounts.length() == 0) {
            delete $.accounts[id];
        }
    }
}
