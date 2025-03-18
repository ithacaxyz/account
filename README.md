# <h1 align="center"> Account </h1>

**All-in-one EIP-7702 powered delegation contract, coupled with [Porto](https://github.com/ithacaxyz/porto)**

Every app needs an account, traditionally requiring separate services for auth, payments, and recovery. Doing this in a way that empowers users with control over their funds and their data is the core challenge of the crypto space. While crypto wallets have made great strides, users still face a fragmented experience - juggling private keys, managing account balances across networks, 
having to install browser extensions, and more.

We believe that unstoppable crypto-powered accounts should be excellent throughout a user's journey:

- **Onboarding**: No key management using WebAuthn and Passkeys. KYC-less fiat onramping. No kicking of the user to 3rd party applications, fully embedded experience with headless wallet.
- **Verifying their identity**: Privacy-preserving identity verification with [ZK Passport](https://www.openpassport.app/) or other techniques.
- **Transacting safely**: Access [control policies](b/main/src/GuardedExecutor.sol) baked in with sensible defaults in smart contracts.
- **Transacting privately**: Built-in privacy using [stealth addresses](https://vitalik.eth.limo/general/2023/01/20/stealth.html) and [confidential transactions](https://eips.ethereum.org/EIPS/eip-4491).
- **Transacting seamlessly across chains**: Single address with automatic gas handling across chains using [ERC7683](https://eips.ethereum.org/EIPS/eip-7683).
- **Recovering their account**: Multi-path recovery via social, [email](https://github.com/zkemail), [OAuth](https://github.com/olehmisar/zklogin/pull/2), or other identity providers.
- **No vendor lock-in**: No vendor lock-in, built on top of standards that have powered Ethereum for years.

# Features out of the box

## Currently Implemented

* [x] **Secure Login**: Using WebAuthN-compatible credentials like PassKeys. Implementation complete with support for multiple passkeys per account.
* [x] **Call Batching**: Send multiple calls in 1. Fully optimized for gas efficiency.
* [x] **Gas Sponsorship**: Allow anyone to pay for your fees in any ERC20 or ETH. Implementation includes fee abstraction and relayer compensation.
* [x] **Access Control**: Whitelist receivers, function selectors and arguments. Comprehensive policy system already in place.
* [x] **Session Keys**: Allow transactions without confirmations if they pass low-security access control policies. Implementation includes time-based expiry.

## Coming Soon (Q3 2023)

* [ ] **Multi-factor Authentication**: If a call is outside of a certain access control policy, require multiple signatures. Implementation will support hardware security keys, mobile authenticators, and biometric verification.
* [ ] **Optimized for L2**: Using BLS signatures to reduce verification costs and improve transaction throughput on Layer 2 networks.

## In Development (Q4 2023)

* [ ] **Chain Abstraction**: Transaction on any chain invisibly. Powered by ERC7683. Development is in progress with initial testnet deployments planned for early Q4.
* [ ] **Privacy**: Using stealth addresses and confidential transactions. Technical research phase completed, implementation beginning soon.
* [ ] **Account Recovery & Identity**: Using ZK {Email, OAUth, Passport} and more. Integration with multiple identity providers is in progress.

## Additional Planned Features

* [ ] **Delegation Limits**: Set spending limits for different keys and delegates.
* [ ] **Social Recovery**: Support for guardian-based account recovery methods.
* [ ] **Subscription Management**: Built-in support for managing recurring payments and subscriptions.
* [ ] **Cross-chain Messaging**: Native support for cross-chain asset transfers and message passing.
