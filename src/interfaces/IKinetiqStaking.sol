// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Kinetiq kHYPE integration interfaces
/// @notice Verbatim transcription (signatures and doc intent) of Kinetiq's
///         OFFICIAL simplified integration interfaces for the kHYPE liquid-
///         staking protocol, published in the `khype.zip` bundle linked from
///         the Kinetiq integration docs (kinetiq.xyz → Contracts & Audits /
///         integration page, retrieved 2026-10-06):
///         https://kinetiq.xyz/assets/share/contract-interfaces/khype.zip
///
///         The bundle ships `IStakingManager.sol`, `IStakingAccountant.sol`
///         and `IKHYPE.sol`; they are transcribed here into a single file,
///         unchanged in signatures and semantics. Nothing in this file is
///         inferred: if Kinetiq's published interface does not expose it, it
///         is not here. No addresses are embedded — Kinetiq has not published
///         any kHYPE/StakingManager deployment for Elysium (chain 99801) yet,
///         so every address is a deploy-time constructor parameter.
///
/// @dev Transcribed signatures are the ONLY sanctioned integration surface.
///      Do not add members to these interfaces without re-verifying them
///      against an official Kinetiq release.
interface IStakingManager {
    /* ========== STRUCTS ========== */

    struct WithdrawalRequest {
        uint256 hypeAmount; // Amount in HYPE to withdraw
        uint256 kHYPEAmount; // Amount in kHYPE to burn (excluding fee)
        uint256 kHYPEFee; // Fee amount in kHYPE tokens
        uint256 bufferUsed; // Amount fulfilled from hypeBuffer
        uint256 timestamp; // Request timestamp
    }

    /* ========== EVENTS ========== */

    event StakeReceived(address indexed staking, address indexed staker, uint256 amount);
    event WithdrawalQueued(
        address indexed staking,
        address indexed user,
        uint256 indexed withdrawalId,
        uint256 kHYPEAmount,
        uint256 hypeAmount,
        uint256 feeAmount
    );
    event WithdrawalConfirmed(address indexed user, uint256 indexed withdrawalId, uint256 amount);
    event InstantUnstakeExecuted(
        address indexed user,
        uint256 kHYPEAmount,
        uint256 hypeReceived,
        uint256 kHYPEFee,
        uint256 feeRateBps,
        uint256 kHYPEFeeBurned,
        uint256 kHYPEFeeToTreasury
    );

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Gets the total amount of HYPE staked
    function totalStaked() external view returns (uint256);

    /// @notice Gets the current HYPE buffer amount
    function hypeBuffer() external view returns (uint256);

    /// @notice Gets the minimum stake amount per transaction
    function minStakeAmount() external view returns (uint256);

    /// @notice Gets the minimum withdrawal amount
    function minWithdrawalAmount() external view returns (uint256);

    /// @notice Gets the withdrawal delay period
    function withdrawalDelay() external view returns (uint256);

    /// @notice Gets the quick withdrawal delay period (for buffer-only withdrawals)
    function quickWithdrawalDelay() external view returns (uint256);

    /// @notice Gets withdrawal request details for a user
    function withdrawalRequests(address user, uint256 id) external view returns (WithdrawalRequest memory);

    /// @notice Gets the next withdrawal ID for a user
    function nextWithdrawalId(address user) external view returns (uint256);

    /// @notice Gets the current unstake fee rate in basis points
    function unstakeFeeRate() external view returns (uint256);

    /// @notice Gets the basis points constant (10000 = 100%)
    function BASIS_POINTS() external view returns (uint256);

    /// @notice Gets the instant unstake pool address
    function instantUnstakePool() external view returns (address);

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Stakes HYPE tokens and receives kHYPE in return
    function stake() external payable;

    /// @notice Queues a withdrawal request
    /// @param kHYPEAmount Amount of kHYPE to withdraw
    function queueWithdrawal(uint256 kHYPEAmount) external;

    /// @notice Confirms a withdrawal request after the delay period
    /// @param withdrawalId The ID of the withdrawal to confirm
    function confirmWithdrawal(uint256 withdrawalId) external;

    /// @notice Instant unstake - withdraw HYPE immediately from buffer with flat fee
    /// @param kHYPEAmount Amount of kHYPE to unstake
    /// @param minHYPEOut Minimum HYPE to receive (slippage protection)
    function instantUnstake(uint256 kHYPEAmount, uint256 minHYPEOut) external;
}

/// @notice Official Kinetiq exchange-rate oracle for kHYPE: the accountant is
///         the protocol's canonical kHYPE↔HYPE conversion source. Yield
///         accrues by the exchange rate rising over time; it is realized only
///         when kHYPE is redeemed.
interface IStakingAccountant {
    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Gets the total amount of HYPE staked across all managers
    function totalStaked() external view returns (uint256);

    /// @notice Gets the total amount of HYPE claimed
    function totalClaimed() external view returns (uint256);

    /// @notice Gets total rewards accrued
    function totalRewards() external view returns (uint256);

    /// @notice Gets total slashing losses
    function totalSlashing() external view returns (uint256);

    /// @notice Convert kHYPE amount to HYPE using current exchange rate
    /// @param kHYPEAmount Amount of kHYPE to convert
    /// @return Equivalent HYPE amount
    function kHYPEToHYPE(uint256 kHYPEAmount) external view returns (uint256);

    /// @notice Convert HYPE amount to kHYPE using current exchange rate
    /// @param HYPEAmount Amount of HYPE to convert
    /// @return Equivalent kHYPE amount
    function HYPEToKHYPE(uint256 HYPEAmount) external view returns (uint256);
}

/// @notice Official kHYPE token interface: an access-controlled ERC-20 with
///         mint/burn roles and EIP-2612 permit.
interface IKHYPE is IERC20, IAccessControl {
    /// @notice Mints new tokens to the specified address
    /// @dev Only callable by addresses with MINTER_ROLE
    /// @param to Address to receive the minted tokens
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burns tokens from the specified address
    /// @dev Only callable by addresses with BURNER_ROLE
    /// @param from Address to burn tokens from
    /// @param amount Amount of tokens to burn
    function burn(address from, uint256 amount) external;

    /// @notice EIP-2612 permit for gasless approvals
    /// @param owner Token owner
    /// @param spender Address to approve
    /// @param value Amount to approve
    /// @param deadline Signature expiry timestamp
    /// @param v Signature component
    /// @param r Signature component
    /// @param s Signature component
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;

    /// @notice Role identifier for addresses allowed to mint tokens
    function MINTER_ROLE() external view returns (bytes32);

    /// @notice Role identifier for addresses allowed to burn tokens
    function BURNER_ROLE() external view returns (bytes32);
}
