// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategy} from "./IStrategy.sol";

/// @title IHypeStrategy
/// @notice Native-asset specialization of AscendMM's unified {IStrategy}: the
///         minimal surface {AscendVaultHype} needs to custody native HYPE.
/// @dev Deliberately a separate, narrower interface rather than a reuse of the
///      ERC-20 contract: the unified {IStrategy} fixes only signatures and
///      trust rules, while the native track pins the transfer mechanism to
///      the native pull model (`msg.value == assets` exactly). Since
///      Solidity 0.8.24 forbids mutability changes in overrides in BOTH
///      directions, {IStrategy.invest} is declared `payable` (the native
///      shape) and this interface re-declares it unchanged to document the
///      native contract; ERC-20 implementations keep their `invest` payable
///      only to satisfy the base interface while ignoring native value. Every
///      other function is inherited unmodified from {IStrategy}, and the
///      shared events are declared once there (re-declaring them in an
///      inheriting interface causes compile errors). The ERC-20 track
///      (`AscendVault` + `IStrategy` + `IdleStrategy`) keeps its behavior;
///      only the signature shape is unified so both tracks recognize one base
///      interface. Vault-side trust rules port 1:1: implementers MUST
///      restrict invest/divest/divestAll to their bound vault, and the vault
///      must never price shares off the strategy's self-reported
///      `totalAssets()`.
interface IHypeStrategy is IStrategy {
    /// @notice Underlying asset the strategy operates on. Native-asset
    ///         strategies report the ERC-7528 sentinel:
    ///         0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
    /// @dev Re-declared to pin native-asset documentation onto the inherited
    ///      ERC-20-generalized signature; `IHypeStrategy.asset` remains
    ///      selector-identical to `IStrategy.asset`.
    function asset() external view returns (address);

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
}
