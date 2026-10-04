// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategy
/// @notice Minimal interface for a strategy that AscendVault can allocate idle
///         funds to. This is a foundation placeholder: the vault only stores the
///         strategy address and emits events today. Active allocation,
///         accounting, and lifecycle rules are intentionally NOT implemented
///         yet and will be specified in a future iteration of AscendMM.
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

    /// @notice Underlying ERC20 asset the strategy operates on.
    /// @return The asset contract address (must match the vault's asset).
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

    /// @notice Move `assets` underlying tokens from the caller (expected to be
    ///         the vault) into the strategy.
    /// @dev Will be exercised by a future vault iteration. Implementations
    ///      MUST restrict the caller to the vault and MUST NOT assume the
    ///      tokens were pulled on their behalf.
    /// @param assets Amount of underlying asset to invest.
    function invest(uint256 assets) external;

    /// @notice Move `assets` underlying tokens held by the strategy back to
    ///         the vault.
    /// @dev Will be exercised by a future vault iteration. Implementations
    ///      MUST restrict the caller to the vault.
    /// @param assets Amount of underlying asset to return to the vault.
    function divest(uint256 assets) external;

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

    /// @notice Emitted after a profit/loss report.
    /// @param profit Signed profit (>= 0) or loss (< 0) in asset units.
    event Reported(int256 profit);
}
