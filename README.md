# <h1 align="center"> Account </h1>

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/ithacaxyz/account)

> 🚧 **Work In Progress**  
> This repository is under active development. Contracts are **unaudited**, and the codebase may have **breaking changes** without notice.  
> A bug bounty is live on Base Mainnet — [details here](docs/bug-bounty.md).

**All-in-one EIP-7702 powered account contract, coupled with [Porto](https://github.com/ithacaxyz/porto)**

Every app needs an account, traditionally requiring separate services for auth, payments, and recovery. Doing this in a way that empowers users with control over their funds and their data is the core challenge of the crypto space. While crypto wallets have made great strides, users still face a fragmented experience - juggling private keys, managing account balances across networks,
having to install browser extensions, and more.

We believe that unstoppable crypto-powered accounts should be excellent throughout a user's journey:

- **Onboarding**: No key management using WebAuthn and Passkeys. KYC-less fiat onramping. No kicking of the user to 3rd party applications, fully embedded experience with headless wallet.
- **Verifying their identity**: Privacy-preserving identity verification with [ZK Passport](https://www.openpassport.app/) or other techniques.
- **Transacting safely**: Access [control policies](src/GuardedExecutor.sol) baked in with sensible defaults in smart contracts.
- **Transacting privately**: Built-in privacy using [stealth addresses](https://vitalik.eth.limo/general/2023/01/20/stealth.html) or other designs.
- **Transacting seamlessly across chains**: Single address with automatic fund transfers between chains.
- **Recovering their account**: Multi-path recovery via social, [email](https://github.com/zkemail), [OAuth](https://github.com/olehmisar/zklogin/pull/2), or other identity providers.
- **No vendor lock-in**: No vendor lock-in, built on top of standards that have powered Ethereum for years.

# Features out of the box

- [x] Secure Login: Using WebAuthN-compatible credentials like PassKeys.
- [x] Call Batching: Send multiple calls in 1.
- [x] Gas Sponsorship: Allow anyone to pay for your fees in any ERC20 or ETH.
- [x] Access Control: Whitelist receivers, function selectors and arguments.
- [x] Session Keys: Allow transactions without confirmations if they pass low-security access control policies.
- [x] Multi-sig Support: If a call is outside of a certain access control policy, require multiple signatures.
- [x] Interop: Transaction on any chain invisibly. 
- [ ] Timelocks: Add a time delay between transaction verification and execution, for additional safety.
- [ ] Optimized for L2: Using BLS signatures.
- [ ] Privacy: Using stealth addresses, confidential ERC20 tokens, and privacy pool integrations.
- [ ] Account Recovery & Identity: Using ZK {Email, OAUth, Passport} and more.

## Getting Help

Have questions or building something cool with Porto Accounts?  
Join the Telegram group to chat with the team and other devs: [@porto_devs](https://t.me/porto_devs)
