// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {StrategyRegistry} from "../StrategyRegistry.sol";
import {VaultRegistry} from "../VaultRegistry.sol";

/*//////////////////////////////////////////////////////////////////////////
 Minimal typed surfaces the keeper operates on. Both vault tracks (ERC-4626
 `AscendVault` and native-HYPE `AscendVaultHype`, plus their Phase 2G guarded
 variants) expose the core selectors; the guarded variants additionally expose
 the control selectors. Capability probing is done per target at call time.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Core vault surface shared by every AscendMM vault track/variant.
interface IVaultCore {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function strategy() external view returns (address);
    function strategyInvested() external view returns (uint256);
    function investIdle(uint256 assets) external;
    function exitStrategy() external;
}

/// @notice Guarded-vault control surface (Phase 2G: `AscendVaultGuarded` /
///         `AscendVaultHypeGuarded`). Base vaults do NOT expose these.
interface IGuardedVaultControl {
    function totalAssetCap() external view returns (uint256);
    function depositsPaused() external view returns (bool);
    function setDepositsPaused(bool paused) external;
    function setTotalAssetCap(uint256 newCap) external;
    function emergencyExitStrategy() external;
}

/// @title AutomationKeeper
/// @notice Phase 2I operational automation infrastructure for AscendMM: a
///         lightweight, permissioned keeper layer anchored on the protocol's
///         own registries. It can MONITOR every registered vault and strategy
///         (state read directly on-chain — the registries are the only source
///         of protocol truth; no off-chain database is consulted or needed)
///         and can EXECUTE the state-changing actions the current contracts
///         actually support, behind a two-layer permission model.
///
///         What it deliberately does NOT do:
///          * No harvest/rebalance actions: no live yield strategy exists on
///            Elysium 99801 (the Kinetiq kHYPE adapter is inactive and no
///            other protocol is deployed), so there is nothing real to
///            harvest or rebalance and no such action is faked. When a real
///            yield strategy ships, a typed action is added for it here.
///          * No generic escape hatch (`execute(target, calldata)`-style):
///            arbitrary external calls from an automation layer are an
///            unacceptable blast radius. Every action is a typed function.
///          * No token, no governance, no keeper marketplace.
///
///         Permission model (two layers):
///          1. THIS layer: only the admin (owner) and explicitly authorized
///             keepers can submit actions (see {setKeeper}).
///          2. THE TARGET layer: every underlying function remains owner-only
///             on the vault/registry. Actions execute successfully only once
///             the protocol owner delegates the target's admin rights to this
///             keeper (e.g. by transferring ownership of the vault/registry
///             to it). Until then every underlying call reverts (fail closed)
///             and the submitted actionId stays unused and retryable — the
///             keeper never bypasses a target's own authorization.
///
///         Idempotency and duplicate prevention:
///          * Every action carries a caller-chosen `actionId` (bytes32, zero
///            rejected). Each id resolves exactly once — {DuplicateAction}
///            otherwise. The id is marked handled only inside the same
///            transaction as the underlying execution, so a reverted
///            execution (failed external call) leaves the id unused and
///            retryable.
///          * State-targeting actions (pauses, caps, registry active flags)
///            are additionally idempotent: when the target is already in the
///            requested state the keeper emits {ActionNoOp} instead of
///            re-executing (and still consumes the actionId — one request,
///            one resolution).
///
///         Monitoring: {vaultReport} and {strategyReport} aggregate current
///         on-chain state (registration, active flags, assets, ledgers, caps,
///         cap utilization inputs, pause state, strategy binding) into a
///         flag bitmask of anomalous conditions. Every flag is derived from
///         live contract reads; nothing is estimated or fabricated. The
///         strategy's self-reported `totalAssets()` is used ONLY as an
///         informational divergence hint — never for pricing (the vaults'
///         own ledger remains the source of truth).
contract AutomationKeeper is Ownable {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice Supported action types (typed; no generic call escape hatch).
    /// @dev Small enums are uint8-backed in Solidity, matching the event
    ///      `actionType` field.
    enum ActionType {
        SetVaultDepositsPaused,
        SetVaultCap,
        VaultEmergencyExit,
        VaultExitStrategy,
        VaultInvestIdle,
        SetStrategyActive,
        SetVaultActive
    }

    // ------------------------------------------------------------------
    // Immutable anchors
    // ------------------------------------------------------------------

    /// @notice The protocol's vault directory. Single source of truth for
    ///         which vaults exist; all keeper actions require the target
    ///         vault to be registered here.
    VaultRegistry public immutable vaultRegistry;

    /// @notice The protocol's strategy directory. Single source of truth for
    ///         which strategies exist and are active.
    StrategyRegistry public immutable strategyRegistry;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice Addresses authorized to submit actions (the admin is always
    ///         implicitly authorized).
    mapping(address keeper => bool authorized) private _keepers;

    /// @notice Action dedupe ledger: each submitted actionId resolves once.
    mapping(bytes32 actionId => bool handled) public actionHandled;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice Caller is neither the admin nor an authorized keeper.
    error NotKeeper(address caller);

    /// @notice Zero address passed where a real address is required.
    error ZeroAddress();

    /// @notice The submitted actionId is zero (accidental-noise guard).
    error ZeroActionId();

    /// @notice A zero amount was passed to a value-moving action.
    error ZeroAmount();

    /// @notice The target is not registered in the protocol's registry.
    error NotRegistered(address target);

    /// @notice The submitted actionId has already resolved.
    error DuplicateAction(bytes32 actionId);

    /// @notice The target contract does not support the requested action
    ///         (e.g. a deposits pause on a base vault that has no such
    ///         surface — only the Phase 2G guarded vaults do).
    error ActionNotSupported(address target);

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice Emitted when the admin authorizes or revokes a keeper.
    event KeeperUpdated(address indexed keeper, bool authorized);

    /// @notice Emitted when an action executes against its target. The
    ///         underlying contract emits its own state event alongside this
    ///         correlation record.
    event ActionExecuted(bytes32 indexed actionId, uint8 indexed actionType, address indexed target, address caller);

    /// @notice Emitted when a submitted action resolves as a no-op because
    ///         the target is already in the requested state (idempotent
    ///         execution). The actionId is consumed either way.
    event ActionNoOp(bytes32 indexed actionId, uint8 indexed actionType, address indexed target, address caller);

    // ------------------------------------------------------------------
    // Anomaly flags (monitoring only; every bit is derived on-chain)
    // ------------------------------------------------------------------

    /// @notice The vault is registered but its registry entry is deactivated.
    uint256 public constant FLAG_VAULT_INACTIVE = 1 << 0;
    /// @notice The vault's bound strategy is not in the StrategyRegistry.
    uint256 public constant FLAG_STRATEGY_NOT_REGISTERED = 1 << 1;
    /// @notice The vault's bound strategy is registered but deactivated.
    uint256 public constant FLAG_STRATEGY_INACTIVE = 1 << 2;
    /// @notice The registry's recorded binding for the strategy differs from
    ///         the vault the strategy is actually bound to.
    uint256 public constant FLAG_STRATEGY_VAULT_MISMATCH = 1 << 3;
    /// @notice The registry's recorded asset for the strategy differs from
    ///         the vault's underlying asset.
    uint256 public constant FLAG_STRATEGY_ASSET_MISMATCH = 1 << 4;
    /// @notice A capped vault's total assets exceed its configured cap
    ///         (possible only via out-of-band value, e.g. donations).
    uint256 public constant FLAG_OVER_CAP = 1 << 5;
    /// @notice The guarded vault currently has deposits paused (status bit).
    uint256 public constant FLAG_DEPOSITS_PAUSED = 1 << 6;
    /// @notice The strategy's self-reported holdings are below the vault's
    ///         investment ledger (possible insolvency signal). Informational
    ///         only — self-reports are never used for pricing.
    uint256 public constant FLAG_STRATEGY_BALANCE_DIVERGENCE = 1 << 7;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @notice Deploy the keeper anchored on the protocol's registries.
    /// @param initialAdmin_ Admin account (manages the keeper allowlist;
    ///        implicitly authorized to execute). Ideally a multisig.
    /// @param vaultRegistry_ Canonical VaultRegistry (must be a contract).
    /// @param strategyRegistry_ Canonical StrategyRegistry (must be a contract).
    constructor(address initialAdmin_, address vaultRegistry_, address strategyRegistry_) Ownable(initialAdmin_) {
        if (
            initialAdmin_ == address(0) || vaultRegistry_ == address(0) || strategyRegistry_ == address(0)
                || vaultRegistry_.code.length == 0 || strategyRegistry_.code.length == 0
        ) {
            revert ZeroAddress();
        }
        vaultRegistry = VaultRegistry(vaultRegistry_);
        strategyRegistry = StrategyRegistry(strategyRegistry_);
    }

    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------

    /// @notice Authorize or revoke an automation keeper.
    function setKeeper(address keeper, bool authorized) external onlyOwner {
        if (keeper == address(0)) {
            revert ZeroAddress();
        }
        _keepers[keeper] = authorized;
        emit KeeperUpdated(keeper, authorized);
    }

    /// @notice True when `account` may submit actions (admin or keeper).
    function isKeeper(address account) public view returns (bool) {
        return account == owner() || _keepers[account];
    }

    modifier onlyAutomation() {
        if (!isKeeper(msg.sender)) {
            revert NotKeeper(msg.sender);
        }
        _;
    }

    // ------------------------------------------------------------------
    // Internal guards
    // ------------------------------------------------------------------

    /// @dev Common action preamble: valid nonzero actionId, unused id.
    ///      Marking the id handled happens per-action right before the
    ///      underlying execution — a reverted execution rolls the marking
    ///      back, so failed actions stay retryable under the same id.
    function _begin(bytes32 actionId) internal pure {
        if (actionId == bytes32(0)) {
            revert ZeroActionId();
        }
    }

    function _requireUnused(bytes32 actionId) internal view {
        if (actionHandled[actionId]) {
            revert DuplicateAction(actionId);
        }
    }

    function _requireRegisteredVault(address vault) internal view {
        if (vault == address(0)) {
            revert ZeroAddress();
        }
        if (!vaultRegistry.isRegistered(vault)) {
            revert NotRegistered(vault);
        }
    }

    function _requireRegisteredStrategy(address strategy) internal view {
        if (strategy == address(0)) {
            revert ZeroAddress();
        }
        if (!strategyRegistry.isRegistered(strategy)) {
            revert NotRegistered(strategy);
        }
    }

    /// @dev Capability probe: does `vault` expose the guarded control
    ///      surface? Base vaults (and empty addresses) fail the staticcall
    ///      and return false — fail closed.
    function _probeGuarded(address vault) internal view returns (bool) {
        try IGuardedVaultControl(vault).totalAssetCap() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------
    // Actions: guarded-vault controls (Phase 2G surface)
    // ------------------------------------------------------------------

    /// @notice Pause or unpause deposits on a registered GUARDED vault.
    /// @dev Idempotent: no-op when the vault is already in the requested
    ///      state. Requires the vault's admin rights to be delegated to this
    ///      keeper, otherwise the underlying call reverts (fail closed).
    function setVaultDepositsPaused(address vault, bool paused, bytes32 actionId) external onlyAutomation {
        _begin(actionId);
        _requireUnused(actionId);
        _requireRegisteredVault(vault);
        if (!_probeGuarded(vault)) {
            revert ActionNotSupported(vault);
        }

        bool current = IGuardedVaultControl(vault).depositsPaused();
        if (current == paused) {
            actionHandled[actionId] = true;
            emit ActionNoOp(actionId, uint8(ActionType.SetVaultDepositsPaused), vault, msg.sender);
            return;
        }

        actionHandled[actionId] = true;
        IGuardedVaultControl(vault).setDepositsPaused(paused);
        emit ActionExecuted(actionId, uint8(ActionType.SetVaultDepositsPaused), vault, msg.sender);
    }

    /// @notice Set the total-asset cap on a registered GUARDED vault
    ///         (0 = explicit unbounded). Idempotent at equal values.
    function setVaultTotalAssetCap(address vault, uint256 newCap, bytes32 actionId) external onlyAutomation {
        _begin(actionId);
        _requireUnused(actionId);
        _requireRegisteredVault(vault);
        if (!_probeGuarded(vault)) {
            revert ActionNotSupported(vault);
        }

        uint256 current = IGuardedVaultControl(vault).totalAssetCap();
        if (current == newCap) {
            actionHandled[actionId] = true;
            emit ActionNoOp(actionId, uint8(ActionType.SetVaultCap), vault, msg.sender);
            return;
        }

        actionHandled[actionId] = true;
        IGuardedVaultControl(vault).setTotalAssetCap(newCap);
        emit ActionExecuted(actionId, uint8(ActionType.SetVaultCap), vault, msg.sender);
    }

    /// @notice Run the guarded vault's loss-aware emergency strategy exit.
    /// @dev Not idempotent by state (it is a one-shot realized-loss event);
    ///      duplicates are prevented by the actionId ledger and by the
    ///      vault's own `NothingInvested` guard on repeat calls.
    function vaultEmergencyExitStrategy(address vault, bytes32 actionId) external onlyAutomation {
        _begin(actionId);
        _requireUnused(actionId);
        _requireRegisteredVault(vault);
        if (!_probeGuarded(vault)) {
            revert ActionNotSupported(vault);
        }

        actionHandled[actionId] = true;
        IGuardedVaultControl(vault).emergencyExitStrategy();
        emit ActionExecuted(actionId, uint8(ActionType.VaultEmergencyExit), vault, msg.sender);
    }

    // ------------------------------------------------------------------
    // Actions: core vault flows (all tracks; supported today)
    // ------------------------------------------------------------------

    /// @notice Invest idle vault assets into the vault's bound strategy
    ///         (owner-gated on the vault; the keeper must hold delegated
    ///         rights). Zero amounts revert.
    function vaultInvestIdle(address vault, uint256 assets, bytes32 actionId) external onlyAutomation {
        _begin(actionId);
        _requireUnused(actionId);
        _requireRegisteredVault(vault);
        if (assets == 0) {
            revert ZeroAmount();
        }

        actionHandled[actionId] = true;
        IVaultCore(vault).investIdle(assets);
        emit ActionExecuted(actionId, uint8(ActionType.VaultInvestIdle), vault, msg.sender);
    }

    /// @notice Pull the vault's invested assets back to idle (risk-off).
    /// @dev Idempotent when nothing is invested (the base flow would be a
    ///      silent no-op — the keeper resolves it as an explicit {ActionNoOp}).
    function vaultExitStrategy(address vault, bytes32 actionId) external onlyAutomation {
        _begin(actionId);
        _requireUnused(actionId);
        _requireRegisteredVault(vault);

        if (IVaultCore(vault).strategyInvested() == 0) {
            actionHandled[actionId] = true;
            emit ActionNoOp(actionId, uint8(ActionType.VaultExitStrategy), vault, msg.sender);
            return;
        }

        actionHandled[actionId] = true;
        IVaultCore(vault).exitStrategy();
        emit ActionExecuted(actionId, uint8(ActionType.VaultExitStrategy), vault, msg.sender);
    }

    // ------------------------------------------------------------------
    // Actions: registry incident response
    // ------------------------------------------------------------------

    /// @notice Activate or deactivate a strategy's registry entry.
    /// @dev Idempotent: the registries revert on same-value changes, so the
    ///      keeper pre-checks and resolves no-ops explicitly.
    function setStrategyEntryActive(address strategy, bool active, bytes32 actionId) external onlyAutomation {
        _begin(actionId);
        _requireUnused(actionId);
        _requireRegisteredStrategy(strategy);

        if (strategyRegistry.isActive(strategy) == active) {
            actionHandled[actionId] = true;
            emit ActionNoOp(actionId, uint8(ActionType.SetStrategyActive), strategy, msg.sender);
            return;
        }

        actionHandled[actionId] = true;
        strategyRegistry.setActive(strategy, active);
        emit ActionExecuted(actionId, uint8(ActionType.SetStrategyActive), strategy, msg.sender);
    }

    /// @notice Activate or deactivate a vault's registry entry. Idempotent
    ///         (same pattern as {setStrategyEntryActive}).
    function setVaultEntryActive(address vault, bool active, bytes32 actionId) external onlyAutomation {
        _begin(actionId);
        _requireUnused(actionId);
        _requireRegisteredVault(vault);

        if (vaultRegistry.isActive(vault) == active) {
            actionHandled[actionId] = true;
            emit ActionNoOp(actionId, uint8(ActionType.SetVaultActive), vault, msg.sender);
            return;
        }

        actionHandled[actionId] = true;
        vaultRegistry.setActive(vault, active);
        emit ActionExecuted(actionId, uint8(ActionType.SetVaultActive), vault, msg.sender);
    }

    // ------------------------------------------------------------------
    // Monitoring (pure reads; every value derived on-chain)
    // ------------------------------------------------------------------

    /// @notice Aggregated on-chain snapshot of a registered vault plus an
    ///         anomaly flag bitmask. Unregistered addresses return an empty
    ///         report (`registered == false`, flags 0).
    function vaultReport(address vault)
        external
        view
        returns (
            bool registered,
            bool active,
            address asset,
            uint256 totalAssets,
            address strategy,
            uint256 strategyInvested,
            bool capSupported,
            uint256 totalAssetCap,
            bool depositsPaused,
            uint256 flags
        )
    {
        if (vault == address(0) || !vaultRegistry.isRegistered(vault)) {
            return (false, false, address(0), 0, address(0), 0, false, 0, false, 0);
        }

        registered = true;
        active = vaultRegistry.isActive(vault);
        asset = IVaultCore(vault).asset();
        totalAssets = IVaultCore(vault).totalAssets();
        strategy = IVaultCore(vault).strategy();
        strategyInvested = IVaultCore(vault).strategyInvested();

        try IGuardedVaultControl(vault).totalAssetCap() returns (uint256 cap) {
            capSupported = true;
            totalAssetCap = cap;
        } catch {}
        try IGuardedVaultControl(vault).depositsPaused() returns (bool paused) {
            depositsPaused = paused;
        } catch {}

        if (!active) {
            flags |= FLAG_VAULT_INACTIVE;
        }
        if (capSupported && totalAssetCap != 0 && totalAssets > totalAssetCap) {
            flags |= FLAG_OVER_CAP;
        }
        if (depositsPaused) {
            flags |= FLAG_DEPOSITS_PAUSED;
        }

        if (strategy != address(0)) {
            if (!strategyRegistry.isRegistered(strategy)) {
                flags |= FLAG_STRATEGY_NOT_REGISTERED;
            } else {
                StrategyRegistry.Entry memory entry = strategyRegistry.getStrategy(strategy);
                if (!entry.active) {
                    flags |= FLAG_STRATEGY_INACTIVE;
                }
                if (entry.vault != vault) {
                    flags |= FLAG_STRATEGY_VAULT_MISMATCH;
                }
                if (entry.asset != asset) {
                    flags |= FLAG_STRATEGY_ASSET_MISMATCH;
                }
            }
            if (strategyInvested > 0) {
                // Informational divergence hint only (never pricing).
                try IStrategy(strategy).totalAssets() returns (uint256 reported) {
                    if (reported < strategyInvested) {
                        flags |= FLAG_STRATEGY_BALANCE_DIVERGENCE;
                    }
                } catch {}
            }
        }
    }

    /// @notice Aggregated on-chain snapshot of a registered strategy plus
    ///         anomaly flags. Unregistered addresses return an empty report.
    function strategyReport(address strategy)
        external
        view
        returns (
            bool registered,
            bool active,
            address vault,
            address asset,
            uint256 cap,
            uint256 selfReportedTotalAssets,
            uint256 vaultLedgerInvested,
            uint256 flags
        )
    {
        if (strategy == address(0) || !strategyRegistry.isRegistered(strategy)) {
            return (false, false, address(0), address(0), 0, 0, 0, 0);
        }

        StrategyRegistry.Entry memory entry = strategyRegistry.getStrategy(strategy);
        registered = true;
        active = entry.active;
        vault = entry.vault;
        asset = entry.asset;
        cap = IStrategy(strategy).cap();
        try IStrategy(strategy).totalAssets() returns (uint256 reported) {
            selfReportedTotalAssets = reported;
        } catch {}
        if (vault != address(0)) {
            vaultLedgerInvested = IVaultCore(vault).strategyInvested();
        }

        if (!active) {
            flags |= FLAG_STRATEGY_INACTIVE;
        }
        if (vaultLedgerInvested > 0 && selfReportedTotalAssets < vaultLedgerInvested) {
            flags |= FLAG_STRATEGY_BALANCE_DIVERGENCE;
        }
    }
}
