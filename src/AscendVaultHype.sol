// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626Hype} from "./interfaces/IERC4626Hype.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHypeStrategy} from "./interfaces/IHypeStrategy.sol";

/// @title AscendVaultHype
/// @notice ERC-7535 native-asset tokenized vault for AscendMM on Kinetiq
///         Elysium: a share-issuing vault whose underlying asset is native
///         HYPE (the chain's gas asset), moved as `msg.value` end to end.
///
///         Elysium publishes NO ERC-20 representation of HYPE ("native value
///         in both directions, no wrapper asset" — Elysium token-bridging
///         docs), so this vault implements the ERC-7535 native-asset vault
///         pattern instead of wrapping HYPE. No wrapper token is deployed or
///         required.
///
///         ERC-7535 extensions over the ERC-20 shape (per the Final EIP):
///          * `deposit` and `mint` are `payable` and key the accounting on
///            `msg.value` (the `assets` parameter is validated against it).
///          * `asset()` returns the ERC-7528 native-asset sentinel:
///            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
///          * Withdrawals and redeems pay out native HYPE via a limited-
///            stipend `call` (never `transfer` — see ERC-7535 security
///            considerations), and reverts on any payout failure.
///          * There is no approval flow for the asset: sending value with
///            the deposit IS the transfer.
///
///         Proven AscendMM accounting, preserved 1:1 from the ERC-20 track:
///          * Vault-side strategy investment ledger (`_strategyInvested`);
///            share pricing counts `address(this).balance + _strategyInvested`
///            and NEVER a strategy's self-reported `totalAssets()`, so a
///            lying strategy cannot move the share price.
///          * Deposits stay idle; the owner explicitly invests idle HYPE via
///            {investIdle} (settlement-verified) and pulls it back via
///            {exitStrategy}. Withdrawals automatically tap the strategy for
///            any shortfall, with exact settlement checks.
///          * Dormant fee architecture (entry/exit fees default 0, capped at
///            10% each, recipient must be set before any fee is enabled).
///          * Effects before interactions everywhere; {ReentrancyGuard} on
///            every share-minting/burning and strategy-funding path.
///
///         Accounting and security notes:
///          * {totalAssets} is the raw native balance plus the ledger —
///            forced HYPE donations (selfdestruct or any direct send that
///            bypasses {deposit}) therefore reprice shares exactly like
///            donations to an ERC-4626 vault's asset balance. The OZ virtual
///            share/asset offset (`_decimalsOffset` = 3 decimal places here)
///            makes donation-attacks on near-empty vaults non-profitable;
///            users should still protect large first deposits with slippage
///            checks.
///          * The contract has NO `receive()` and NO `fallback()`: plain
///            HYPE transfers to the vault revert. The only way value enters
///            is {deposit}/{mint} (exact value, validated) and the strategy-
///            gated `receive()` that accepts native HYPE ONLY while a bound
///            strategy's {divest} is pushing funds back (guarded by a
///            transient flag — see {_setReceivingHYPE}). The sole path that
///            may deliver untracked value is a forced send (selfdestruct),
///            which is donation accounting — see {totalAssets}.
///          * Share pricing uses `Math.mulDiv` with the same rounding
///           directions as ERC-4626 (Floor for depositor, Ceil for
///            minting more shares away / preview consistency).
///
/// @dev Status: FOUNDATION. Not audited. Intended for Elysium testnet first.
///      Fees and strategy accounting must be reviewed and finalized before any
///      production deployment.
contract AscendVaultHype is IERC4626Hype, ERC20, Ownable, ReentrancyGuard {
    using Math for uint256;

    // ---------------------------------------------------------------------
    // Native asset constant (ERC-7528)
    // ---------------------------------------------------------------------

    /// @notice ERC-7528 native-asset sentinel exposed by {asset()}.
    /// @dev 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
    address public constant NATIVE_ASSET_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Decimals offset for virtual shares/assets: 10^3 virtual
    ///         shares minted per 10^3 virtual assets against a zero-balance
    ///         vault, matching the OZ ERC-4626 donation-attack mitigation.
    /// @dev This gives 1/1000 non-withdrawable virtual shares to the vault
    ///      itself, making cannot-share-price manipulation via forced
    ///      donations uneconomical while keeping the vault fully ERC-20
    ///      (shares) standard.
    function _decimalsOffset() internal pure returns (uint8) {
        return 3;
    }

    // ---------------------------------------------------------------------
    // Types / constants: identical fee model as AscendVault (ERC-20 track)
    // ---------------------------------------------------------------------

    /// @notice Denominator for fee values expressed in basis points.
    uint256 private constant _FEE_DIVISOR = 10_000;

    /// @notice Hard upper bound for the entry fee (10.00%).
    uint256 private constant _MAX_ENTRY_FEE_BPS = 1_000;

    /// @notice Hard upper bound for the exit fee (10.00%).
    uint256 private constant _MAX_EXIT_FEE_BPS = 1_000;

    // ---------------------------------------------------------------------
    // Storage: identical layout philosophy as AscendVault (ERC-20 track)
    // ---------------------------------------------------------------------

    /// @notice Entry fee in basis points charged on assets entering the vault.
    uint64 private _entryFeeBps;

    /// @notice Exit fee in basis points charged on assets leaving the vault.
    uint64 private _exitFeeBps;

    /// @notice Receiver of accrued fees; zero address disables fees entirely.
    address private _feeRecipient;

    /// @notice Currently bound native strategy; zero address = none.
    IHypeStrategy private _strategy;

    /// @notice Vault-side ledger of wei of HYPE currently invested in the
    ///         bound strategy. This — never the strategy's self-reported
    ///         `totalAssets()` — is what share pricing counts for invested
    ///         assets, so a compromised strategy cannot inflate the
    ///         exchange rate by lying about its holdings.
    uint256 private _strategyInvested;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice deposit()/mint() was called with msg.value != the declared
    ///         asset amount. Native deposits are keyed on msg.value.
    error HypeVaultValueMismatch(uint256 declared, uint256 attached);

    /// @notice deposit()/mint() was called with zero value (the ERC-7535
    ///         vault deliberately rejects empty deposits).
    error HypeVaultZeroDeposit();

    /// @notice A native HYPE payout to `to` (receiver or fee recipient)
    ///         failed. The whole withdrawal/redeem reverts; accounting is
    ///         untouched.
    error HypeVaultTransferFailed(address to, uint256 amount);

    /// @notice Native HYPE arrived at the vault's `receive()` while no
    ///         strategy divest was in flight. Untracked value would break
    ///         the ledger model, so it is rejected (the transfer reverts).
    error ReceivingUnauthorized(address sender);

    /// @notice Share tokens were minted outside the deposit/mint flow
    ///         (impossible through the vault's own code; guarded for
    ///         defense in depth).
    error HypeMintUnauthorized(address to);

    /// @notice The vault itself was used to move share tokens (impossible
    ///         through the vault's own code; guarded for defense in depth).
    error HypeTransferUnauthorized(address from, address to, uint256 value);

    /// @notice The candidate strategy reports a different vault binding.
    error HypeStrategyVaultMismatch(address expected, address actual);

    /// @notice The candidate strategy reports a different underlying asset
    ///         (must be the ERC-7528 native sentinel).
    error HypeStrategyAssetMismatch(address expected, address actual);

    /// @notice Provided entry fee exceeds the protocol maximum.
    error HypeEntryFeeTooHigh(uint64 feeBps, uint64 maxFeeBps);

    /// @notice Provided exit fee exceeds the protocol maximum.
    error HypeExitFeeTooHigh(uint64 feeBps, uint64 maxFeeBps);

    /// @notice Fees were enabled before a fee recipient was configured.
    error HypeFeeRecipientNotSet();

    /// @notice Invalid fee recipient change (e.g. unsetting while fees active).
    error HypeFeeRecipientInvalid();

    /// @notice A strategy action was attempted while no strategy is bound.
    error HypeNoStrategySet();

    /// @notice The strategy binding cannot change while vault assets remain
    ///         invested in the current strategy. Exit first ({exitStrategy}).
    error HypeStrategyStillInvested(address strategy, uint256 invested);

    /// @notice More idle assets were requested for investment than the vault
    ///         currently holds.
    error HypeIdleBalanceTooLow(uint256 requested, uint256 idle);

    /// @notice Investing the requested amount would exceed the strategy cap.
    error HypeStrategyCapacityExceeded(uint256 projected, uint256 cap);

    /// @notice The vault balance after `invest` differs from the expected
    ///         post-invest balance: the strategy did not settle exactly what
    ///         was attached. The whole operation reverts.
    error HypeInvestSettlementMismatch(uint256 expectedBalance, uint256 actualBalance);

    /// @notice A withdrawal from the strategy settled less than required. The
    ///         whole operation reverts, leaving accounting untouched.
    error HypeDivestShortfall(uint256 required, uint256 settled);

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when the owner binds or clears the strategy.
    event HypeStrategyUpdated(IHypeStrategy indexed oldStrategy, IHypeStrategy indexed newStrategy);

    /// @notice Emitted when the owner updates the fee recipient.
    event HypeFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when the owner updates fee configurations.
    event HypeEntryFeeUpdated(uint64 oldFeeBps, uint64 newFeeBps);
    event HypeExitFeeUpdated(uint64 oldFeeBps, uint64 newFeeBps);

    /// @notice Emitted when the vault invests idle native HYPE into the
    ///         strategy.
    event HypeStrategyInvested(address indexed strategy, uint256 assets);

    /// @notice Emitted when the vault pulls native HYPE back from the
    ///         strategy.
    event HypeStrategyDivested(address indexed strategy, uint256 assets);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @notice Deploy the native-HYPE vault.
    /// @dev HYPE has 18 decimals; with the default 3-place virtual offset the
    ///      share token also exposes 18 decimals.
    /// @param name_ ERC20 name of the vault share token.
    /// @param symbol_ ERC20 symbol of the vault share token.
    /// @param initialOwner_ Account granted ownership (admin of fees and
    ///        strategy binding). Cannot be the zero address.
    constructor(string memory name_, string memory symbol_, address initialOwner_)
        ERC20(name_, symbol_)
        Ownable(initialOwner_)
    {}

    /// @notice Accepts native HYPE ONLY while a bound strategy is returning
    ///         funds to the vault ({divest} pushes value to msg.sender, i.e.
    ///         this vault). Any other native transfer reverts, so value can
    ///         never enter the vault untracked.
    receive() external payable {
        if (!_receivingHYPE) {
            revert ReceivingUnauthorized(msg.sender);
        }
    }

    /// @dev Share-token guard: shares may be minted ONLY by the deposit/mint
    ///      flow ({_minting} flag), and the vault itself must never move its
    ///      own shares. During a strategy divest the {receive()} value gate
    ///      is open, but share minting stays closed — a reentrant strategy
    ///      cannot mint itself shares mid-payout (defense in depth on top of
    ///      {ReentrancyGuard}).
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) && !_minting) {
            revert HypeMintUnauthorized(to);
        }
        if (from == address(this)) {
            revert HypeTransferUnauthorized(from, to, value);
        }
        super._update(from, to, value);
    }

    /// @notice True while the vault is receiving a strategy divest payout
    ///         ({receive()} gate); share minting is gated separately via
    ///         {_minting}.
    bool private _receivingHYPE;

    /// @notice True only inside the deposit/mint flow's share mint.
    bool private _minting;

    // ---------------------------------------------------------------------
    // ERC-7535: asset identity + total accounting
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC4626Hype
    /// @dev Always the ERC-7528 native-asset sentinel: this vault operates on
    ///      native HYPE, not on any ERC-20 token.
    function asset() public pure returns (address) {
        return NATIVE_ASSET_SENTINEL;
    }

    /// @notice Share-token decimals: HYPE's 18 decimals plus the 3-dec
    ///         virtual offset, exactly as OZ's ERC-4626 computes them.
    function decimals() public pure override returns (uint8) {
        return 18 + _decimalsOffset();
    }

    /// @notice Total native HYPE managed by the vault: idle native balance
    ///         plus the vault-side strategy ledger.
    /// @dev Deliberately does NOT consult the strategy's self-reported
    ///      `totalAssets()`: a compromised strategy could inflate it to
    ///      manipulate the share price. Assets are counted only after the
    ///      vault verifiably moved them into the strategy ({investIdle}).
    function totalAssets() public view returns (uint256) {
        return address(this).balance + _strategyInvested;
    }

    // ---------------------------------------------------------------------
    // Conversion helpers (ERC-4626 math, OZ-style virtual units)
    // ---------------------------------------------------------------------

    /// @dev Conversion helpers MUST price against a pre-interaction
    ///      snapshot of totalAssets: in payable deposit()/mint() the incoming
    ///      msg.value is credited BEFORE the body runs, so totalAssets() at
    ///      that point already includes the deposit being priced. Sharing
    ///      that snapshot avoids self-referential pricing.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return _convertToSharesAt(assets, totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return _convertToAssetsAt(shares, totalAssets(), rounding);
    }

    function _convertToSharesAt(uint256 assets, uint256 totalAssetsAt, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssetsAt + 1, rounding);
    }

    function _convertToAssetsAt(uint256 shares, uint256 totalAssetsAt, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        return shares.mulDiv(totalAssetsAt + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /// @inheritdoc IERC4626Hype
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626Hype
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626Hype
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626Hype
    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626Hype
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626Hype
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    // ---------------------------------------------------------------------
    // ERC-7535: deposit / mint (payable, msg.value-keyed)
    // ---------------------------------------------------------------------

    /// @notice Deposit native HYPE (`msg.value`) and mint shares to
    ///         `receiver`. Returns the shares minted.
    /// @dev The `assets` parameter MUST equal `msg.value` (checked, not
    ///      ignored — stricter than the ERC-7535 minimum). A nonzero assets
    ///      with zero attached value reverts: no silent zero-value deposits.
    ///      Shares are priced against the PRE-deposit totalAssets snapshot
    ///      (msg.value is credited before the body runs).
    ///      Value can only enter through this validated path (plus the
    ///      strategy-gated `receive()` during divest payouts).
    /// @param assets Amount of native HYPE attached (must equal msg.value).
    /// @param receiver Account receiving the minted shares.
    /// @return shares Shares minted for the deposit.
    function deposit(uint256 assets, address receiver)
        public
        payable
        override(IERC4626Hype)
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) {
            revert HypeVaultZeroDeposit();
        }
        if (msg.value != assets) {
            revert HypeVaultValueMismatch(assets, msg.value);
        }
        // Price against the PRE-deposit snapshot: msg.value is already
        // credited when the body runs.
        shares = _convertToSharesAt(assets, totalAssets() - assets, Math.Rounding.Floor);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @notice Mint exactly `shares` to `receiver` for a native HYPE
    ///         `msg.value` of `assets`. Returns the assets taken.
    /// @dev `assets` MUST equal `msg.value` exactly. The cost is computed
    ///      against the PRE-mint totalAssets snapshot, so depositors never
    ///      pay a self-referential price.
    /// @param shares Shares to mint for the receiver.
    /// @param receiver Account receiving the minted shares.
    /// @return assets Amount of native HYPE taken for the minted shares.
    function mint(uint256 shares, address receiver)
        public
        payable
        override(IERC4626Hype)
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) {
            revert HypeVaultZeroDeposit();
        }
        // Exact mint cost against the PRE-mint snapshot: msg.value is
        // already credited when the body runs.
        assets = _convertToAssetsAt(shares, totalAssets() - msg.value, Math.Rounding.Ceil);
        if (msg.value != assets) {
            revert HypeVaultValueMismatch(assets, msg.value);
        }
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @dev Deposit/mint common workflow (native equivalent of OZ ERC4626
    ///      _deposit, with native value already received):
    ///      1. Compute the entry fee (0 while fees are dormant).
    ///      2. Mint FULL share amount to the receiver (depositors are not
    ///         diluted by entry fees — the fee is paid out of the deposited
    ///         native value, exactly like the ERC-20 track).
    ///      3. Emit the standard ERC-4626 `Deposit` event.
    ///      4. Pay the entry fee out of the freshly received value (0 by
    ///         default). Fee transfer failure reverts the deposit so no
    ///         shares can ever exist without their backing native value.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        uint256 fee = _calculateEntryFee(assets);

        _minting = true;
        _mint(receiver, shares);
        _minting = false;
        emit Deposit(caller, receiver, assets, shares);

        if (fee != 0) {
            // Limited-stipend call (never `transfer`): Native HYPE payout to
            // the fee recipient. Reverts on failure.
            (bool sent,) = _feeRecipient.call{value: fee}(new bytes(0));
            if (!sent) {
                revert HypeVaultTransferFailed(_feeRecipient, fee);
            }
        }
    }

    // ---------------------------------------------------------------------
    // ERC-7535: withdraw / redeem (native payout)
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC4626Hype
    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /// @inheritdoc IERC4626Hype
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256 assets) {
        assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /// @dev Withdraw/redeem common workflow (native equivalent of OZ
    ///      ERC4626 _withdraw):
    ///      0. Shares shortfalls/auto-tap: the vault holds idle native value
    ///         and shares.
    ///      0b. Effects before interactions: burn shares FIRST.
    ///      1. Rebalance idle native balance against the strategy when idle
    ///         is insufficient.
    ///      2. Pay the exit fee (0 while dormant) using a limited-stipend
    ///         call, then the net assets: revert on any payout failure.
    ///      3. Emit the standard ERC-4626 `Withdraw` event.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Effects before interactions: burn shares FIRST.
        _burn(owner, shares);

        uint256 idle = address(this).balance;
        if (idle < assets) {
            // Insufficient idle liquidity: pull the shortfall from the bound
            // strategy. A native strategy MUST settle in full, otherwise the
            // whole redemption reverts (including the share burn) and no
            // accounting changes.
            uint256 shortfall = assets - idle;
            IHypeStrategy strategy = _strategy;
            if (address(strategy) == address(0)) {
                revert HypeDivestShortfall(assets, idle);
            }

            // Open the receive() gate for this strategy's native payout.
            _receivingHYPE = true;
            strategy.divest(shortfall);
            _receivingHYPE = false;

            uint256 settled = address(this).balance;
            if (settled < assets) {
                revert HypeDivestShortfall(assets, settled);
            }

            // Ledger decrement is floored at zero: if the strategy returned
            // more than it was owed (e.g. forced donations it held on top),
            // the extra simply becomes idle balance.
            _strategyInvested = shortfall >= _strategyInvested ? 0 : _strategyInvested - shortfall;

            emit HypeStrategyDivested(address(strategy), shortfall);
        }

        uint256 fee = _calculateExitFee(assets);
        uint256 netAssets = assets - fee; // fee <= assets by construction

        if (fee != 0) {
            (bool sent,) = _feeRecipient.call{value: fee}(new bytes(0));
            if (!sent) {
                revert HypeVaultTransferFailed(_feeRecipient, fee);
            }
        }

        // Limited-stipend call (never `transfer`): native HYPE payout to the
        // receiver. Reverts on failure (shares are already burned, so this is
        // a cold revert, not a trapped asset).
        (bool sent,) = receiver.call{value: netAssets}(new bytes(0));
        if (!sent) {
            revert HypeVaultTransferFailed(receiver, netAssets);
        }

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    // ---------------------------------------------------------------------
    // ERC-4626 max* views (identical semantics to the ERC-20 track)
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC4626Hype
    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IERC4626Hype
    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IERC4626Hype
    function maxWithdraw(address owner) public view returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    /// @inheritdoc IERC4626Hype
    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    // ---------------------------------------------------------------------
    // Admin: strategy binding
    // ---------------------------------------------------------------------

    /// @notice Bind or clear the vault's native strategy.
    /// @dev Validates the candidate's self-reported bindings (`vault()` /
    ///      `asset()`); `asset()` MUST be the ERC-7528 native sentinel.
    ///      Binding never moves funds; assets reach the strategy only via
    ///      {investIdle}. Switching or clearing is blocked while assets
    ///      remain invested — exit first via {exitStrategy}.
    ///      Re-binding the SAME strategy is always allowed (no-op).
    function setStrategy(IHypeStrategy newStrategy) external onlyOwner {
        _validateStrategyBinding(newStrategy);

        IHypeStrategy oldStrategy = _strategy;
        if (oldStrategy != newStrategy && _strategyInvested != 0) {
            revert HypeStrategyStillInvested(address(oldStrategy), _strategyInvested);
        }

        _strategy = newStrategy;

        emit HypeStrategyUpdated(oldStrategy, newStrategy);
    }

    /// @notice Currently bound native strategy (zero address if none).
    function strategy() external view returns (address) {
        return address(_strategy);
    }

    /// @notice Wei of HYPE the vault has currently invested in the bound
    ///         strategy (vault-side ledger; see {totalAssets}).
    function strategyInvested() external view returns (uint256) {
        return _strategyInvested;
    }

    // ---------------------------------------------------------------------
    // Admin: strategy funding / exit
    // ---------------------------------------------------------------------

    /// @notice Invest idle vault HYPE into the bound native strategy (owner-
    ///         only). Deposits stay idle; binding a strategy never moves
    ///         funds.
    /// @dev The value is sent WITH the `invest` call (native pull model):
    ///      `invest` receives exactly `assets` wei as msg.value. The vault
    ///      then verifies its own balance dropped by exactly `assets` — a
    ///      strategy that rejects, holds, or re-enters any other amount
    ///      makes the whole call revert (ledger rolls back).
    /// @param assets Wei of HYPE to invest (0 = no-op).
    function investIdle(uint256 assets) external onlyOwner nonReentrant {
        IHypeStrategy strategy = _strategy;
        if (address(strategy) == address(0)) {
            revert HypeNoStrategySet();
        }
        if (assets == 0) {
            return;
        }

        uint256 idle = address(this).balance;
        if (assets > idle) {
            revert HypeIdleBalanceTooLow(assets, idle);
        }
        uint256 projected = _strategyInvested + assets;
        if (projected > strategy.cap()) {
            revert HypeStrategyCapacityExceeded(projected, strategy.cap());
        }

        // Effect before interaction: the ledger moves first; the settlement
        // check below reverts (rolling everything back) unless the strategy
        // settled the exact value attached.
        _strategyInvested = projected;
        strategy.invest{value: assets}(assets);
        uint256 settledBalance = address(this).balance;
        if (settledBalance != idle - assets) {
            revert HypeInvestSettlementMismatch(idle - assets, settledBalance);
        }

        emit HypeStrategyInvested(address(strategy), assets);
    }

    /// @notice Pull all vault-owned HYPE back from the bound strategy (owner-
    ///         only). Required before replacing or clearing a strategy that
    ///         still holds invested assets. No-op when nothing is invested.
    function exitStrategy() external onlyOwner nonReentrant {
        IHypeStrategy strategy = _strategy;
        if (address(strategy) == address(0)) {
            revert HypeNoStrategySet();
        }

        uint256 invested = _strategyInvested;
        if (invested == 0) {
            return;
        }

        uint256 idleBefore = address(this).balance;

        // Open the receive() gate for this strategy's native payout.
        _receivingHYPE = true;
        strategy.divest(invested);
        _receivingHYPE = false;

        uint256 settled = address(this).balance - idleBefore;
        if (settled < invested) {
            revert HypeDivestShortfall(invested, settled);
        }

        _strategyInvested = 0;

        emit HypeStrategyDivested(address(strategy), settled);
    }

    // ---------------------------------------------------------------------
    // Admin: fee configuration (dormant; everything is 0 by default)
    // ---------------------------------------------------------------------

    /// @notice Set entry and exit fees in basis points. Values hard-capped
    ///         at 10%; a recipient must be set first.
    function setFees(uint64 newEntryFeeBps, uint64 newExitFeeBps) external onlyOwner {
        if (newEntryFeeBps > _MAX_ENTRY_FEE_BPS) {
            revert HypeEntryFeeTooHigh(newEntryFeeBps, uint64(_MAX_ENTRY_FEE_BPS));
        }
        if (newExitFeeBps > _MAX_EXIT_FEE_BPS) {
            revert HypeExitFeeTooHigh(newExitFeeBps, uint64(_MAX_EXIT_FEE_BPS));
        }
        if (_feeRecipient == address(0) && (newEntryFeeBps != 0 || newExitFeeBps != 0)) {
            revert HypeFeeRecipientNotSet();
        }

        emit HypeEntryFeeUpdated(_entryFeeBps, newEntryFeeBps);
        emit HypeExitFeeUpdated(_exitFeeBps, newExitFeeBps);

        _entryFeeBps = newEntryFeeBps;
        _exitFeeBps = newExitFeeBps;
    }

    /// @notice Set the fee recipient (zero address clears it, only while all
    ///         fees are 0).
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) && (_entryFeeBps != 0 || _exitFeeBps != 0)) {
            revert HypeFeeRecipientInvalid();
        }

        address oldRecipient = _feeRecipient;
        _feeRecipient = newRecipient;

        emit HypeFeeRecipientUpdated(oldRecipient, newRecipient);
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
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @notice Validate a candidate strategy's self-reported bindings before
    ///         storing it. A zero address is always valid (clears binding).
    function _validateStrategyBinding(IHypeStrategy newStrategy) internal view {
        if (address(newStrategy) == address(0)) {
            return;
        }
        if (newStrategy.vault() != address(this)) {
            revert HypeStrategyVaultMismatch(address(this), newStrategy.vault());
        }
        if (newStrategy.asset() != NATIVE_ASSET_SENTINEL) {
            revert HypeStrategyAssetMismatch(NATIVE_ASSET_SENTINEL, newStrategy.asset());
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
