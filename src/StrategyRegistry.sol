// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title StrategyRegistry
/// @notice Owner-controlled allowlist of AscendMM strategies: records, for
///         each approved strategy address, the vault it is bound to, its
///         underlying asset, an active/paused flag, and a strategy-type
///         identifier (e.g. `keccak256("ASCEND_IDLE_V1")`). It is the
///         directory layer for supporting multiple real yield strategies
///         later — it deliberately does NOT move funds and is NOT consulted
///         by the deployed vaults' accounting (their binding/ledger model is
///         unchanged).
/// @dev Registration validates the SAME self-reported bindings the vaults
///      enforce in their own `setStrategy`, extended with a vault-side asset
///      cross-check so a registry entry can never describe an invalid
///      strategy/vault/asset combination:
///        1. the strategy must report the given vault via `vault()`, and
///        2. the strategy's `asset()` must equal the VAULT's `asset()`.
///      Because both vault tracks expose `asset()` — ERC-20 vaults return the
///      token address, native-HYPE vaults return the ERC-7528 sentinel
///      0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE — one unified path
///      registers strategies for either track. A vault that does not expose
///      `asset()` (or returns malformed data) simply makes registration
///      revert on that external call. The registry is standalone (no
///      dependency on the vault contracts, only on {IStrategy}) and never
///      holds funds. All admin functions are owner-only (OpenZeppelin
///      `Ownable`, matching the vaults' access model).
contract StrategyRegistry is Ownable {
    // ------------------------------------------------------------------
    // Risk classification buckets (protocol classifications, NOT audited
    // or quantitative risk ratings)
    // ------------------------------------------------------------------

    /// @notice Custodial/idle strategies with no external dependencies.
    bytes32 public constant RISK_LOW = keccak256("RISK_LOW");

    /// @notice Strategies with one reviewed external dependency and bounded
    ///         downside.
    bytes32 public constant RISK_MEDIUM = keccak256("RISK_MEDIUM");

    /// @notice Strategies with unbounded downside or multiple external
    ///         dependencies.
    bytes32 public constant RISK_HIGH = keccak256("RISK_HIGH");

    /// @notice Strategies not yet reviewed for production use.
    bytes32 public constant RISK_EXPERIMENTAL = keccak256("RISK_EXPERIMENTAL");

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice Registry entry for one approved strategy.
    /// @param strategy The registered strategy contract.
    /// @param vault The vault the strategy is bound to (as reported by the
    ///        strategy itself and pinned at registration).
    /// @param asset Underlying asset, as reported by the strategy and
    ///        verified equal to the vault's asset: an ERC-20 token address,
    ///        or the ERC-7528 native-asset sentinel for native-HYPE
    ///        strategies.
    /// @param active Active/paused flag. Registration sets it active; only
    ///        the owner flips it. Pausing here is informational today — the
    ///        deployed vaults do not consult the registry.
    /// @param strategyType Free-form type identifier (bytes32; e.g.
    ///        `keccak256("ASCEND_IDLE_V1")`). Zero is rejected at
    ///        registration so every entry is categorizable.
    /// @param riskClass Protocol risk classification (bytes32 bucket; see
    ///        {VaultRegistry.RISK_LOW}). Default for registrations is LOW.
    ///        These are protocol-only classifications, NOT audited or
    ///        third-party risk ratings.
    /// @param version Metadata/version identifier for the entry (bytes32,
    ///        e.g. `bytes32("V1")`). Default for registrations is "V1".
    /// @param label Human-readable name for indexers/UIs (informational).
    struct Entry {
        address strategy;
        address vault;
        address asset;
        bool active;
        bytes32 strategyType;
        bytes32 riskClass;
        bytes32 version;
        string label;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice Entries keyed by strategy address.
    mapping(address strategy => Entry entry) private _entries;

    /// @notice All registered strategy addresses (for enumeration).
    address[] private _strategyList;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice Zero address passed where a real address is required.
    error StrategyRegistryZeroAddress();

    /// @notice Address passed where a deployed contract is required.
    error StrategyRegistryNotContract(address account);

    /// @notice The strategy is already registered.
    error StrategyRegistryAlreadyRegistered(address strategy);

    /// @notice The strategy is not registered.
    error StrategyRegistryNotRegistered(address strategy);

    /// @notice Activation attempted on an already-active strategy.
    error StrategyRegistryAlreadyActive(address strategy);

    /// @notice Deactivation attempted on an already-paused strategy.
    error StrategyRegistryAlreadyPaused(address strategy);

    /// @notice The strategy reports a different vault binding than given.
    error StrategyRegistryVaultMismatch(address expected, address actual);

    /// @notice The strategy's reported asset differs from the vault's asset.
    error StrategyRegistryAssetMismatch(address expected, address actual);

    /// @notice A zero strategy-type identifier was given.
    error StrategyRegistryStrategyTypeEmpty(address strategy);

    /// @notice The new strategy type equals the current one (no-op rejected
    ///         so type changes are always observable).
    error StrategyRegistrySameType(address strategy, bytes32 strategyType);

    /// @notice The new strategy version equals the current one (no-op
    ///         rejected so version changes are always observable).
    error StrategyRegistrySameVersion(address strategy, bytes32 version);

    /// @notice An invalid risk-classification bucket was given (must be one
    ///         of the registry's RISK_* constants — LOW/MEDIUM/HIGH/
    ///         EXPERIMENTAL).
    error StrategyRegistryInvalidRiskClass(bytes32 riskClass);

    /// @notice The new strategy risk classification equals the current one
    ///         (no-op rejected so risk changes are always observable).
    error StrategyRegistrySameRisk(address strategy, bytes32 riskClass);

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice A strategy was registered (active by default).
    event StrategyRegistered(
        address indexed strategy, address indexed vault, address indexed asset, bytes32 strategyType, string label
    );

    /// @notice A registered strategy was activated.
    event StrategyActivated(address indexed strategy);

    /// @notice A registered strategy was deactivated (paused).
    event StrategyDeactivated(address indexed strategy);

    /// @notice A registered strategy was removed entirely.
    event StrategyRemoved(address indexed strategy, address vault, address asset);

    /// @notice A registered strategy's type identifier changed.
    event StrategyTypeUpdated(address indexed strategy, bytes32 oldType, bytes32 newType);

    /// @notice A registered strategy's risk classification changed.
    event StrategyRiskUpdated(address indexed strategy, bytes32 oldRiskClass, bytes32 newRiskClass);

    /// @notice A registered strategy's version identifier changed.
    event StrategyVersionUpdated(address indexed strategy, bytes32 oldVersion, bytes32 newVersion);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @notice Deploy the registry with `initialOwner` as its administrator
    ///         (supports an immutable multisig, like the vaults).
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ------------------------------------------------------------------
    // Registration (owner-only)
    // ------------------------------------------------------------------

    /// @notice Register a strategy bound to `vault` (it becomes active
    ///         immediately). Works for BOTH vault tracks: ERC-20 vaults
    ///         (`asset()` = token) and native-HYPE vaults (`asset()` = the
    ///         ERC-7528 sentinel).
    /// @dev Validation: both addresses must be deployed contracts, the
    ///      strategy must report `vault` via `vault()`, and the strategy's
    ///      `asset()` must equal the vault's `asset()`.
    /// @param strategy Strategy contract to approve.
    /// @param vault Vault the strategy is bound to.
    /// @param strategyType Nonzero type identifier for the entry.
    function registerStrategy(address strategy, address vault, bytes32 strategyType) external onlyOwner {
        _register(strategy, vault, strategyType, "");
    }

    /// @notice Register a strategy with a human-readable label.
    function registerStrategy(address strategy, address vault, bytes32 strategyType, string calldata label)
        external
        onlyOwner
    {
        _register(strategy, vault, strategyType, label);
    }

    /// @dev Shared registration path.
    function _register(address strategy, address vault, bytes32 strategyType, string memory label) private {
        if (strategy == address(0) || vault == address(0)) {
            revert StrategyRegistryZeroAddress();
        }
        if (strategy.code.length == 0) {
            revert StrategyRegistryNotContract(strategy);
        }
        if (vault.code.length == 0) {
            revert StrategyRegistryNotContract(vault);
        }
        if (IStrategy(strategy).vault() != vault) {
            revert StrategyRegistryVaultMismatch(vault, IStrategy(strategy).vault());
        }
        // Vault-side asset cross-check: the vault's own asset() getter is
        // the source of truth (token address on the ERC-20 track, ERC-7528
        // sentinel on the native track). A vault without asset() reverts
        // here, which is the documented outcome.
        address vaultAsset = IStrategy(vault).asset();
        address strategyAsset = IStrategy(strategy).asset();
        if (strategyAsset != vaultAsset) {
            revert StrategyRegistryAssetMismatch(vaultAsset, strategyAsset);
        }
        if (strategyType == bytes32(0)) {
            revert StrategyRegistryStrategyTypeEmpty(strategy);
        }
        if (_entries[strategy].strategy != address(0)) {
            revert StrategyRegistryAlreadyRegistered(strategy);
        }

        _entries[strategy] = Entry({
            strategy: strategy,
            vault: vault,
            asset: strategyAsset,
            active: true,
            strategyType: strategyType,
            riskClass: RISK_LOW,
            version: "V1",
            label: label
        });
        _strategyList.push(strategy);

        emit StrategyRegistered(strategy, vault, strategyAsset, strategyType, label);
    }

    /// @notice Update a registered strategy's protocol risk classification.
    /// @dev `riskClass` MUST be one of the registry's RISK_* constants
    ///      (RISK_LOW / RISK_MEDIUM / RISK_HIGH / RISK_EXPERIMENTAL).
    ///      These are protocol classifications, not audited, third-party or
    ///      quantitative risk ratings.
    function setRiskClass(address strategy, bytes32 riskClass) external onlyOwner {
        Entry storage entry = _entries[strategy];
        if (entry.strategy == address(0)) {
            revert StrategyRegistryNotRegistered(strategy);
        }
        if (
            riskClass != RISK_LOW && riskClass != RISK_MEDIUM && riskClass != RISK_HIGH
                && riskClass != RISK_EXPERIMENTAL
        ) {
            revert StrategyRegistryInvalidRiskClass(riskClass);
        }
        if (riskClass == entry.riskClass) {
            revert StrategyRegistrySameRisk(strategy, riskClass);
        }

        bytes32 old = entry.riskClass;
        entry.riskClass = riskClass;

        emit StrategyRiskUpdated(strategy, old, riskClass);
    }

    /// @notice Update a registered strategy's version identifier.
    function setVersion(address strategy, bytes32 newVersion) external onlyOwner {
        Entry storage entry = _entries[strategy];
        if (entry.strategy == address(0)) {
            revert StrategyRegistryNotRegistered(strategy);
        }
        if (newVersion == bytes32(0)) {
            revert StrategyRegistryStrategyTypeEmpty(strategy);
        }
        if (newVersion == entry.version) {
            revert StrategyRegistrySameVersion(strategy, newVersion);
        }

        bytes32 old = entry.version;
        entry.version = newVersion;

        emit StrategyVersionUpdated(strategy, old, newVersion);
    }

    // ------------------------------------------------------------------
    // Lifecycle administration (owner-only)
    // ------------------------------------------------------------------

    /// @notice Activate or pause a registered strategy.
    /// @dev Informational today (the deployed vaults do not consult the
    ///      registry); it gives operators a single off-chain/integration-
    ///      facing kill switch per strategy.
    function setActive(address strategy, bool active) external onlyOwner {
        Entry storage entry = _entries[strategy];
        if (entry.strategy == address(0)) {
            revert StrategyRegistryNotRegistered(strategy);
        }
        if (active) {
            if (entry.active) {
                revert StrategyRegistryAlreadyActive(strategy);
            }
            entry.active = true;
            emit StrategyActivated(strategy);
        } else {
            if (!entry.active) {
                revert StrategyRegistryAlreadyPaused(strategy);
            }
            entry.active = false;
            emit StrategyDeactivated(strategy);
        }
    }

    /// @notice Update a registered strategy's type identifier.
    function setType(address strategy, bytes32 newType) external onlyOwner {
        Entry storage entry = _entries[strategy];
        if (entry.strategy == address(0)) {
            revert StrategyRegistryNotRegistered(strategy);
        }
        if (newType == bytes32(0)) {
            revert StrategyRegistryStrategyTypeEmpty(strategy);
        }
        if (newType == entry.strategyType) {
            revert StrategyRegistrySameType(strategy, newType);
        }

        bytes32 oldType = entry.strategyType;
        entry.strategyType = newType;

        emit StrategyTypeUpdated(strategy, oldType, newType);
    }

    /// @notice Remove a strategy from the registry entirely. Re-registering
    ///         the same address afterwards starts a fresh entry.
    function removeStrategy(address strategy) external onlyOwner {
        Entry memory entry = _entries[strategy];
        if (entry.strategy == address(0)) {
            revert StrategyRegistryNotRegistered(strategy);
        }

        delete _entries[strategy];

        uint256 len = _strategyList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_strategyList[i] == strategy) {
                _strategyList[i] = _strategyList[len - 1];
                _strategyList.pop();
                break;
            }
        }

        emit StrategyRemoved(strategy, entry.vault, entry.asset);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Full registry entry for `strategy` (zeroed fields when
    ///         unregistered — check {isRegistered}).
    function getStrategy(address strategy) external view returns (Entry memory) {
        return _entries[strategy];
    }

    /// @notice Whether `strategy` is registered.
    function isRegistered(address strategy) external view returns (bool) {
        return _entries[strategy].strategy != address(0);
    }

    /// @notice Whether `strategy` is registered AND active.
    function isActive(address strategy) external view returns (bool) {
        return _entries[strategy].active;
    }

    /// @notice Number of registered strategies.
    function strategyCount() external view returns (uint256) {
        return _strategyList.length;
    }

    /// @notice All registered strategy addresses.
    function allStrategies() external view returns (address[] memory) {
        return _strategyList;
    }
}
