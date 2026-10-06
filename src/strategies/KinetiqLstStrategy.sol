// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IHypeStrategy} from "../interfaces/IHypeStrategy.sol";
import {IStakingManager, IStakingAccountant, IKHYPE} from "../interfaces/IKinetiqStaking.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title KinetiqLstStrategy
/// @notice Native-HYPE (ERC-7535) strategy adapter for Kinetiq's kHYPE liquid
///         staking protocol, prepared for a future Elysium deployment. It is
///         deliberately UNREGISTERED and INACTIVE in the strategy/vault
///         registries until an official Kinetiq deployment exists on chain
///         99801: kHYPE, the StakingManager and the StakingAccountant have NO
///         published Elysium addresses (Kinetiq's docs list mainnet
///         deployments only), so every protocol dependency is a deploy-time
///         constructor parameter — none is hardcoded, and no fake Elysium
///         deployment is asserted anywhere in this codebase.
///
///         Architecture:
///          * {invest} — vault-only, native pull (`msg.value == assets`
///            exactly), forwards the HYPE to the StakingManager via
///            {IStakingManager.stake} and verifies the kHYPE actually minted
///            against the StakingAccountant's official conversion quote
///            (minimum-output protection).
///          * {divest} — vault-only, settles the vault's request
///            SYNCHRONOUSLY: serves from idle HYPE first, then redeems only
///            the needed kHYPE via {IStakingManager.instantUnstake} (the
///            slippage-protected redemption path, `minHYPEOut` set to the
///            exact shortfall) and pushes exactly `assets` back to the vault
///            through its gated `receive()`.
///          * {divestAll} — vault-only full/emergency exit: instant-unstakes
///            the ENTIRE kHYPE position and pushes the whole native balance
///            back. All-or-nothing: if the protocol cannot fulfill, the call
///            reverts and the position stays intact in kHYPE (still officially
///            valued, recoverable when liquidity returns — never stranded
///            into a loss).
///          * {totalAssets} — idle HYPE plus kHYPE valued through the
///            StakingAccountant ({IStakingAccountant.kHYPEToHYPE}). No
///            fabricated APY anywhere: value moves ONLY when the official
///            conversion rate moves.
///          * {harvest}/{report} — flat no-ops ({Reported}(0)). The official
///            interface exposes NO realized-yield claim operation: kHYPE
///            yield accrues implicitly via the accountant exchange rate and
///            is realized only on redemption, so there is nothing to harvest
///            and nothing honest to report until then. Vault share pricing
///            never consults this contract's views anyway (vault-side ledger).
///
///         Protocol-behavior assumptions (from the OFFICIAL simplified
///         interfaces in {IKinetiqStaking}, and their limits):
///          * `stake()` is assumed to mint kHYPE to the caller at the
///            accountant's rate. The interface documents no stake fee; if a
///            real deployment charges one beyond {maxSlippageBps}, invest
///            fails closed (reverts) rather than accepting a worse rate.
///          * `instantUnstake` is assumed to burn the caller's kHYPE and pay
///            `(conversion − unstake fee)` HYPE to the caller within the same
///            call, honoring `minHYPEOut` (per its doc: "withdraw HYPE
///            immediately from buffer", slippage-protected). The strategy's
///            `receive()` is opened for the whole duration of the unstake
///            call and accepts a payout from ANY address during that window,
///            so it stays correct whether the protocol pays directly from the
///            StakingManager or through the documented `instantUnstakePool()`.
///          * The exact fee mechanics are NOT pinned by the simplified
///            interface (the `InstantUnstakeExecuted` event carries both a
///            `kHYPEFee` amount and a `feeRateBps`; the docs say "flat fee").
///            The adapter therefore treats the protocol's reported
///            `unstakeFeeRate()` plus {maxSlippageBps} as a bounded headroom
///            when sizing the kHYPE input, and enforces the output on both
///            sides (`minHYPEOut` and a local settlement check). Any fee
///            model beyond that headroom reverts the whole operation — fail
///            closed, nothing mis-settles.
///
///         Known limitations (documented, NOT worked around):
///          * Kinetiq's standard withdrawal path is an ASYNC queue
///            (`queueWithdrawal` + `confirmWithdrawal` after a delay). The
///            AscendVaultHype settlement model is SYNCHRONOUS — `divest` must
///            push the exact requested HYPE within the call — so an async
///            queue cannot satisfy the bound vault's divest contract and this
///            adapter does not use it. Divestments (including {divestAll})
///            therefore depend on instant-unstake buffer liquidity; when the
///            buffer is short, calls revert (fail closed) and the kHYPE
///            position remains intact. The published simplified interfaces
///            also do not pin the queued-withdrawal custody semantics (the
///            `WithdrawalRequest` fields say the kHYPE is "to burn" without
///            fixing WHEN), so accounting for pending claims would mean
///            inventing a valuation — no queue surface is exposed. A future
///            async-aware vault iteration can add it.
///          * With a nonzero unstake fee, divesting the ENTIRE kHYPE position
///            for its full face amount cannot settle exactly (the fee is a
///            protocol cost); such requests revert fail-closed. Partial
///            divests absorb the fee from the grossed-up input, and idle
///            surplus accumulates toward exact settlement.
///
///         Security model:
///          * All protocol dependencies are `immutable` and zero-address
///            validated at construction — no admin path can ever redirect
///            calls to an arbitrary external contract; the external-call
///            surface is fixed at deploy time.
///          * Only the bound vault can move value ({onlyVault}); the vault
///            enforces {cap} itself (same division of labor as
///            {HypeIdleStrategy}).
///          * {ReentrancyGuard} on every value-moving entry point. The
///            strategy holds NO accounting state that reentrancy could
///            corrupt (no ledger, no shares) — the vault's ledger is the
///            source of truth and is updated effects-first inside the vault's
///            own nonReentrant frame.
///          * NO approvals, ever: `stake` receives native value directly and
///            `instantUnstake` burns kHYPE from the holder via the protocol's
///            burner authority — the strategy never grants an allowance, so
///            there is no standing approval to exploit.
///          * `receive()` is GATED: native value is accepted only while an
///            unstake settlement is in flight. Plain HYPE transfers revert
///            (untracked value cannot enter), the same posture as the vault's
///            gated `receive()`. Forced sends (selfdestruct) are donation
///            accounting, counted by {totalAssets}.
///          * Value leaves ONLY to the bound vault (limited-stipend `call`,
///            revert on failure). Failed settlement reverts atomically on
///            both sides — no partial state anywhere.
///          * Every protocol response is verified against an official
///            on-chain quote before it is accepted: short-minted stakes and
///            short-paid unstakes revert instead of being absorbed.
contract KinetiqLstStrategy is IHypeStrategy, ReentrancyGuard {
    using Math for uint256;

    // ---------------------------------------------------------------------
    // Immutable bindings / configuration
    // ---------------------------------------------------------------------

    /// @inheritdoc IStrategy
    address public immutable override vault;

    /// @inheritdoc IStrategy
    uint256 public immutable override cap;

    /// @notice Kinetiq StakingManager this strategy stakes through and
    ///         instant-unstakes against.
    IStakingManager public immutable stakingManager;

    /// @notice kHYPE token (the protocol's liquid-staking receipt).
    IKHYPE public immutable khype;

    /// @notice Official kHYPE↔HYPE exchange-rate oracle. All valuation and
    ///         all minimum-output checks derive from it — never from a
    ///         hardcoded or fabricated rate.
    IStakingAccountant public immutable stakingAccountant;

    /// @notice Slippage tolerance (bps) for the difference between the
    ///         accountant's on-chain quote and the protocol's actual
    ///         conversion (fee-model drift, rounding, buffer fee changes):
    ///          * invest: kHYPE minted must be ≥ quote × (1 − tolerance);
    ///          * divest: the kHYPE input is grossed up for the reported
    ///            unstake fee PLUS this tolerance, and the HYPE output must
    ///            still cover the exact shortfall (protocol `minHYPEOut` and
    ///            a local settlement check both enforce it).
    ///         Failures beyond the tolerance revert (fail closed) rather
    ///         than under-settle. Atomic execution means the quote and the
    ///         protocol call settle in one transaction — the tolerance exists
    ///         for fee-model uncertainty, not for inter-block rate moves.
    uint256 public immutable maxSlippageBps;

    /// @notice Hard upper bound for {maxSlippageBps}: 10.00%.
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    /// @notice Basis-point denominator. Kinetiq's protocol exposes the same
    ///         denominator via {IStakingManager.BASIS_POINTS} (10000 = 100%);
    ///         it is kept as a local constant to avoid an external call in
    ///         every conversion.
    uint256 private constant _BPS = 10_000;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Zero address passed where a real address is required.
    error KinetiqStrategyZeroAddress();

    /// @notice Caller is not the vault this strategy is bound to.
    error NotVault(address caller);

    /// @notice `invest` was called with a value different from `assets`.
    ///         The exact-match check is what makes vault-side settlement
    ///         verification meaningful.
    error KinetiqStrategyValueMismatch(uint256 expected, uint256 attached);

    /// @notice Asked to divest more value than the strategy holds across
    ///         idle HYPE and its kHYPE position (at the official rate).
    error DivestShortfall(uint256 requested, uint256 held);

    /// @notice The native payout to the vault failed. Reverting leaves both
    ///         sides unchanged.
    error KinetiqTransferFailed(uint256 amount);

    /// @notice The StakingManager minted less kHYPE than the official quote
    ///         allows. The whole invest reverts — value is never accepted at
    ///         a worse-than-quoted rate.
    error StakeSlippageExceeded(uint256 minKHYPEOut, uint256 received);

    /// @notice An instant unstake settled less HYPE than required (defense
    ///         in depth behind the protocol's own `minHYPEOut`). The whole
    ///         operation reverts.
    error UnstakeShortfall(uint256 required, uint256 received);

    /// @notice A slippage tolerance above the hard cap was configured.
    error InvalidSlippageBps(uint256 provided, uint256 maxAllowed);

    /// @notice The protocol's unstake fee rate is unusable: the fee plus the
    ///         configured tolerance would consume the whole conversion (or
    ///         the rate itself exceeds 100%).
    error InvalidFeeRate(uint256 feeRateBps);

    /// @notice The accountant returned a zero valuation for a nonzero
    ///         amount — fail closed rather than accept free value.
    error InvalidValuation();

    /// @notice Native HYPE arrived while no unstake settlement was in flight.
    ///         Untracked value is rejected (plain transfers revert); forced
    ///         sends (selfdestruct) are donation accounting.
    error KinetiqReceiveUnauthorized(address sender);

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when the strategy stakes HYPE and receives kHYPE.
    /// @param hypeAmount Native HYPE sent to the StakingManager.
    /// @param khypeReceived kHYPE actually minted to this strategy.
    event Staked(uint256 indexed hypeAmount, uint256 khypeReceived);

    /// @notice Emitted when the strategy instant-unstakes kHYPE for HYPE.
    /// @param khypeAmount kHYPE burned.
    /// @param hypeReceived Native HYPE actually received.
    event Unstaked(uint256 indexed khypeAmount, uint256 hypeReceived);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @notice Deploy the Kinetiq kHYPE strategy adapter.
    /// @dev All protocol dependencies are immutable: there is no setter that
    ///      could ever redirect protocol calls. Addresses MUST be the
    ///      official Elysium Kinetiq deployments once they exist — none are
    ///      hardcoded here because none have been published for chain 99801.
    ///      Before production use, verify against the real deployment: the
    ///      actual fee model, the `instantUnstake` payout path (direct push
    ///      vs `instantUnstakePool()`), and every event signature.
    /// @param vault_ Vault allowed to invest/divest (cannot be zero).
    /// @param cap_ Upper bound on wei of HYPE the strategy manages. The
    ///        vault enforces it; `type(uint256).max` means unbounded.
    /// @param stakingManager_ Official Kinetiq StakingManager (cannot be
    ///        zero).
    /// @param khype_ Official kHYPE token (cannot be zero).
    /// @param stakingAccountant_ Official Kinetiq StakingAccountant, the
    ///        canonical kHYPE↔HYPE conversion oracle (cannot be zero).
    /// @param maxSlippageBps_ Slippage tolerance in bps (≤ {MAX_SLIPPAGE_BPS};
    ///        0 means exact-quote checks with no tolerance).
    constructor(
        address vault_,
        uint256 cap_,
        address stakingManager_,
        address khype_,
        address stakingAccountant_,
        uint256 maxSlippageBps_
    ) {
        if (
            vault_ == address(0) || stakingManager_ == address(0) || khype_ == address(0)
                || stakingAccountant_ == address(0)
        ) {
            revert KinetiqStrategyZeroAddress();
        }
        if (maxSlippageBps_ > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippageBps(maxSlippageBps_, MAX_SLIPPAGE_BPS);
        }
        vault = vault_;
        cap = cap_;
        stakingManager = IStakingManager(stakingManager_);
        khype = IKHYPE(khype_);
        stakingAccountant = IStakingAccountant(stakingAccountant_);
        maxSlippageBps = maxSlippageBps_;
    }

    // ---------------------------------------------------------------------
    // Native settlement gate
    // ---------------------------------------------------------------------

    /// @notice True only while an instant-unstake settlement is in flight —
    ///         the window during which the protocol's HYPE payout may arrive.
    /// @dev Opened immediately before {IStakingManager.instantUnstake} and
    ///      closed right after it returns. The payout is accepted from ANY
    ///      address during that window, so the adapter stays correct whether
    ///      the real protocol pays directly from the StakingManager or
    ///      through the documented `instantUnstakePool()`. Outside the
    ///      window, plain transfers revert (untracked value cannot enter).
    bool private _receivingUnstake;

    /// @notice Accepts the protocol's instant-unstake HYPE payout (and
    ///         nothing else — see {_receivingUnstake}).
    receive() external payable {
        if (!_receivingUnstake) {
            revert KinetiqReceiveUnauthorized(msg.sender);
        }
    }

    // ---------------------------------------------------------------------
    // IStrategy views
    // ---------------------------------------------------------------------

    /// @inheritdoc IHypeStrategy
    /// @dev Always the ERC-7528 native-asset sentinel: this strategy operates
    ///      on native HYPE and holds its yield position in kHYPE.
    function asset() external pure returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    /// @inheritdoc IStrategy
    /// @dev Idle native balance plus kHYPE valued through the OFFICIAL
    ///      conversion ({IStakingAccountant.kHYPEToHYPE}). The vault never
    ///      consults this for share pricing (it counts its own ledger), so
    ///      the informational value tracks the protocol's real exchange rate
    ///      — including its fee and liquidity state — and nothing else.
    function totalAssets() external view returns (uint256) {
        return address(this).balance + stakingAccountant.kHYPEToHYPE(khype.balanceOf(address(this)));
    }

    // ---------------------------------------------------------------------
    // State-changing functions (vault-only)
    // ---------------------------------------------------------------------

    /// @inheritdoc IHypeStrategy
    /// @dev Native pull model: the value arrives WITH this call and MUST
    ///      equal `assets` exactly. The minted kHYPE is verified against the
    ///      accountant's official conversion (relaxed by {maxSlippageBps}): a
    ///      StakingManager that mints less than quoted reverts the whole
    ///      invest, rolling back every state change atomically.
    function invest(uint256 assets) external payable override onlyVault nonReentrant {
        if (msg.value != assets) {
            revert KinetiqStrategyValueMismatch(assets, msg.value);
        }
        if (assets == 0) {
            emit Invested(0);
            return;
        }

        uint256 minKHYPEOut = _minKHYPEOut(assets);
        uint256 khypeBefore = khype.balanceOf(address(this));

        stakingManager.stake{value: assets}();

        uint256 received = khype.balanceOf(address(this)) - khypeBefore;
        if (received < minKHYPEOut) {
            revert StakeSlippageExceeded(minKHYPEOut, received);
        }

        emit Staked(assets, received);
        emit Invested(assets);
    }

    /// @inheritdoc IHypeStrategy
    /// @dev Synchronous settlement (the vault verifies its own balance after
    ///      this call returns): idle HYPE is used first; only the shortfall
    ///      is redeemed via {IStakingManager.instantUnstake} with
    ///      `minHYPEOut == shortfall` (exact — the protocol reverts rather
    ///      than paying less) and the kHYPE input grossed up for the
    ///      protocol's unstake fee plus {maxSlippageBps}, capped at the held
    ///      position. The settled amount is verified locally (defense in
    ///      depth) before exactly `assets` is pushed to the vault; any
    ///      over-received surplus stays as idle HYPE, still counted by
    ///      {totalAssets} and available to serve later divests exactly.
    function divest(uint256 assets) external override onlyVault nonReentrant {
        if (assets == 0) {
            emit Divested(0);
            return;
        }

        uint256 idle = address(this).balance;
        if (idle >= assets) {
            _pushToVault(assets);
            emit Divested(assets);
            return;
        }

        uint256 shortfall = assets - idle;
        uint256 khypeHeld = khype.balanceOf(address(this));
        uint256 kHypeValue = stakingAccountant.kHYPEToHYPE(khypeHeld);
        if (shortfall > kHypeValue) {
            revert DivestShortfall(assets, idle + kHypeValue);
        }

        uint256 khypeIn = _kHYPEInForHYPE(shortfall);
        if (khypeIn > khypeHeld) {
            // The gross-up headroom exceeds the position: burning the ENTIRE
            // position is the best possible attempt. If that still cannot
            // net the shortfall (fee > 0 or rate below the tolerance), the
            // protocol's own `minHYPEOut` check reverts — fail closed.
            khypeIn = khypeHeld;
        }

        // Effects before interactions: no strategy-side ledger exists; the
        // balances below are measured after the interaction and verified
        // before the payout to the vault.
        _receivingUnstake = true;
        stakingManager.instantUnstake(khypeIn, shortfall);
        _receivingUnstake = false;

        uint256 received = address(this).balance - idle;
        if (received < shortfall) {
            revert UnstakeShortfall(shortfall, received);
        }
        emit Unstaked(khypeIn, received);

        _pushToVault(assets);
        emit Divested(assets);
    }

    /// @inheritdoc IStrategy
    /// @dev Full/emergency exit, all-or-nothing: instant-unstakes the ENTIRE
    ///      kHYPE position with `minHYPEOut` set to its official valuation
    ///      minus the protocol fee minus {maxSlippageBps} (slippage
    ///      protection), then pushes the whole native balance to the vault.
    ///      If the protocol cannot fulfill (e.g. `hypeBuffer` liquidity), the
    ///      whole call reverts and the position stays intact in kHYPE —
    ///      valued, recoverable, never stranded into a loss. Idempotent at
    ///      zero (emits `Divested(0)`).
    ///      Note: the deployed vault's `receive()` is gated, so payouts are
    ///      accepted only while the vault itself is pulling (its `divest`
    ///      frames) — a direct `divestAll` against the deployed vault reverts
    ///      at the push, atomically. A future vault iteration that opens the
    ///      gate for {divestAll} can consume it as-is.
    function divestAll() external override onlyVault nonReentrant {
        uint256 hypeHeld = address(this).balance;
        uint256 khypeHeld = khype.balanceOf(address(this));
        if (hypeHeld == 0 && khypeHeld == 0) {
            emit Divested(0);
            return;
        }

        if (khypeHeld != 0) {
            uint256 minHYPEOut = _minHYPEOut(khypeHeld);

            _receivingUnstake = true;
            stakingManager.instantUnstake(khypeHeld, minHYPEOut);
            _receivingUnstake = false;

            uint256 received = address(this).balance - hypeHeld;
            if (received < minHYPEOut) {
                revert UnstakeShortfall(minHYPEOut, received);
            }
            emit Unstaked(khypeHeld, received);
        }

        uint256 total = address(this).balance;
        _pushToVault(total);
        emit Divested(total);
    }

    /// @notice No-op claim: the official Kinetiq interface exposes no
    ///         realized-yield operation (yield accrues via the accountant
    ///         exchange rate and is realized only on redemption), so this
    ///         always emits a flat {Reported}(0). It never simulates,
    ///         fabricates, or pre-realizes yield.
    /// @dev Restricted to the bound vault like every other state-changing
    ///      entry point. Vaults MUST NOT change share pricing off this event.
    function harvest() external override onlyVault {
        emit Reported(0);
    }

    /// @inheritdoc IStrategy
    /// @dev Always flat: no realized-yield event exists in the official
    ///      protocol interface, and unrealized exchange-rate appreciation is
    ///      not a realized profit. Revaluation is observable through
    ///      {totalAssets} (official conversion) and, if ever consumed, a
    ///      future reviewed profit-realization design.
    function report() external override returns (int256 profit) {
        profit = 0;
        emit Reported(profit);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Minimum acceptable kHYPE out for staking `hypeAmount`: the
    ///      accountant's official conversion relaxed by {maxSlippageBps}.
    ///      Zero quotes (a broken accountant) revert fail-closed.
    function _minKHYPEOut(uint256 hypeAmount) internal view returns (uint256) {
        uint256 quote = stakingAccountant.HYPEToKHYPE(hypeAmount);
        if (quote == 0) {
            revert InvalidValuation();
        }
        return quote.mulDiv(_BPS - maxSlippageBps, _BPS, Math.Rounding.Floor);
    }

    /// @dev kHYPE to burn so the post-fee HYPE received covers `hypeAmount`:
    ///      the accountant's official conversion grossed up (ceiling) for the
    ///      protocol's reported unstake fee PLUS {maxSlippageBps}. The
    ///      proportional gross-up is an upper bound for fee-model drift
    ///      within the configured tolerance; anything beyond it is caught by
    ///      the protocol's `minHYPEOut` check and the post-interaction
    ///      settlement check, both of which revert (fail closed). The result
    ///      is capped at the held position by the caller.
    function _kHYPEInForHYPE(uint256 hypeAmount) internal view returns (uint256) {
        uint256 feeRateBps = stakingManager.unstakeFeeRate();
        if (feeRateBps + maxSlippageBps >= _BPS) {
            revert InvalidFeeRate(feeRateBps);
        }
        uint256 quote = stakingAccountant.HYPEToKHYPE(hypeAmount);
        if (quote == 0) {
            revert InvalidValuation();
        }
        return quote.mulDiv(_BPS, _BPS - feeRateBps - maxSlippageBps, Math.Rounding.Ceil);
    }

    /// @dev Minimum acceptable HYPE out for burning the ENTIRE `khypeAmount`
    ///      position: its official valuation minus the protocol fee minus
    ///      {maxSlippageBps} (floored). Guarded against fee configurations
    ///      that would consume the whole conversion.
    function _minHYPEOut(uint256 khypeAmount) internal view returns (uint256) {
        uint256 feeRateBps = stakingManager.unstakeFeeRate();
        if (feeRateBps + maxSlippageBps >= _BPS) {
            revert InvalidFeeRate(feeRateBps);
        }
        uint256 grossValue = stakingAccountant.kHYPEToHYPE(khypeAmount);
        if (grossValue == 0) {
            revert InvalidValuation();
        }
        return grossValue.mulDiv(_BPS - feeRateBps - maxSlippageBps, _BPS, Math.Rounding.Floor);
    }

    /// @dev Limited-stipend native push to the vault (the ERC-7535 pattern
    ///      used across the native track — never `transfer`/`send`, whose
    ///      2300-gas stipend cannot run vault logic). Reverts on failure so
    ///      neither side's state changes.
    function _pushToVault(uint256 assets) internal {
        (bool ok,) = msg.sender.call{value: assets}(new bytes(0));
        if (!ok) {
            revert KinetiqTransferFailed(assets);
        }
    }
}
