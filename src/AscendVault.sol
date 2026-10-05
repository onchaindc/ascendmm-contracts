// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title AscendVault
/// @notice ERC-4626 vault foundation for the AscendMM market-making and
///         strategy-vault protocol on the Elysium ecosystem.
///
/// This contract is deliberately minimal and production-minded:
///  * Standard ERC-4626 deposit/mint/withdraw/redeem accounting inherited from
///    OpenZeppelin's audited implementation (virtual-share math mitigates the
///    classic inflation/donation attack).
///  * A dormant fee architecture: entry and exit fees default to 0 with no fee
///    recipient set, and can be enabled later by the owner without redeploying
///    or redesigning the vault.
///  * A strategy layer with vault-side accounting: the owner can bind an
///    `IStrategy`, explicitly invest idle assets into it (`investIdle`), and
///    pull them back (`exitStrategy`). Withdrawals automatically tap the
///    strategy when idle balance is insufficient. Share pricing counts a
///    vault-side investment ledger — never the strategy's self-reported
///    balance (see {totalAssets}).
///
/// @dev Status: FOUNDATION. Not audited. Intended for Elysium testnet first.
///      Fees and strategy accounting must be reviewed and finalized before any
///      production deployment.
contract AscendVault is ERC4626, Ownable, ReentrancyGuard {
    // ---------------------------------------------------------------------
    // Types / constants
    // ---------------------------------------------------------------------

    /// @notice Denominator for fee values expressed in basis points.
    /// @dev 10_000 == 100.00%.
    uint256 private constant _FEE_DIVISOR = 10_000;

    /// @notice Hard upper bound for the entry fee (10.00%).
    uint256 private constant _MAX_ENTRY_FEE_BPS = 1_000;

    /// @notice Hard upper bound for the exit fee (10.00%).
    uint256 private constant _MAX_EXIT_FEE_BPS = 1_000;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Entry fee in basis points charged on assets entering the vault.
    ///         0 until explicitly enabled by the owner.
    uint64 private _entryFeeBps;

    /// @notice Exit fee in basis points charged on assets leaving the vault.
    ///         0 until explicitly enabled by the owner.
    uint64 private _exitFeeBps;

    /// @notice Receiver of accrued fees. The zero address means fees are fully
    ///         disabled: while unset, any nonzero fee configuration is rejected
    ///         and fee calculations short-circuit to zero.
    address private _feeRecipient;

    /// @notice Currently bound strategy. The zero address means "no strategy".
    /// @dev Binding never moves funds by itself; the owner explicitly invests
    ///      idle assets via {investIdle}. The strategy is the only external
    ///      contract called on the asset path, and every transfer is
    ///      settlement-verified (see {investIdle} and {_withdraw}).
    IStrategy private _strategy;

    /// @notice Vault-side ledger of assets currently invested in the bound
    ///         strategy. This — not the strategy's self-reported
    ///         `totalAssets()` — is what share pricing counts, so a
    ///         compromised or buggy strategy cannot inflate the exchange
    ///         rate by lying about its holdings.
    uint256 private _strategyInvested;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice The candidate strategy reports a different vault binding.
    error StrategyVaultMismatch(address expected, address actual);

    /// @notice The candidate strategy reports a different underlying asset.
    error StrategyAssetMismatch(address expected, address actual);

    /// @notice Provided entry fee exceeds the protocol maximum.
    error EntryFeeTooHigh(uint64 feeBps, uint64 maxFeeBps);

    /// @notice Provided exit fee exceeds the protocol maximum.
    error ExitFeeTooHigh(uint64 feeBps, uint64 maxFeeBps);

    /// @notice Fees were enabled before a fee recipient was configured.
    error FeeRecipientNotSet();

    /// @notice Invalid fee recipient change (e.g. unsetting while fees active).
    error FeeRecipientInvalid();

    /// @notice A strategy action was attempted while no strategy is bound.
    error NoStrategySet();

    /// @notice The strategy binding cannot change while vault assets remain
    ///         invested in the current strategy. Exit first ({exitStrategy}).
    error StrategyStillInvested(address strategy, uint256 invested);

    /// @notice More idle assets were requested for investment than the vault
    ///         currently holds.
    error IdleBalanceTooLow(uint256 requested, uint256 idle);

    /// @notice Investing the requested amount would exceed the strategy cap.
    error StrategyCapacityExceeded(uint256 projected, uint256 cap);

    /// @notice The vault balance after `invest` differs from the expected
    ///         post-pull balance: the strategy did not settle exactly what it
    ///         was allowed to pull. The whole operation reverts.
    error InvestSettlementMismatch(uint256 expectedBalance, uint256 actualBalance);

    /// @notice A withdrawal from the strategy settled less than required. The
    ///         whole operation reverts, leaving accounting untouched.
    error DivestShortfall(uint256 required, uint256 settled);

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when the owner binds or clears the strategy.
    /// @param oldStrategy Previous strategy (zero address if none).
    /// @param newStrategy New strategy (zero address to clear).
    event StrategyUpdated(IStrategy indexed oldStrategy, IStrategy indexed newStrategy);

    /// @notice Emitted when the owner updates the fee recipient.
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when the owner updates fee configurations.
    event EntryFeeUpdated(uint64 oldFeeBps, uint64 newFeeBps);
    event ExitFeeUpdated(uint64 oldFeeBps, uint64 newFeeBps);

    /// @notice Emitted when the vault invests idle assets into the strategy.
    /// @param strategy Strategy that received the assets.
    /// @param assets Amount invested.
    event StrategyInvested(address indexed strategy, uint256 assets);

    /// @notice Emitted when the vault pulls assets back from the strategy.
    /// @param strategy Strategy the assets were pulled from.
    /// @param assets Amount divested (settled amount; may exceed the ledgered
    ///        amount if the strategy returned donated tokens as well).
    event StrategyDivested(address indexed strategy, uint256 assets);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @notice Deploys the vault.
    /// @param asset_ Underlying ERC20 asset accepted by the vault.
    /// @param name_ ERC20 name of the vault share token.
    /// @param symbol_ ERC20 symbol of the vault share token.
    /// @param initialOwner_ Account granted ownership (admin of fees and
    ///        strategy binding). Cannot be the zero address (enforced by
    ///        OpenZeppelin `Ownable`).
    constructor(IERC20 asset_, string memory name_, string memory symbol_, address initialOwner_)
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(initialOwner_)
    {}

    // ---------------------------------------------------------------------
    // Admin: strategy binding
    // ---------------------------------------------------------------------

    /// @notice Bind or clear the vault's strategy.
    /// @dev Validates the candidate's self-reported bindings (`vault()` /
    ///      `asset()`) against this vault. Binding never moves funds; assets
    ///      reach the strategy only via {investIdle}. Switching or clearing is
    ///      blocked while assets remain invested — exit first via
    ///      {exitStrategy} so migration cannot strand or lose assets.
    ///      Re-binding the SAME strategy is always allowed (no-op).
    ///      `setStrategy(IStrategy(address(0)))` clears the binding.
    /// @param newStrategy Candidate strategy (zero address clears).
    function setStrategy(IStrategy newStrategy) external onlyOwner {
        _validateStrategyBinding(newStrategy);

        IStrategy oldStrategy = _strategy;
        if (oldStrategy != newStrategy && _strategyInvested != 0) {
            revert StrategyStillInvested(address(oldStrategy), _strategyInvested);
        }

        _strategy = newStrategy;

        emit StrategyUpdated(oldStrategy, newStrategy);
    }

    /// @notice Currently bound strategy (zero address if none).
    function strategy() external view returns (address) {
        return address(_strategy);
    }

    /// @notice Assets the vault has currently invested in the bound strategy
    ///         (vault-side ledger; see {totalAssets}).
    function strategyInvested() external view returns (uint256) {
        return _strategyInvested;
    }

    /// @notice Total assets managed by the vault: idle balance plus the
    ///         vault-side strategy ledger.
    /// @dev Deliberately does NOT consult the strategy's self-reported
    ///      `totalAssets()` (see {IStrategy-totalAssets}): a compromised
    ///      strategy could inflate it to manipulate the share price. Assets
    ///      are counted only after the vault verifiably moved them into the
    ///      strategy ({investIdle}) and stop being counted only after they
    ///      verifiably return ({exitStrategy} / {_withdraw}). All ERC-4626
    ///      conversions (previews, convert*, max*) build on this, so pricing
    ///      stays exact for idle-style strategies.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _strategyInvested;
    }

    // ---------------------------------------------------------------------
    // Admin: strategy funding / exit
    // ---------------------------------------------------------------------

    /// @notice Invest idle vault assets into the bound strategy (owner-only).
    /// @dev Deposits stay idle; binding a strategy never moves funds. The
    ///      pull is allowance-scoped: the vault approves exactly `assets`,
    ///      verifies that it lost exactly `assets`, then clears the approval
    ///      — the strategy never holds a standing allowance over vault funds.
    /// @param assets Amount of the underlying asset to invest (0 = no-op).
    function investIdle(uint256 assets) external onlyOwner nonReentrant {
        IStrategy strategy = _strategy;
        if (strategy == IStrategy(address(0))) {
            revert NoStrategySet();
        }
        if (assets == 0) {
            return;
        }

        IERC20 token = IERC20(asset());
        uint256 idle = token.balanceOf(address(this));
        if (assets > idle) {
            revert IdleBalanceTooLow(assets, idle);
        }
        uint256 projected = _strategyInvested + assets;
        if (projected > strategy.cap()) {
            revert StrategyCapacityExceeded(projected, strategy.cap());
        }

        // Effect before interaction: the ledger moves first; the settlement
        // check below reverts (rolling everything back) unless the strategy
        // pulled exactly what it was approved for.
        _strategyInvested = projected;
        SafeERC20.forceApprove(token, address(strategy), assets);
        strategy.invest(assets);
        uint256 settledBalance = token.balanceOf(address(this));
        if (settledBalance != idle - assets) {
            revert InvestSettlementMismatch(idle - assets, settledBalance);
        }
        SafeERC20.forceApprove(token, address(strategy), 0);

        emit StrategyInvested(address(strategy), assets);
    }

    /// @notice Pull all vault-owned assets back from the bound strategy into
    ///         vault idle balance (owner-only).
    /// @dev Required before replacing or clearing a strategy that still holds
    ///      invested assets. Requests exactly the ledgered amount and requires
    ///      full settlement: a strategy that cannot repay makes the whole
    ///      call revert, leaving the binding and accounting untouched. No-op
    ///      when nothing is invested.
    function exitStrategy() external onlyOwner nonReentrant {
        IStrategy strategy = _strategy;
        if (strategy == IStrategy(address(0))) {
            revert NoStrategySet();
        }

        uint256 invested = _strategyInvested;
        if (invested == 0) {
            return;
        }

        IERC20 token = IERC20(asset());
        uint256 idleBefore = token.balanceOf(address(this));

        strategy.divest(invested);

        uint256 settled = token.balanceOf(address(this)) - idleBefore;
        if (settled < invested) {
            revert DivestShortfall(invested, settled);
        }

        _strategyInvested = 0;

        emit StrategyDivested(address(strategy), settled);
    }

    // ---------------------------------------------------------------------
    // Admin: fee configuration (dormant; everything is 0 by default)
    // ---------------------------------------------------------------------

    /// @notice Set entry and exit fees in basis points.
    /// @dev Enable a fee recipient FIRST via {setFeeRecipient}; fees cannot be
    ///      enabled while no recipient is set. Values are hard-capped at 10%.
    /// @param newEntryFeeBps Entry fee in bps (0 = disabled).
    /// @param newExitFeeBps Exit fee in bps (0 = disabled).
    function setFees(uint64 newEntryFeeBps, uint64 newExitFeeBps) external onlyOwner {
        if (newEntryFeeBps > _MAX_ENTRY_FEE_BPS) {
            revert EntryFeeTooHigh(newEntryFeeBps, uint64(_MAX_ENTRY_FEE_BPS));
        }
        if (newExitFeeBps > _MAX_EXIT_FEE_BPS) {
            revert ExitFeeTooHigh(newExitFeeBps, uint64(_MAX_EXIT_FEE_BPS));
        }
        if (_feeRecipient == address(0) && (newEntryFeeBps != 0 || newExitFeeBps != 0)) {
            revert FeeRecipientNotSet();
        }

        emit EntryFeeUpdated(_entryFeeBps, newEntryFeeBps);
        emit ExitFeeUpdated(_exitFeeBps, newExitFeeBps);

        _entryFeeBps = newEntryFeeBps;
        _exitFeeBps = newExitFeeBps;
    }

    /// @notice Set the fee recipient.
    /// @dev Cannot be set back to the zero address while any fee is active, to
    ///      avoid a configuration where accrual targets nothing. To fully
    ///      disable fees, set both fees to 0 first, then (optionally) clear the
    ///      recipient.
    /// @param newRecipient Account that will receive accrued fees.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) && (_entryFeeBps != 0 || _exitFeeBps != 0)) {
            revert FeeRecipientInvalid();
        }

        address oldRecipient = _feeRecipient;
        _feeRecipient = newRecipient;

        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /// @notice Current entry fee in basis points.
    function entryFeeBps() external view returns (uint64) {
        return _entryFeeBps;
    }

    /// @notice Current exit fee in basis points.
    function exitFeeBps() external view returns (uint64) {
        return _exitFeeBps;
    }

    /// @notice Current fee recipient (zero address = fees disabled).
    function feeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    /// @notice Fee denominator: 10_000 == 100.00%.
    function FEE_DIVISOR() external pure returns (uint256) {
        return _FEE_DIVISOR;
    }

    /// @notice Maximum entry fee in basis points (10.00%).
    function MAX_ENTRY_FEE_BPS() external pure returns (uint256) {
        return _MAX_ENTRY_FEE_BPS;
    }

    /// @notice Maximum exit fee in basis points (10.00%).
    function MAX_EXIT_FEE_BPS() external pure returns (uint256) {
        return _MAX_EXIT_FEE_BPS;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 overrides: fee hooks + reentrancy protection
    // ---------------------------------------------------------------------

    /// @inheritdoc ERC4626
    /// @dev Deposit/mint workflow with the entry-fee hook.
    ///
    ///      Deposits are NOT automatically routed to the strategy: binding a
    ///      strategy never moves funds (pinned by tests), assets accumulate
    ///      idle, and the owner invests explicitly via {investIdle}. This
    ///      keeps deposits gas-flat and independent of strategy state.
    ///
    ///      `shares` is the FULL ERC-4626 share amount for the gross `assets`
    ///      entering the vault: depositors are not diluted by entry fees (the
    ///      fee is paid out of the deposited assets, not by minting extra
    ///      shares). With fees at 0 this is byte-for-byte the standard flow.
    ///
    ///      Checks-effects-interactions: state updates happen inside the
    ///      inherited flow before the fee payout; the whole flow is guarded by
    ///      {ReentrancyGuard} (the asset could be an ERC-777 or otherwise
    ///      callback-capable token).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        virtual
        override
        nonReentrant
    {
        uint256 fee = _calculateEntryFee(assets);

        // Pull assets, mint shares, emit ERC-4626 `Deposit`.
        super._deposit(caller, receiver, assets, shares);

        if (fee != 0) {
            SafeERC20.safeTransfer(IERC20(asset()), _feeRecipient, fee);
        }
    }

    /// @inheritdoc ERC4626
    /// @dev Withdraw/redeem workflow with the exit-fee hook.
    ///
    ///      The vault burns the full share amount and transfers out
    ///      `assets - exitFee` to `receiver`, paying the fee to the fee
    ///      recipient. The ERC-4626 `Withdraw` event reports the GROSS asset
    ///      amount `assets` (the vault-side redemption value implied by the
    ///      standard preview math); net received equals `assets - exitFee`.
    ///      With fees at 0, gross == net and this is the standard flow.
    ///
    ///      Checks-effects-interactions: allowance spend and share burn (state)
    ///      happen before any external token transfer.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
        nonReentrant
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Burn shares first (effects before interactions).
        _burn(owner, shares);

        IERC20 token = IERC20(asset());
        uint256 idle = token.balanceOf(address(this));
        if (idle < assets) {
            // Insufficient idle liquidity: pull the shortfall from the bound
            // strategy. The strategy is vault-gated and must settle in full,
            // otherwise the whole redemption reverts (shares included) and
            // no accounting changes.
            uint256 shortfall = assets - idle;
            IStrategy strategy = _strategy;
            if (strategy == IStrategy(address(0))) {
                revert DivestShortfall(assets, idle);
            }

            strategy.divest(shortfall);

            uint256 settled = token.balanceOf(address(this));
            if (settled < assets) {
                revert DivestShortfall(assets, settled);
            }

            // Ledger decrement is floored at zero: if the strategy returned
            // more than it was owed (e.g. donated tokens it held on top), the
            // extra simply becomes idle balance.
            _strategyInvested = shortfall >= _strategyInvested ? 0 : _strategyInvested - shortfall;

            emit StrategyDivested(address(strategy), shortfall);
        }

        uint256 fee = _calculateExitFee(assets);
        uint256 netAssets = assets - fee; // fee <= assets by construction

        if (fee != 0) {
            _transferOut(_feeRecipient, fee);
        }
        _transferOut(receiver, netAssets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @notice Validate a candidate strategy's self-reported bindings before
    ///         storing it. A zero address is always valid (clears the binding).
    /// @dev These are sanity checks against the strategy's own reports; they do
    ///      not prove the strategy is safe. Deeper trust assumptions belong to
    ///      the future allocation milestone (and to governance review).
    function _validateStrategyBinding(IStrategy newStrategy) internal view {
        if (address(newStrategy) == address(0)) {
            return;
        }
        // Staticcall-based view reads; a malformed strategy reverts here.
        if (newStrategy.vault() != address(this)) {
            revert StrategyVaultMismatch(address(this), newStrategy.vault());
        }
        if (newStrategy.asset() != asset()) {
            revert StrategyAssetMismatch(asset(), newStrategy.asset());
        }
    }

    /// @notice Entry fee owed on `assets` entering the vault. Zero while fees
    ///         are disabled (default state).
    function _calculateEntryFee(uint256 assets) private view returns (uint256) {
        if (_entryFeeBps == 0 || _feeRecipient == address(0)) {
            return 0;
        }
        return (assets * _entryFeeBps) / _FEE_DIVISOR;
    }

    /// @notice Exit fee owed on `assets` leaving the vault. Zero while fees
    ///         are disabled (default state).
    function _calculateExitFee(uint256 assets) private view returns (uint256) {
        if (_exitFeeBps == 0 || _feeRecipient == address(0)) {
            return 0;
        }
        return (assets * _exitFeeBps) / _FEE_DIVISOR;
    }
}
