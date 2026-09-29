// SPDX-License-Identifier: MIT
// Copyright (c) 2026 IXS
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title IxsToken
 * @notice IXS 2.0 — fixed-supply ERC-20.
 *   - 2.5B minted once, in the constructor, to a single genesis address. No mint function exists.
 *   - Holders can burn their own tokens (burn) or tokens they have an allowance for (burnFrom).
 *   - The owner can only pause / unpause, and transfer or renounce that role.
 *     It cannot mint, move, seize or blacklist tokens.
 *   - Not upgradeable. No permit (EIP-2612).
 * @custom:security-contact security@ixs.finance
 *
 * @dev Stock OpenZeppelin v5 components; the only custom logic is the renounceOwnership guard.
 *   Ownership is two-step (Ownable2Step): transferOwnership only nominates a pending owner, which
 *   must call acceptOwnership to take over. The current owner keeps control until then, and can
 *   re-nominate (or cancel with address(0)). initialOwner is set directly at deployment.
 */
contract IxsToken is ERC20, ERC20Burnable, ERC20Pausable, Ownable2Step {
    /// @notice Supply minted at deployment. Also the all-time maximum: burns can only lower totalSupply().
    uint256 public constant INITIAL_SUPPLY = 2_500_000_000e18;

    /// @param genesis      Receives the entire supply. address(0) reverts (ERC20InvalidReceiver).
    /// @param initialOwner Pause admin, set directly (no accept step). address(0) reverts (OwnableInvalidOwner).
    /// @dev msg.sender is not used: the deployer receives no tokens and no role.
    constructor(address genesis, address initialOwner) ERC20("Ixs Token", "IXS") Ownable(initialOwner) {
        _mint(genesis, INITIAL_SUPPLY);
    }

    /// @notice Halts all balance changes (transfer, transferFrom, burn, burnFrom). Approvals still work.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes transfers and burns.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Renouncing while paused would freeze every balance permanently, so the owner must unpause first.
    function renounceOwnership() public override onlyOwner whenNotPaused {
        super.renounceOwnership();
    }

    // Required override: both ERC20 and ERC20Pausable define _update.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }
}
