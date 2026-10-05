// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC4626Hype
/// @notice ERC-4626 vault interface with the ERC-7535 native-asset
///         deviations applied: `deposit` and `mint` are `payable` and keyed
///         on `msg.value`, and the underlying asset is the ERC-7528 native
///         sentinel `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.
/// @dev Deliberately a local copy of OpenZeppelin's `IERC4626`: OZ's
///      interface declares `deposit`/`mint` nonpayable, which cannot be
///      overridden as payable (Solidity forbids weakening-to-strengthening
///      mutability changes against an interface). Function SELECTORS are
///      identical to ERC-4626 (mutability is not part of a selector), so
///      ABI-level compatibility with ERC-4626 tooling is preserved. Events
///      and errors are identical to ERC-4626.
interface IERC4626Hype {
    // ------------------------------------------------------------------
    // Events (identical to ERC-4626)
    // ------------------------------------------------------------------

    /// @notice Emitted when `assets` of native HYPE deposited by `sender`
    ///         mints `shares` for `receiver`.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted when `shares` redeemed by `sender` pays out `assets`
    ///         of native HYPE to `receiver`.
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    // ------------------------------------------------------------------
    // Errors (identical to OZ IERC4626)
    // ------------------------------------------------------------------

    /// @notice Attempted to deposit more assets than the max amount.
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);

    /// @notice Attempted to mint more shares than the max amount.
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);

    /// @notice Attempted to withdraw more assets than the max amount.
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);

    /// @notice Attempted to redeem more shares than the max amount.
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The ERC-7528 native-asset sentinel for native-asset vaults.
    function asset() external view returns (address);

    /// @notice Total native HYPE managed by the vault (idle + invested).
    function totalAssets() external view returns (uint256);

    /// @notice Shares minted for `assets` of native HYPE (floor).
    function convertToShares(uint256 assets) external view returns (uint256);

    /// @notice Native HYPE returned for `shares` (floor).
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Maximum native HYPE that may be deposited.
    function maxDeposit(address receiver) external view returns (uint256);

    /// @notice Maximum shares that may be minted.
    function maxMint(address receiver) external view returns (uint256);

    /// @notice Maximum native HYPE `owner` may withdraw.
    function maxWithdraw(address owner) external view returns (uint256);

    /// @notice Maximum shares `owner` may redeem.
    function maxRedeem(address owner) external view returns (uint256);

    /// @notice Shares minted for a deposit of `assets` (floor).
    function previewDeposit(uint256 assets) external view returns (uint256);

    /// @notice Native HYPE required to mint `shares` (ceil).
    function previewMint(uint256 shares) external view returns (uint256);

    /// @notice Shares burned to withdraw `assets` (ceil).
    function previewWithdraw(uint256 assets) external view returns (uint256);

    /// @notice Native HYPE paid out for `shares` (floor).
    function previewRedeem(uint256 shares) external view returns (uint256);

    // ------------------------------------------------------------------
    // State-changing functions
    // ------------------------------------------------------------------

    /// @notice Deposit exactly `msg.value` native HYPE, mint shares.
    /// @dev ERC-7535: payable; `msg.value` is the primary input. This
    ///      implementation additionally requires `assets == msg.value`.
    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares);

    /// @notice Mint exactly `shares` against `msg.value` native HYPE.
    /// @dev ERC-7535: payable; `msg.value` is the primary input. This
    ///      implementation additionally requires `assets == msg.value`.
    function mint(uint256 shares, address receiver) external payable returns (uint256 assets);

    /// @notice Burn `shares` from `owner`, pay `assets` native HYPE to
    ///         `receiver`.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Burn `shares` from `owner`, pay the implied native HYPE to
    ///         `receiver`.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
