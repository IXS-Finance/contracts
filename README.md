# InvestaX Contracts

Public source for the smart contracts that InvestaX (IXS) runs in production. It is published for auditors, security reviewers, integrators and on-chain tooling.

This repository holds contract source only. Tests, deployment scripts and internal documentation live in the development repository, [IXS-Finance/ixs-vaults-uups](https://github.com/IXS-Finance/ixs-vaults-uups). That repository is private, and access is granted to engaged auditors on request (see [Security](#security)).

## Contracts

| Contract | Standard | Deposits | Redemptions | Used by |
|---|---|---|---|---|
| [`ERC7540OperatedVault`](contracts/ERC7540OperatedVault.sol) | ERC-4626 + ERC-7540 (async deposit and redeem) + ERC-7575 | Async: request, then finalize or reject | Async: request, then finalize or reject | Avalanche, Base, Robinhood Chain |
| [`ManagedVault`](contracts/ManagedVault.sol) | ERC-4626 with an async redemption queue | Synchronous, at the stored NAV | Async: request, then finalize or reject | BSC |

Both contracts are UUPS-upgradeable implementations. Each vault is a fresh implementation behind a plain `ERC1967Proxy`, with no factory and no beacon.

## Deployments (mainnet)

| Vault | Chain | Asset | Whitelist | Contract | Proxy (vault address) | Implementation |
|---|---|---|---|---|---|---|
| IX High Yield Bond (USDC), permissionless | Avalanche C-Chain (43114) | USDC (6 dec) | Off | `ERC7540OperatedVault` | [`0xaD01573b459805E3954398796203d830B57A8bD9`](https://snowscan.xyz/address/0xaD01573b459805E3954398796203d830B57A8bD9) | [`0x648c66E8791B1Ea20f01db549b49dE7FBa3f2a53`](https://snowscan.xyz/address/0x648c66E8791B1Ea20f01db549b49dE7FBa3f2a53) |
| IX High Yield Bond (USDC), permissioned | Avalanche C-Chain (43114) | USDC (6 dec) | On | `ERC7540OperatedVault` | [`0x864E9C192a724773C2bB8C1e84572996074F0B41`](https://snowscan.xyz/address/0x864E9C192a724773C2bB8C1e84572996074F0B41) | [`0x35F8C1ea3b3Be06E5626F057094E498338f7B821`](https://snowscan.xyz/address/0x35F8C1ea3b3Be06E5626F057094E498338f7B821) |
| IX High Yield Bond (USDG) | Robinhood Chain (4663) | USDG (6 dec) | Off | `ERC7540OperatedVault` | [`0x4a8B74A9d246082b671540492222e89c9A866498`](https://robinhoodchain.blockscout.com/address/0x4a8B74A9d246082b671540492222e89c9A866498) | [`0xbBCa80A7116aE46b0F249D279Ef43F86274dc4F4`](https://robinhoodchain.blockscout.com/address/0xbBCa80A7116aE46b0F249D279Ef43F86274dc4F4) |
| ix7540v1 | Base (8453) | USDC (6 dec) | On | `ERC7540OperatedVault` | [`0x864E9C192a724773C2bB8C1e84572996074F0B41`](https://basescan.org/address/0x864E9C192a724773C2bB8C1e84572996074F0B41) | [`0x35F8C1ea3b3Be06E5626F057094E498338f7B821`](https://basescan.org/address/0x35F8C1ea3b3Be06E5626F057094E498338f7B821) |
| ixv1 | BNB Smart Chain (56) | Binance-Peg USDC (**18 dec**) | Off | `ManagedVault` | [`0xc975a3EeF2e49F8eDdEf585340C43f15300fCB82`](https://bscscan.com/address/0xc975a3EeF2e49F8eDdEf585340C43f15300fCB82) | [`0x96D16f6A266fa90702aA3E579aB87F983cEe9FF0`](https://bscscan.com/address/0x96D16f6A266fa90702aA3E579aB87F983cEe9FF0) ¹ |

Notes:

- Always pair an address with its chain. Some addresses repeat across chains (for example `0x864E…0B41` on both Avalanche and Base) because the same deployer and nonce were used. They are separate contracts.
- The BSC asset has 18 decimals; every other asset has 6. Vault shares always have 18 decimals regardless of the asset (see [Decimals](#decimals)).
- Fee settings, custody and whitelist membership change through role-gated calls. Read them on-chain rather than relying on this file.
- ¹ The BSC `ixv1` implementation was deployed from an earlier revision of `ManagedVault`. Its bytecode will not match the source in this repository.

## Shared design

Both vaults issue receipt tokens for a position whose underlying asset is held off-chain by a custodian. The contracts handle share accounting, request queues, fees and access control. Asset execution and custody happen off-chain.

- **Custody forwarding.** Deposited assets are transferred to `custody` in the same transaction. The vault does not hold user assets between deposit and redemption.
- **Redemption funding.** Before a redemption is finalized, custody returns assets to the vault. Finalization then pays the receiver from the vault's balance (`availableAssets()`).
- **Off-chain NAV.** Share price (`pricePerShare`, in asset units and asset-decimal precision) is supplied by a privileged role. No yield or valuation is computed on-chain.
- **NAV deviation guard.** Each price update is bounded by `maxNavChangeBps`. The default is 5,000 (50%); the admin can raise it to at most 100,000 (1,000%).
- **Whitelist.** Optional, set at initialization and toggleable by the admin. It gates subscription and redemption only. Plain `transfer`/`transferFrom` are never gated, so shares stay composable, for example as lending collateral.
- **Sweep guard.** `sweepTokenToCustody` recovers stray ERC-20s to custody. It cannot sweep the vault asset or the vault's own shares.
- **Pause.** Blocks new deposits and new requests. Finalizing or rejecting existing requests is not blocked, so queued users can always be settled.
- **Fees.** Charged in basis points and capped at `MAX_BPS` (10,000). Fee amounts round up; base conversions round down (rounding favors the vault).
- **Minimums.** `minDepositAssets` and `minRedeemAssets` are set by the admin.

### Decimals

Shares always have 18 decimals. The ERC-4626 decimals offset is set to `18 - asset.decimals()` at initialization, and assets with more than 18 decimals are rejected.

## `ERC7540OperatedVault`

A single-asset, pass-through tokenization wrapper. One vault maps to one underlying asset bought and held off-chain. Both sides are asynchronous and settle at the actual execution price of each trade.

**Deposit flow**

1. `requestDeposit(assets, controller, owner)`: the assets are transferred to custody immediately and a pending request is recorded.
2. The operator executes the trade off-chain. It then calls one of:
   - `finalizeDepositRequest(requestId, executionPrice)`, which mints net shares to the controller and fee shares to `feeRecipient`.
   - `rejectDepositRequest(requestId)`, which refunds the assets. Custody must return them to the vault first.

**Redeem flow**

1. `requestRedeem(shares, controller, owner)`: the shares are escrowed in the vault.
2. Custody funds the vault. The operator then calls one of:
   - `finalizeRedeemRequest(requestId, executionPrice)`, which burns the escrowed shares, pays net assets to the controller and pays the fee to `feeRecipient`.
   - `rejectRedeemRequest(requestId)`, which returns the escrowed shares.

**Pricing**

- The `executionPrice` passed at finalization is the only price that sets what a user pays or receives. It is checked against `maxNavChangeBps` relative to the last recorded price, and becomes the new `pricePerShare`.
- `setNAV` is a manual override for out-of-band corrections and in-kind distributions. It never prices a settlement, and `pricePerShare` is otherwise indicative only.
- `navStalenessThreshold` (default 30 days) is a monitoring signal only. It does not gate finalization.

**Fees**

- `subscribeFeeBps` applies on the deposit side and is charged in shares.
- `redeemFeeBps` applies on the redeem side and is charged in assets.
- Both are independent and default to 0.

**ERC-7540 specifics**

- Requests are controller-only: `msg.sender == controller == owner`. Operator delegation is not supported: `isOperator` always returns `false`, and `setOperator(_, true)` returns `false` without reverting.
- It is a push-model vault. Shares and assets are delivered at finalization, so `claimableDepositRequest` and `claimableRedeemRequest` always return 0, and the claim overloads `deposit(uint256,address,address)` and `mint(uint256,address,address)` always revert.
- The synchronous ERC-4626 entry points are disabled: `maxDeposit`, `maxMint`, `maxWithdraw` and `maxRedeem` return 0.
- The vault is its own share token (ERC-7575 `share()`). `supportsInterface` reports the ERC-7540 and ERC-7575 interface IDs.

**Distributions**

Distributions are handled outside this contract:

- Cash payouts go through a separate claim contract.
- Total-return instruments need no action, because execution price already reflects them.
- In-kind distributions are reflected through an occasional `setNAV`.

## `ManagedVault`

An ERC-4626 vault with an externally managed NAV, synchronous subscriptions and queued redemptions.

**Deposits**

- Deposits go through standard ERC-4626 `deposit` and `mint`, priced at the stored `pricePerShare`.
- They are blocked while the vault is paused, while NAV is stale (older than `navStalenessThreshold`, default 48 hours), and until the first `setNAV`.
- When the whitelist is on, both the caller and the receiver must be whitelisted.

**Redemptions**

1. `requestRedeem(shares, receiver)`: the shares are escrowed. The price at request time is recorded for audit-trail purposes only.
2. Custody funds the vault. The operator then calls one of:
   - `finalizeRedeem(id)`, which burns the shares and pays the receiver at the live `pricePerShare` minus `feeBps`. When the whitelist is on, the receiver is re-checked.
   - `rejectRedeem(id)`, which returns the escrowed shares.

Synchronous `withdraw`/`redeem` always revert.

**NAV**

`setNAV(pricePerShare)` is the only price entry point. It is called on a regular cadence by `NAV_MANAGER_ROLE` and bounded by `maxNavChangeBps`. `totalAssets() = totalSupply × pricePerShare / 10^decimals`.

**Fees**

A single `feeBps` is applied on redemption. Use `previewRedeemFee`, `previewWithdrawFee` and `previewFinalizeRedeem` to preview it.

## Roles and trust assumptions

All roles are OpenZeppelin `AccessControl` roles. At initialization the `admin` receives `DEFAULT_ADMIN_ROLE` and the operational roles.

| Role | Powers |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Upgrade the implementation (UUPS `_authorizeUpgrade`). Set custody, fee recipient, fee bps, minimums, NAV staleness threshold, max NAV change, token name and symbol, and the whitelist toggle. Sweep non-asset tokens to custody. Grant and revoke roles. |
| `OPERATOR_ROLE` | Finalize and reject deposit and redeem requests (`ERC7540OperatedVault` supplies the execution price). Manage whitelist membership, up to 200 accounts per batch. |
| `NAV_MANAGER_ROLE` | `setNAV`, within `maxNavChangeBps`. |
| `PAUSER_ROLE` | `pause` / `unpause`. |

What a reviewer should assume:

- Users rely on the operator and custodian to execute trades, hold the underlying and fund redemptions. The contracts do not enforce solvency of custody.
- The operator and NAV manager set prices. On-chain protection is limited to the per-update deviation bound.
- The admin can upgrade the implementation and change economic parameters. Fees are capped at 100%.

## Build settings

Deployed implementations were compiled with:

| Setting | Value |
|---|---|
| Compiler | `solc 0.8.28` |
| Optimizer | Enabled, 200 runs |
| `viaIR` | `true` |
| EVM version | `prague` |
| Dependencies | [`@openzeppelin/contracts`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.3.0) v5.3.0, [`@openzeppelin/contracts-upgradeable`](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/tree/v5.3.0) v5.3.0 |

Import paths use the standard remappings:

```
@openzeppelin/contracts/=<openzeppelin-contracts>/contracts/
@openzeppelin/contracts-upgradeable/=<openzeppelin-contracts-upgradeable>/contracts/
```

## Security

Report vulnerabilities privately to **security@investax.io**. Do not open public issues for security reports.

To request access to the test suite and deployment scripts for an audit engagement, contact the same address.

## License

MIT, as declared in each file's SPDX header.
