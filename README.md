# IXS Contracts

Smart contract source for IXS, published for auditors, reviewers and integrators.

Tests and deployment scripts live in [IXS-Finance/ixs-vaults-uups](https://github.com/IXS-Finance/ixs-vaults-uups). That repository is private; access is available on request.

## `IxsToken`

[`contracts/IxsToken.sol`](contracts/IxsToken.sol): the IXS 2.0 ERC-20 token. **Not deployed yet.**

- 2.5B IXS are minted once, in the constructor, to `genesis`. No mint function exists.
- Holders can `burn` their own tokens, or `burnFrom` with an allowance.
- The owner (`Ownable2Step`) can only `pause`/`unpause`, which halts all transfers and burns. It cannot mint, move, seize or blacklist tokens.
- `renounceOwnership` is blocked while paused.
- Not upgradeable. No permit.

**Scope:** one file, 56 lines. It is built from stock OpenZeppelin v5.3.0 components (`ERC20`, `ERC20Burnable`, `ERC20Pausable`, `Ownable2Step`). The only custom logic is the `renounceOwnership` guard.

## Contracts

| Contract | What it is | Upgradeable | Status |
|---|---|---|---|
| [`IxsToken`](contracts/IxsToken.sol) | IXS 2.0 ERC-20, fixed 2.5B supply | No | Not deployed |
| [`ERC7540OperatedVault`](contracts/ERC7540OperatedVault.sol) | ERC-4626 vault with async deposits and redemptions (ERC-7540) | UUPS | Live |
| [`ManagedVault`](contracts/ManagedVault.sol) | ERC-4626 vault with sync deposits and queued redemptions | UUPS | Live |

## Vault deployments

| Vault | Chain | Asset | Contract | Proxy | Implementation |
|---|---|---|---|---|---|
| IX High Yield Bond (USDC), permissionless | Avalanche (43114) | USDC | `ERC7540OperatedVault` | [`0xaD01573b459805E3954398796203d830B57A8bD9`](https://snowscan.xyz/address/0xaD01573b459805E3954398796203d830B57A8bD9) | [`0x648c66E8791B1Ea20f01db549b49dE7FBa3f2a53`](https://snowscan.xyz/address/0x648c66E8791B1Ea20f01db549b49dE7FBa3f2a53) |
| IX High Yield Bond (USDC), permissioned | Avalanche (43114) | USDC | `ERC7540OperatedVault` | [`0x864E9C192a724773C2bB8C1e84572996074F0B41`](https://snowscan.xyz/address/0x864E9C192a724773C2bB8C1e84572996074F0B41) | [`0x35F8C1ea3b3Be06E5626F057094E498338f7B821`](https://snowscan.xyz/address/0x35F8C1ea3b3Be06E5626F057094E498338f7B821) |
| IX High Yield Bond (USDG) | Robinhood Chain (4663) | USDG | `ERC7540OperatedVault` | [`0x4a8B74A9d246082b671540492222e89c9A866498`](https://robinhoodchain.blockscout.com/address/0x4a8B74A9d246082b671540492222e89c9A866498) | [`0xbBCa80A7116aE46b0F249D279Ef43F86274dc4F4`](https://robinhoodchain.blockscout.com/address/0xbBCa80A7116aE46b0F249D279Ef43F86274dc4F4) |
| ix7540v1 | Base (8453) | USDC | `ERC7540OperatedVault` | [`0x864E9C192a724773C2bB8C1e84572996074F0B41`](https://basescan.org/address/0x864E9C192a724773C2bB8C1e84572996074F0B41) | [`0x35F8C1ea3b3Be06E5626F057094E498338f7B821`](https://basescan.org/address/0x35F8C1ea3b3Be06E5626F057094E498338f7B821) |
| ixv1 | BNB Chain (56) | USDC (18 dec) | `ManagedVault` | [`0xc975a3EeF2e49F8eDdEf585340C43f15300fCB82`](https://bscscan.com/address/0xc975a3EeF2e49F8eDdEf585340C43f15300fCB82) | [`0x96D16f6A266fa90702aA3E579aB87F983cEe9FF0`](https://bscscan.com/address/0x96D16f6A266fa90702aA3E579aB87F983cEe9FF0) ¹ |

- Some addresses repeat across chains because the same deployer and nonce were used. Always pair an address with its chain.
- ¹ Deployed from an earlier revision of `ManagedVault`, so its bytecode does not match the source here.

## Vaults

Both vaults issue 18-decimal shares against an asset held off-chain by a custodian. Deposits are forwarded to `custody` immediately. Custody funds the vault before a redemption is finalized.

**`ERC7540OperatedVault`**
- Deposit: `requestDeposit`, then the operator calls `finalizeDepositRequest(id, executionPrice)` to mint shares, or `rejectDepositRequest` to refund.
- Redeem: `requestRedeem` escrows shares, then the operator calls `finalizeRedeemRequest(id, executionPrice)` to pay out, or `rejectRedeemRequest` to return the shares.
- Settlement uses the execution price only. `setNAV` is a manual override and never prices a settlement.
- Fees: `subscribeFeeBps` (taken in shares) and `redeemFeeBps` (taken in assets).
- Requests are controller-only, with no operator delegation. It is a push model: `claimable*` views always return 0, and the sync ERC-4626 entry points are disabled.

**`ManagedVault`**
- Deposit: sync `deposit`/`mint` at `pricePerShare`. Blocked while paused or while NAV is stale (default 48h).
- Redeem: `requestRedeem`, then the operator calls `finalizeRedeem` (pays out at live NAV minus `feeBps`) or `rejectRedeem`. Sync `withdraw`/`redeem` revert.
- NAV is set by `setNAV`.

**Both**
- Every price update is bounded by `maxNavChangeBps` (default 50%).
- The optional whitelist gates deposits and requests only, never transfers.
- Pause blocks new deposits and requests, never finalization or rejection.
- `sweepTokenToCustody` cannot move the vault asset or vault shares.
- Fees are capped at 100% and round in the vault's favor.

**Roles**

| Role | Can |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Upgrade; set custody, fees, fee recipient, minimums, NAV limits, name/symbol and the whitelist toggle; sweep; manage roles |
| `OPERATOR_ROLE` | Finalize/reject requests; manage the whitelist (max 200 per batch) |
| `NAV_MANAGER_ROLE` | `setNAV` |
| `PAUSER_ROLE` | `pause` / `unpause` |

**Trust assumptions:** users rely on the operator and custodian to execute trades, hold the underlying and fund redemptions. Custody solvency is not enforced on-chain. The admin can upgrade the contract and change parameters.

## Build

`solc 0.8.28`, optimizer 200 runs, `viaIR = true`, EVM `prague`. Dependencies: [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.3.0) and [Contracts Upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/tree/v5.3.0), both v5.3.0, with the standard `@openzeppelin/` remappings.

## Security

Report vulnerabilities to **security@ixs.finance**. Don't open public issues.

## License

MIT
