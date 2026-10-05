// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHypeStrategy
/// @notice Native-asset counterpart of AscendMM's ERC-20 `IStrategy`: the
///         minimal surface {AscendVaultHype} needs to custody native HYPE.
/// @dev Deliberately a separate interface. The ERC-20 `IStrategy` is
///      hard-wired to ERC-20 transfer assumptions: `invest` pulls tokens via
///      `transferFrom` against a vault-granted allowance and `divest` pushes
///      tokens with `safeTransfer`. Native HYPE moves as `msg.value` and has
///      no allowance concept, so reusing `IStrategy` would force unsafe
///      reinterpretations of its documented contract. The ERC-20 track
///      (`AscendVault` + `IStrategy` + `IdleStrategy`) stays untouched and
///      fully independent; only the signature shape (views + invest/divest/
///      report) is mirrored so the proven vault-side trust model ports 1:1.
interface IHypeStrategy {
    // ------------------------------------------------------------------
    // View functions
    // ------------------------------------------------------------------

    /// @notice Address of the vault this strategy is bound to.
    function vault() external view returns (address);

    /// @notice Underlying asset the strategy operates on. Native-asset
    ///         strategies report the ERC-7528 sentinel:
    ///         0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
    function asset() external view returns (address);

    /// @notice Upper bound (in wei of HYPE) the strategy is allowed to manage.
    function cap() external view returns (uint256);

    /// @notice Amount of native HYPE currently managed by the strategy, as
    ///         reported by the strategy itself (raw balance).
    /// @dev Informational only. The vault MUST NOT use this value for share
    ///      pricing — the same rule as the ERC-20 track. Share pricing counts
    ///      the vault's own investment ledger, never a strategy self-report.
    function totalAssets() external view returns (uint256);

    // ------------------------------------------------------------------
    // State-changing functions
    // ------------------------------------------------------------------

    /// @notice Receive exactly `assets` wei of native HYPE from the caller
    ///         (expected to be the vault).
    /// @dev Native pull model: the value arrives WITH the call, so
    ///      `msg.value` must equal `assets`. Implementations MUST restrict
    ///      the caller to `vault()` and MUST NOT keep or forward any value
    ///      beyond what the vault believes it invested (the vault verifies
    ///      settlement by measuring its own balance after this call).
    /// @param assets Amount of native HYPE attached to this call.
    function invest(uint256 assets) external payable;

    /// @notice Return `assets` wei of native HYPE to the caller (expected to
    ///         be the vault).
    /// @dev Push model: the strategy sends native value to `msg.sender`. A
    ///      failed native transfer MUST revert (failed divest = no state
    ///      change on either side). Implementations MUST restrict the caller
    ///      to `vault()`.
    /// @param assets Amount of native HYPE to return.
    function divest(uint256 assets) external;

    /// @notice Report realized profit (positive) or loss (negative) since the
    ///         last report, denominated in wei of HYPE.
    /// @dev Informational only; the vault does not rely on it. Mirrors the
    ///      ERC-20 `IStrategy.report` shape.
    /// @return profit Signed profit (>= 0) or loss (< 0) in wei of HYPE.
    function report() external returns (int256 profit);

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice Emitted when the strategy receives invested native HYPE.
    event Invested(uint256 assets);

    /// @notice Emitted when the strategy returns native HYPE to the vault.
    event Divested(uint256 assets);

    /// @notice Emitted after a profit/loss report.
    event Reported(int256 profit);
}
