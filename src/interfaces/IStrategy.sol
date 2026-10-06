// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategy
/// @notice Minimal, mechanism-agnostic interface for a strategy that an
///         AscendMM vault can allocate idle funds to. Shared by BOTH vault
///         tracks: the ERC-20 track binds strategies typed as `IStrategy`
///         directly, and the native-HYPE track binds them as `IHypeStrategy`
///         (a specialization of this interface — see {IHypeStrategy}).
///
///         The interface fixes only signatures and the trust rules below.
///         The asset-transfer mechanism is intentionally implementation-
///         defined: ERC-20 strategies pull tokens via a vault-granted
///         allowance, native strategies receive the value as `msg.value`
///         with the call. For that reason `invest` is declared `payable` —
///         the native shape — and ERC-20 implementations keep the function
///         payable solely to satisfy the interface while never using native
///         value (Solidity 0.8.24 forbids overriding a non-payable function
///         as payable, so a non-payable base declaration would make the
///         unified interface impossible).
/// @dev Implementations MUST validate the asset relationship against the vault
///      they are bound to before any funds move. Any future vault-side entry
///      point that moves funds into the strategy is expected to re-validate
///      `asset()` and `vault()` at call time rather than trusting stored state.
interface IStrategy {
    // ------------------------------------------------------------------
    // View functions
    // ------------------------------------------------------------------

    /// @notice Address of the vault this strategy is bound to.
    /// @return The vault contract address.
    function vault() external view returns (address);

    /// @notice Underlying asset the strategy operates on: an ERC-20 token
    ///         address, or the ERC-7528 native-asset sentinel
    ///         (0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) for native-value
    ///         strategies.
    /// @return The asset address (must match the bound vault's asset).
    function asset() external view returns (address);

    /// @notice Upper bound (in assets) the strategy is allowed to manage.
    /// @return The cap in underlying-asset units.
    function cap() external view returns (uint256);

    /// @notice Amount of the underlying asset currently managed by the
    ///         strategy, as reported by the strategy itself.
    /// @dev Informational only. The vault MUST NOT use this value for share
    ///      pricing until a full strategy-accounting design is reviewed and
    ///      shipped; a compromised or buggy strategy could report inflated
    ///      balances.
    /// @return Total assets under the strategy's control.
    function totalAssets() external view returns (uint256);

    // ------------------------------------------------------------------
    // State-changing functions
    // ------------------------------------------------------------------

    /// @notice Move `assets` underlying tokens from the caller (expected to
    ///         be the vault) into the strategy.
    /// @dev Transfer mechanism is implementation-defined:
    ///        * ERC-20 strategies pull via a vault-granted exact-amount
    ///          allowance (implementations MUST NOT assume the tokens were
    ///          delivered ahead of the call) and MUST NOT rely on native
    ///          value; the ERC-20 vault never attaches any. Declaring the
    ///          function `payable` is required by this unified interface;
    ///          such implementations simply ignore `msg.value`.
    ///        * Native strategies receive the value WITH the call and MUST
    ///          require `msg.value == assets` exactly (see
    ///          {IHypeStrategy.invest}).
    ///      Implementations MUST restrict the caller to the bound vault.
    /// @param assets Amount of underlying asset to invest.
    function invest(uint256 assets) external payable;

    /// @notice Move `assets` underlying tokens held by the strategy back to
    ///         the vault.
    /// @dev Implementations MUST restrict the caller to the bound vault.
    /// @param assets Amount of underlying asset to return to the vault.
    function divest(uint256 assets) external;

    /// @notice Return the strategy's ENTIRE managed holdings to the vault
    ///         (msg.sender). Convenience companion to {divest}: for a
    ///         custodial strategy this is equivalent to
    ///         `divest(totalAssets())` without the race between reading the
    ///         balance and divesting it.
    /// @dev Implementations MUST restrict the caller to the bound vault and
    ///      MUST emit {Divested} with the amount actually returned. A zero
    ///      balance SHOULD be an idempotent no-op (still emitting
    ///      `Divested(0)`). The transfer mechanism is implementation-defined
    ///      (ERC-20 push vs native push). Note: on the current native-HYPE
    ///      vault the strategy's payout is accepted only while the vault
    ///      itself is pulling (its gated `receive()`), so the vault's own
    ///      flows keep using {divest}; {divestAll} is exercised directly by
    ///      the bound vault or by future vault iterations that open the gate
    ///      for it.
    function divestAll() external;

    /// @notice Claim any yield the strategy has accrued and realize it via a
    ///         {Reported} event (signed profit/loss since the last report).
    /// @dev Zero-yield custodial strategies implement this as a no-op that
    ///      reports flat 0 — they MUST NOT simulate or fabricate yield.
    ///      Access control is implementation-defined (custodial
    ///      implementations restrict it to the bound vault). Vaults MUST NOT
    ///      change share pricing based on {harvest} until a reviewed
    ///      profit-realization design ships (same rule as {report}).
    function harvest() external;

    /// @notice Report realized profit (positive) or loss (negative) since the
    ///         last report, denominated in the underlying asset.
    /// @dev Signature is provisional and may change when strategy accounting
    ///      is designed. Vaults must not rely on it yet.
    /// @return profit Signed profit/loss in underlying-asset units.
    function report() external returns (int256 profit);

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice Emitted when the strategy invests underlying assets.
    /// @param assets Amount invested.
    event Invested(uint256 assets);

    /// @notice Emitted when the strategy returns underlying assets to the
    ///         vault.
    /// @param assets Amount divested.
    event Divested(uint256 assets);

    /// @notice Emitted after a profit/loss report (including a flat
    ///         {harvest} of a zero-yield strategy).
    /// @param profit Signed profit (>= 0) or loss (< 0) in asset units.
    event Reported(int256 profit);
}
