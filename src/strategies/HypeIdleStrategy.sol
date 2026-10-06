// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IHypeStrategy} from "../interfaces/IHypeStrategy.sol";

/// @title HypeIdleStrategy
/// @notice First native-asset AscendMM strategy: custody-holds native HYPE
///         (the Elysium gas asset) and nothing else. Native counterpart of
///         the ERC-20 `IdleStrategy`, bound to {AscendVaultHype}.
///         Implements {IHypeStrategy} — the native specialization of the
///         unified {IStrategy} — so it satisfies the same strategy surface as
///         every other AscendMM strategy.
///
///         Deliberately simple and safe:
///          * No lending, staking, swapping, or ANY external protocol.
///          * No yield is generated, claimed, or simulated — `report()` is
///            always flat (0) and `harvest()` is a no-op that reports 0.
///            There is NO fake APY anywhere in this contract.
///          * Value moves only between this strategy and the vault it is
///            bound to ({onlyVault}).
///          * `totalAssets()` is the raw native balance of this contract.
///
///         Native-value safety model:
///          * The ONLY way value enters this contract is {invest}, which is
///            restricted to the vault and requires `msg.value == assets`
///            exactly — partial or over-sized sends revert. There is no
///            `receive()`/`fallback()`, so accidental plain transfers of
///            HYPE revert instead of being silently absorbed.
///          * {divest} pushes value back to the vault (msg.sender) with a
///            limited-stipend `call` and reverts on failure, so a failed
///            exit can never strand accounting. {divestAll} uses the same
///            mechanism for the entire balance.
///
/// @dev `cap()` is enforced by the vault against its own investment ledger
///      before `invest` is ever called. A real yield strategy would later
///      replace this contract via the vault's exit-then-bind migration path.
///      Behavioral note: the pre-existing functions (bindings, errors,
///      checks, events) are behavior-preserved exactly — this contract is
///      deployed on Kinetiq Elysium testnet.
contract HypeIdleStrategy is IHypeStrategy {
    // ---------------------------------------------------------------------
    // Immutable bindings
    // ---------------------------------------------------------------------

    /// @inheritdoc IStrategy
    address public immutable override vault;

    /// @inheritdoc IStrategy
    uint256 public immutable override cap;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Zero address passed where a real address is required.
    error HypeStrategyZeroAddress();

    /// @notice Caller is not the vault this strategy is bound to.
    error NotVault(address caller);

    /// @notice `invest` was called with a value different from `assets`.
    ///         The exact-match check is what makes vault-side settlement
    ///         verification meaningful.
    error HypeStrategyValueMismatch(uint256 expected, uint256 attached);

    /// @notice Asked to divest more native HYPE than the strategy holds.
    error DivestShortfall(uint256 requested, uint256 held);

    /// @notice The native transfer back to the vault failed (e.g. the vault
    ///         rejected value). Reverting leaves both sides unchanged.
    error HypeTransferFailed(uint256 amount);

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

    /// @notice Deploy the native idle strategy.
    /// @param vault_ Vault address allowed to invest/divest (cannot be zero).
    /// @param cap_ Upper bound on wei of HYPE this strategy manages. The
    ///        vault enforces it; `type(uint256).max` means unbounded.
    constructor(address vault_, uint256 cap_) {
        if (vault_ == address(0)) {
            revert HypeStrategyZeroAddress();
        }
        vault = vault_;
        cap = cap_;
    }

    // ---------------------------------------------------------------------
    // IHypeStrategy views
    // ---------------------------------------------------------------------

    /// @inheritdoc IHypeStrategy
    /// @dev Always the ERC-7528 native-asset sentinel: this strategy operates
    ///      on native HYPE, not on any ERC-20 token.
    function asset() external pure returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    /// @inheritdoc IStrategy
    /// @dev Raw native balance of this contract — the true amount attributable
    ///      to the strategy. Note: because the vault prices shares from its
    ///      own ledger (never this value), a forced donation of HYPE here
    ///      would only sit in custody; it cannot inflate the share price.
    function totalAssets() external view returns (uint256) {
        return address(this).balance;
    }

    // ---------------------------------------------------------------------
    // IHypeStrategy state-changing functions (vault-only)
    // ---------------------------------------------------------------------

    /// @inheritdoc IHypeStrategy
    /// @dev Native pull model: value arrives WITH this call. The exact-match
    ///      check means the strategy can never hold more (or less) than the
    ///      vault believes it invested via this path.
    function invest(uint256 assets) external payable onlyVault {
        if (msg.value != assets) {
            revert HypeStrategyValueMismatch(assets, msg.value);
        }
        emit Invested(assets);
    }

    /// @inheritdoc IHypeStrategy
    /// @dev Push model: sends native HYPE back to msg.sender (the vault).
    ///      Uses `call` with a limited stipend rather than `transfer` (per
    ///      the ERC-7535 security considerations) and reverts on failure so
    ///      neither side's state changes.
    function divest(uint256 assets) external onlyVault {
        uint256 held = address(this).balance;
        if (assets > held) {
            revert DivestShortfall(assets, held);
        }
        (bool ok,) = msg.sender.call{value: assets}(new bytes(0));
        if (!ok) {
            revert HypeTransferFailed(assets);
        }
        emit Divested(assets);
    }

    /// @notice Return the ENTIRE native balance to the caller (the vault).
    /// @inheritdoc IStrategy
    /// @dev Same push mechanics as {divest}: limited-stipend `call`, revert
    ///      on failure, and {Divested} emitted with the amount actually sent.
    ///      A zero balance is an idempotent no-op (emits `Divested(0)`).
    function divestAll() external onlyVault {
        uint256 held = address(this).balance;
        if (held != 0) {
            (bool ok,) = msg.sender.call{value: held}(new bytes(0));
            if (!ok) {
                revert HypeTransferFailed(held);
            }
        }
        emit Divested(held);
    }

    /// @notice No-op claim: idle custody of native HYPE earns nothing, so
    ///         this always emits a flat {Reported}(0). It never simulates or
    ///         fabricates yield.
    /// @dev Restricted to the bound vault like every other state-changing
    ///      entry point. Vaults MUST NOT change share pricing off this event
    ///      (same rule as {report}).
    function harvest() external onlyVault {
        emit Reported(0);
    }

    /// @inheritdoc IStrategy
    /// @dev Always flat: idle custody earns nothing and claims nothing.
    function report() external returns (int256 profit) {
        profit = 0;
        emit Reported(profit);
    }
}
