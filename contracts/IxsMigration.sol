// SPDX-License-Identifier: MIT
// Copyright (c) 2026 IXS
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev IXS 2.0 (IxsToken) is pausable. Its pause also stops migrate(), since every payout is an IXS 2.0 transfer.
interface IPausableToken {
    function paused() external view returns (bool);
}

/**
 * @title IxsMigration
 * @notice One-way IXS 1.0 -> IXS 2.0 swap on Robinhood Chain: 1 IXS 1.0 in, 10 IXS 2.0 out, same transaction.
 *   - IXS 1.0 is the canonical Arbitrum-bridged token, fixed at deployment. Any other "IXS" is rejected.
 *   - IXS 2.0 is pre-funded by a plain ERC-20 transfer (Fireblocks holder vault). This contract never mints.
 *   - Migrated IXS 1.0 is locked forever: no function can move it. Only stray IXS 1.0 sent here directly
 *     (balance above totalMigrated) can be swept.
 *   - The owner can pause / unpause migrate(), and sweep IXS 2.0, stray IXS 1.0, or any other token.
 *   - Pausing IXS 2.0 (IxsToken.pause, by its own owner) also stops migrate(): every payout is an IXS 2.0
 *     transfer. paused() here does not show it; availableToMigrate() does (0 while either is paused).
 *   - Not upgradeable. renounceOwnership is blocked while paused, so the contract can never be left paused
 *     with no owner. To close the migration: sweep IXS 2.0, then renounce. Pausing first is optional and
 *     only stops a swap landing between the balance read and the sweep; unpause before renouncing. An empty,
 *     unpaused contract rejects every migrate() for lack of IXS 2.0, and reopens if it is ever funded again.
 * @custom:security-contact security@investax.io
 *
 * @dev Both tokens are 18-decimal standard ERC-20s with no transfer hooks or fees, so 1:10 on raw amounts is exact
 *   (the constructor rejects tokens with different decimals)
 *   and no reentrancy guard is needed (state is written before any external call regardless).
 */
contract IxsMigration is Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice IXS 2.0 paid out per IXS 1.0 migrated.
    uint256 public constant RATIO = 10;

    /// @notice Canonical bridged IXS 1.0 on Robinhood Chain (taken in, locked forever).
    IERC20 public immutable IXS_V1;
    /// @notice IXS 2.0 (paid out from this contract's balance).
    IERC20 public immutable IXS_V2;

    /// @notice IXS 1.0 locked through migrate(). IXS 2.0 paid out is always totalMigrated * RATIO.
    uint256 public totalMigrated;

    event Migrated(address indexed account, uint256 ixsV1In, uint256 ixsV2Out);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error SameToken();
    error DecimalsMismatch(uint8 ixsV1Decimals, uint8 ixsV2Decimals);
    error ZeroAmount();
    error MigratedIxsV1Locked(uint256 sweepable, uint256 requested);

    /// @param ixsV1        Canonical bridged IXS 1.0. Checked against the Arbitrum gateway in the deploy script.
    /// @param ixsV2        IXS 2.0 token. Must expose paused() (IxsToken does): availableToMigrate() reads it.
    /// @param initialOwner Admin (pause, sweep), set directly. address(0) reverts (OwnableInvalidOwner).
    constructor(IERC20 ixsV1, IERC20 ixsV2, address initialOwner) Ownable(initialOwner) {
        if (address(ixsV1) == address(0) || address(ixsV2) == address(0)) revert ZeroAddress();
        if (address(ixsV1) == address(ixsV2)) revert SameToken();
        // 1:10 runs on raw amounts, so both tokens must use the same decimals or the ratio is wrong forever.
        uint8 v1Decimals = IERC20Metadata(address(ixsV1)).decimals();
        uint8 v2Decimals = IERC20Metadata(address(ixsV2)).decimals();
        if (v1Decimals != v2Decimals) revert DecimalsMismatch(v1Decimals, v2Decimals);
        // availableToMigrate() reads IXS 2.0's paused(); a token without it would brick that view, so
        // probe it here and let a wrong token address fail at deployment (Zokyo v1 #25).
        IPausableToken(address(ixsV2)).paused();
        IXS_V1 = ixsV1;
        IXS_V2 = ixsV2;
    }

    // =========================================================
    // Holder
    // =========================================================

    /// @notice Swap `amount` IXS 1.0 for `amount * RATIO` IXS 2.0, paid to the caller.
    ///   Requires an IXS 1.0 allowance of `amount`. Reverts if this contract holds too little IXS 2.0.
    function migrate(uint256 amount) external whenNotPaused returns (uint256 ixsV2Out) {
        if (amount == 0) revert ZeroAmount();
        ixsV2Out = amount * RATIO;
        totalMigrated += amount;

        IXS_V1.safeTransferFrom(msg.sender, address(this), amount);
        IXS_V2.safeTransfer(msg.sender, ixsV2Out);

        emit Migrated(msg.sender, amount, ixsV2Out);
    }

    /// @notice Most IXS 1.0 that migrate() can take right now: 0 while this contract or the IXS 2.0 token
    ///   is paused (either makes migrate() revert), otherwise the IXS 2.0 balance / RATIO.
    function availableToMigrate() external view returns (uint256) {
        if (paused() || IPausableToken(address(IXS_V2)).paused()) return 0;
        return IXS_V2.balanceOf(address(this)) / RATIO;
    }

    /// @notice IXS 1.0 sent here without migrate(). The only IXS 1.0 sweep() can move.
    function sweepableIxsV1() public view returns (uint256) {
        uint256 balance = IXS_V1.balanceOf(address(this));
        return balance > totalMigrated ? balance - totalMigrated : 0;
    }

    // =========================================================
    // Admin
    // =========================================================

    /// @notice Stops migrate(). Sweep and ownership functions keep working.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Renouncing while paused would freeze migrate() and every balance here permanently,
    ///   so the owner must unpause first.
    function renounceOwnership() public override onlyOwner whenNotPaused {
        super.renounceOwnership();
    }

    /// @notice Move any token out: unspent IXS 2.0, other tokens sent by mistake, or stray IXS 1.0
    ///   (up to sweepableIxsV1()). Migrated IXS 1.0 can never be swept. Works while paused.
    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (address(token) == address(IXS_V1)) {
            uint256 sweepable = sweepableIxsV1();
            if (amount > sweepable) revert MigratedIxsV1Locked(sweepable, amount);
        }
        token.safeTransfer(to, amount);
        emit Swept(address(token), to, amount);
    }
}
