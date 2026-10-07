// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {AscendVault} from "./AscendVault.sol";

/// @title AscendVaultGuarded
/// @notice Guarded extension of {AscendVault}: explicit capital controls and
///         a loss-aware emergency exit, layered on the base vault with no
///         behavior change to the base source or to the two live deployed
///         vaults (independent deployments of the base).
///
///         Owner-controlled surfaces:
///          * {totalAssetCap}: hard ceiling on {totalAssets()} (idle +
///            invested), enforced on deposit/mint via ERC-4626 max* views
///            plus a defense-in-depth gate in {_deposit}. Zero = unbounded.
///          * {setDepositsPaused}: blocks deposit/mint only. Withdrawals,
///            redeems, and {investIdle} stay open — a deposit freeze must
///            never trap user capital.
///          * {emergencyExitStrategy}: when the bound strategy cannot
///            satisfy the strict {exitStrategy} settlement, accept whatever
///            it actually returns (real balance delta), clear the ledger to
///            that settled reality, and emit the realized loss.
///          * {abandonStrategy}: when the strategy cannot return anything at
///            all (reverting divest), relinquish it: zero the ledger (full
///            loss accounting) and free rebinding. Assets the strategy
///            later repays land as idle balance (donation accounting)
///            instead of being mis-accounted.
///
///         Deliberately NOT implemented: a blanket pause or a withdrawal
///         freeze. User assets stay recoverable through withdraw/redeem at
///         all times; the base contract's strict settlement checks refuse to
///         mis-account trapped capital (whole operation reverts) rather than
///         pausing redemptions or re-pricing shares over losses.
/// @dev The base contract's fee flows, reentrancy guards, and settlement
///      verification are inherited unchanged. `nonReentrant` is NOT
///      re-specified on the {_deposit} hook override: the guard lives on the
///      base hook in the same call chain; repeating it would deadlock every
///      deposit.
contract AscendVaultGuarded is AscendVault {
    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice Maximum total assets (idle + invested). Zero = unbounded.
    uint256 private _totalAssetCap;

    /// @notice True while deposit/mint are blocked by the owner.
    bool private _depositsPaused;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice Deposit/mint would push {totalAssets()} above the cap.
    error VaultCapacityExceeded(uint256 projectedTotal, uint256 cap);

    /// @notice A forward-looking cap may not be set below the assets the
    ///         vault already manages.
    error CapBelowTotalAssets(uint256 cap, uint256 totalAssets);

    /// @notice Deposits and mints are paused by the owner.
    error DepositsPaused();

    /// @notice Emergency exit attempted while nothing is invested.
    error NothingInvested();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice Emitted when the owner changes the total-asset cap.
    event VaultCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the owner pauses or unpauses deposits.
    event DepositsPausedUpdated(bool paused);

    /// @notice Emitted when the owner accepts a realized loss on the bound
    ///         strategy: `settled` is the asset amount actually returned by
    ///         the strategy (0 for {abandonStrategy}); `loss` is the part of
    ///         the ledgered investment written off.
    event StrategyForfeited(address indexed strategy, uint256 settled, uint256 loss);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @notice Deploys the guarded vault. Inherits {AscendVault}'s dormant
    ///         fee architecture, strategy-ledger accounting, and settlement
    ///         checks unchanged.
    /// @param asset_ Underlying ERC-20 asset accepted by the vault.
    /// @param name_ ERC-20 name of the vault share token.
    /// @param symbol_ ERC-20 symbol of the vault share token.
    /// @param initialOwner_ Account granted ownership of all admin controls.
    constructor(IERC20 asset_, string memory name_, string memory symbol_, address initialOwner_)
        AscendVault(asset_, name_, symbol_, initialOwner_)
    {}

    // ------------------------------------------------------------------
    // Public reads
    // ------------------------------------------------------------------

    /// @notice Configured maximum total assets. Zero = unbounded.
    function totalAssetCap() external view returns (uint256) {
        return _totalAssetCap;
    }

    /// @notice True while deposit/mint are paused.
    function depositsPaused() external view returns (bool) {
        return _depositsPaused;
    }

    // ------------------------------------------------------------------
    // ERC-4626 capacity enforcement
    // ------------------------------------------------------------------

    /// @notice Headroom in assets: `cap - totalAssets()` when the cap is
    ///         set, `type(uint256).max` when unbounded, 0 at/over the cap.
    function _capacityLeft() private view returns (uint256) {
        uint256 cap = _totalAssetCap;
        if (cap == 0) {
            return type(uint256).max;
        }
        uint256 current = totalAssets();
        return current >= cap ? 0 : cap - current;
    }

    /// @dev Cap-aware headroom in asset units: deposit reverts with
    ///      `ERC4626ExceededMaxDeposit` beyond this (OZ core check).
    function maxDeposit(address) public view override returns (uint256) {
        return _capacityLeft();
    }

    /// @dev Cap-aware headroom in shares: the largest share amount whose
    ///      `previewMint` cost stays within the asset headroom. OZ's mint
    ///      prices via `previewMint` (Ceil) after the check, and
    ///      `convertToAssets(convertToShares(H, Floor), Ceil) <= H` for
    ///      integer H, so enforcing here cannot overshoot the cap. An
    ///      explicit unbounded cap (0) keeps the base default:
    ///      type(uint256).max.
    function maxMint(address) public view override returns (uint256) {
        uint256 cap = _totalAssetCap;
        if (cap == 0) {
            return type(uint256).max;
        }
        return _convertToShares(_capacityLeft(), Math.Rounding.Floor);
    }

    /// @dev Withdrawals are unbounded by the cap and by the deposits pause.
    function maxWithdraw(address owner) public view override returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    /// @dev Withdrawals are unbounded by the cap and by the deposits pause.
    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    /// @dev Deposit/mint entry gate added on top of the base flow: the
    ///      deposits pause and a cap re-check against the post-credit state
    ///      (assets are pulled inside super._deposit BEFORE the share mint,
    ///      so {totalAssets()} at hook start already includes the incoming
    ///      deposit). Defense in depth only: the OZ core flow already
    ///      rejects amounts beyond the max* views.
    ///
    ///      Reentrancy note: `nonReentrant` is deliberately NOT added here —
    ///      super._deposit ({AscendVault}._deposit) carries the guard in the
    ///      same call chain, and stacking it would double-lock and revert
    ///      every deposit. The hook itself performs no external call, so
    ///      there is no pre-lock reentrancy window.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        if (_depositsPaused) {
            revert DepositsPaused();
        }
        uint256 cap = _totalAssetCap;
        if (cap != 0 && totalAssets() > cap) {
            revert VaultCapacityExceeded(totalAssets(), cap);
        }
        super._deposit(caller, receiver, assets, shares);
    }

    // ------------------------------------------------------------------
    // Owner controls
    // ------------------------------------------------------------------

    /// @notice Set the maximum total assets the vault may manage. Zero =
    ///         unbounded. Forward-looking: rejected below current totals
    ///         rather than bricking deposits forever.
    /// @param newCap New cap (0 = unbounded; also explicit at-cap freeze
    ///        when equal to current totals — deposits block, exits stay open).
    function setTotalAssetCap(uint256 newCap) external onlyOwner {
        if (newCap != 0 && newCap < totalAssets()) {
            revert CapBelowTotalAssets(newCap, totalAssets());
        }
        uint256 oldCap = _totalAssetCap;
        _totalAssetCap = newCap;
        emit VaultCapUpdated(oldCap, newCap);
    }

    /// @notice Pause or unpause deposit/mint. Withdrawals, redeems, and
    ///         {investIdle} are never gated by this pause.
    /// @param paused True to block deposits and mints.
    function setDepositsPaused(bool paused) external onlyOwner {
        _depositsPaused = paused;
        emit DepositsPausedUpdated(paused);
    }

    // ------------------------------------------------------------------
    // Emergency exit (loss-aware)
    // ------------------------------------------------------------------

    /// @notice Emergency exit for a strategy that still answers but cannot
    ///         satisfy the strict {exitStrategy} settlement (insolvency,
    ///         partial payoff): request the full ledgered amount, accept
    ///         whatever actually returns as the real balance delta, clear
    ///         the ledger to that settled reality, and emit the realized
    ///         loss. The binding is kept with a zero ledger, so the owner
    ///         can immediately rebind or clear via {setStrategy}.
    /// @dev Push-model measurement (IStrategy.divest pushes to the vault):
    ///      `settled = idleAfter - idleBefore`. Over-return floors the
    ///      ledger decrement at zero (extra becomes idle balance, as in
    ///      {_withdraw}). SHORTFALL DOES NOT REVERT: that is the point —
    ///      the shortfall IS the realized loss.
    function emergencyExitStrategy() external onlyOwner nonReentrant {
        IStrategy strategy = IStrategy(this.strategy());
        if (strategy == IStrategy(address(0))) {
            revert NoStrategySet();
        }
        uint256 invested = this.strategyInvested();
        if (invested == 0) {
            revert NothingInvested();
        }

        IERC20 token = IERC20(asset());
        uint256 idleBefore = token.balanceOf(address(this));

        strategy.divest(invested);

        uint256 settled = token.balanceOf(address(this)) - idleBefore;

        // Same floor-decrement invariant as the base {_withdraw} path.
        _settleStrategyLedger(settled);

        emit StrategyForfeited(address(strategy), settled, invested >= settled ? invested - settled : 0);
    }

    /// @notice Relinquish a strategy that cannot return anything at all
    ///         ({divest} reverts): zero the ledger as a full loss admission
    ///         and free rebinding. No strategy call is made and no recovery
    ///         is faked — {totalAssets()} drops by the full ledgered amount,
    ///         exactly like an explicit loss event should. If the strategy
    ///         later repays assets anyway, they arrive as idle balance
    ///         (donation accounting) and lift the share price legitimately.
    function abandonStrategy() external onlyOwner nonReentrant {
        IStrategy strategy = IStrategy(this.strategy());
        if (strategy == IStrategy(address(0))) {
            revert NoStrategySet();
        }
        uint256 invested = this.strategyInvested();
        if (invested == 0) {
            revert NothingInvested();
        }

        _writeOffStrategyLedger();

        emit StrategyForfeited(address(strategy), 0, invested);
    }
}
