// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHypeStrategy} from "./interfaces/IHypeStrategy.sol";
import {AscendVaultHype} from "./AscendVaultHype.sol";

/// @title AscendVaultHypeGuarded
/// @notice Guarded extension of {AscendVaultHype} (native-HYPE / ERC-7535
///         track): the exact capital-control and emergency-exit surface of
///         {AscendVaultGuarded}, ported to native value with no behavior
///         change to the base source or to the live deployed base vault
///         (independent deployment).
///
///         Owner-controlled surfaces:
///          * {totalAssetCap}: hard ceiling on {totalAssets()} (idle native
///            balance + invested ledger), enforced on payable deposit/mint
///            via the ERC-7535 max* views plus a defense-in-depth gate in
///            {_deposit}. Zero = unbounded.
///          * {setDepositsPaused}: blocks deposit/mint only. Withdrawals,
///            redeems, and {investIdle} stay open — a deposit freeze must
///            never trap user capital.
///          * {emergencyExitStrategy}: when the bound strategy cannot
///            satisfy the strict {exitStrategy} settlement, accept whatever
///            it actually pushes back (real balance delta, received through
///            the vault's gated `receive()` which this contract opens for
///            the payout), clear the ledger to that settled reality, and
///            emit the realized loss.
///          * {abandonStrategy}: when the strategy cannot return anything
///            at all (reverting divest), relinquish it: zero the ledger as
///            a full loss admission and free rebinding. NOTE the native
///            nuance: the base vault's gated `receive()` rejects unsolicited
///            strategy pushes, so a stuck strategy that "repays later"
///            cannot voluntarily donate after abandonment — only a forced
///            send (e.g. selfdestruct) would land as donation accounting.
///            This is honest loss recognition, not a recovery path.
///
///         Deliberately NOT implemented: a blanket pause or a withdrawal
///         freeze. Users stay able to withdraw/redeem at all times; the base
///         contract's strict settlement checks refuse to mis-account trapped
///         capital (whole operation reverts) rather than pausing redemptions
///         or re-pricing shares over losses.
/// @dev The base contract's gated `receive()`, `_minting`/`_update` share
///      guards, reentrancy guards, and settlement verification are inherited
///      unchanged. `nonReentrant` is NOT re-specified on the {_deposit} hook
///      override: the guard lives on the base payable entry points in the
///      same call chain; the hook itself performs no external call.
contract AscendVaultHypeGuarded is AscendVaultHype {
    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice Maximum total assets (idle native HYPE + invested ledger).
    ///         Zero = unbounded.
    uint256 private _totalAssetCap;

    /// @notice True while deposit/mint are blocked by the owner.
    bool private _depositsPaused;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice Deposit/mint would push {totalAssets()} above the cap.
    error HypeVaultCapacityExceeded(uint256 projectedTotal, uint256 cap);

    /// @notice A forward-looking cap may not be set below the assets the
    ///         vault already manages.
    error HypeCapBelowTotalAssets(uint256 cap, uint256 totalAssets);

    /// @notice Deposits and mints are paused by the owner.
    error HypeDepositsPaused();

    /// @notice Emergency exit attempted while nothing is invested.
    error HypeNothingInvested();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice Emitted when the owner changes the total-asset cap.
    event HypeVaultCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the owner pauses or unpauses deposits.
    event HypeDepositsPausedUpdated(bool paused);

    /// @notice Emitted when the owner accepts a realized loss on the bound
    ///         native strategy: `settled` is the HYPE amount actually pushed
    ///         back by the strategy (0 for {abandonStrategy}); `loss` is the
    ///         part of the ledgered investment written off.
    event HypeStrategyForfeited(address indexed strategy, uint256 settled, uint256 loss);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @notice Deploys the guarded native vault, inheriting {AscendVaultHype}'s
    ///         dormant fee architecture, strategy-ledger accounting, and
    ///         settlement checks unchanged.
    /// @param name_ ERC20 name of the vault share token.
    /// @param symbol_ ERC20 symbol of the vault share token.
    /// @param initialOwner_ Account granted ownership of all admin controls.
    constructor(string memory name_, string memory symbol_, address initialOwner_)
        AscendVaultHype(name_, symbol_, initialOwner_)
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
    // ERC-7535 capacity enforcement
    // ------------------------------------------------------------------

    /// @notice Headroom in wei of HYPE: `cap - totalAssets()` when the cap
    ///         is set, `type(uint256).max` when unbounded, 0 at/over the cap.
    function _capacityLeft() private view returns (uint256) {
        uint256 cap = _totalAssetCap;
        if (cap == 0) {
            return type(uint256).max;
        }
        uint256 current = totalAssets();
        return current >= cap ? 0 : cap - current;
    }

    /// @dev Cap-aware headroom in wei: deposit reverts with
    ///      `ERC4626ExceededMaxDeposit` beyond this (base core check — the
    ///      base `deposit` consults `maxDeposit` before `_deposit`).
    function maxDeposit(address) public view override returns (uint256) {
        return _capacityLeft();
    }

    /// @dev Cap-aware headroom in shares: the largest share amount whose
    ///      `previewMint` cost stays within the asset headroom. The base
    ///      mint prices via `previewMint` (Ceil) after the check, and
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

    /// @dev Deposit/mint entry gate added on top of the base flow: the
    ///      deposits pause and a cap re-check against the post-credit state
    ///      (msg.value is credited before the base body runs, so
    ///      {totalAssets()} at hook start already includes the incoming
    ///      deposit). Defense in depth only: the base payable entries
    ///      already reject amounts beyond the max* views.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        if (_depositsPaused) {
            revert HypeDepositsPaused();
        }
        uint256 cap = _totalAssetCap;
        if (cap != 0 && totalAssets() > cap) {
            revert HypeVaultCapacityExceeded(totalAssets(), cap);
        }
        super._deposit(caller, receiver, assets, shares);
    }

    // ------------------------------------------------------------------
    // Owner controls
    // ------------------------------------------------------------------

    /// @notice Set the maximum total assets the vault may manage. Zero =
    ///         unbounded. Forward-looking: rejected below current totals
    ///         rather than bricking deposits forever.
    /// @param newCap New cap in wei of HYPE (0 = unbounded; also an explicit
    ///        at-cap freeze when equal to current totals).
    function setTotalAssetCap(uint256 newCap) external onlyOwner {
        if (newCap != 0 && newCap < totalAssets()) {
            revert HypeCapBelowTotalAssets(newCap, totalAssets());
        }
        uint256 oldCap = _totalAssetCap;
        _totalAssetCap = newCap;
        emit HypeVaultCapUpdated(oldCap, newCap);
    }

    /// @notice Pause or unpause deposit/mint. Withdrawals, redeems, and
    ///         {investIdle} are never gated by this pause.
    /// @param paused True to block deposits and mints.
    function setDepositsPaused(bool paused) external onlyOwner {
        _depositsPaused = paused;
        emit HypeDepositsPausedUpdated(paused);
    }

    // ------------------------------------------------------------------
    // Emergency exit (loss-aware)
    // ------------------------------------------------------------------

    /// @notice Emergency exit for a strategy that still answers but cannot
    ///         satisfy the strict {exitStrategy} settlement (insolvency,
    ///         partial payoff): request the full ledgered amount, open the
    ///         gated `receive()` for the strategy's push exactly like the
    ///         base flows do, accept whatever actually returns as the real
    ///         balance delta, clear the ledger to that settled reality, and
    ///         emit the realized loss. The binding is kept with a zero
    ///         ledger, so the owner can immediately rebind or clear via
    ///         {setStrategy}.
    /// @dev Push-model measurement: `settled = balanceAfter - balanceBefore`
    ///      while the receive gate is open. Over-return floors the ledger
    ///      decrement at zero (extra becomes idle balance, as in the base
    ///      {_withdraw}). SHORTFALL DOES NOT REVERT: the shortfall IS the
    ///      realized loss. If the strategy reverts instead of paying, the
    ///      whole call reverts (gate flag restored by rollback) and the
    ///      owner may fall back to {abandonStrategy}.
    function emergencyExitStrategy() external onlyOwner nonReentrant {
        IHypeStrategy strategy = IHypeStrategy(this.strategy());
        if (address(strategy) == address(0)) {
            revert HypeNoStrategySet();
        }
        uint256 invested = this.strategyInvested();
        if (invested == 0) {
            revert HypeNothingInvested();
        }

        uint256 idleBefore = address(this).balance;

        // Open the receive() gate for this strategy's native payout, exactly
        // as the base flows do around every divest.
        _setReceivingHYPE(true);
        strategy.divest(invested);
        _setReceivingHYPE(false);

        uint256 settled = address(this).balance - idleBefore;

        // Same floor-decrement invariant as the base {_withdraw} path.
        _settleStrategyLedger(settled);

        emit HypeStrategyForfeited(address(strategy), settled, invested >= settled ? invested - settled : 0);
    }

    /// @notice Relinquish a strategy that cannot return anything at all
    ///         ({divest} reverts): zero the ledger as a full loss admission
    ///         and free rebinding. No strategy call is made and no recovery
    ///         is faked — {totalAssets()} drops by the full ledgered amount,
    ///         exactly like an explicit loss event should.
    /// @dev Native nuance: the base vault's gated `receive()` rejects
    ///      unsolicited strategy pushes (`ReceivingUnauthorized`), so an
    ///      abandoned strategy cannot voluntarily repay later; only a forced
    ///      send (e.g. selfdestruct) would land as donation accounting.
    function abandonStrategy() external onlyOwner nonReentrant {
        IHypeStrategy strategy = IHypeStrategy(this.strategy());
        if (address(strategy) == address(0)) {
            revert HypeNoStrategySet();
        }
        uint256 invested = this.strategyInvested();
        if (invested == 0) {
            revert HypeNothingInvested();
        }

        _writeOffStrategyLedger();

        emit HypeStrategyForfeited(address(strategy), 0, invested);
    }
}
