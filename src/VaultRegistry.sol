// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {StrategyRegistry} from "./StrategyRegistry.sol";

/// @title VaultRegistry
/// @notice Owner-controlled bookkeeping registry for AscendMM vaults: for
///         each registered vault it records the underlying asset, an
///         active/paused flag, a vault-type identifier, the associated
///         strategy, a protocol risk classification, and a metadata/version
///         identifier. It is the directory layer for a multi-vault,
///         multi-strategy platform — it deliberately does NOT move funds,
///         does NOT hold funds, and is NOT consulted by the deployed vaults'
///         accounting (their binding/ledger model is unchanged).
/// @dev Registration validates, in the same spirit as {StrategyRegistry}:
///        1. the vault is a deployed contract whose `asset()` is callable
///           (token address on the ERC-20 track, the ERC-7528 native sentinel
///           `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` on the native-HYPE
///           track) — a vault without `asset()` makes registration revert on
///           that external call;
///        2. the associated strategy (if supplied) reports the vault as ITS
///           binding (`strategy.vault() == vault`) and reports the SAME asset
///           as the vault (`strategy.asset() == vault.asset()`);
///        3. if a companion {StrategyRegistry} is wired at construction and
///           the strategy is registered there, the strategy-registry's
///           recorded vault binding must agree — the two registries stay
///           internally consistent (strategy addresses and vault
///           relationships remain authoritative in their own registries;
///           nothing is duplicated beyond this cross-check).
///      Risk classifications are explicit protocol buckets (LOW / MEDIUM /
///      HIGH / EXPERIMENTAL). They are NOT audited, third-party, or
///      quantitative risk ratings. No external protocol integrations exist
///      in this contract; all admin functions are owner-only (OpenZeppelin
///      `Ownable`, matching the vaults' access model).
contract VaultRegistry is Ownable {
    // ------------------------------------------------------------------
    // Risk classification buckets (protocol classifications, NOT audited
    // or quantitative risk ratings)
    // ------------------------------------------------------------------

    /// @notice Custodial/idle setups with no external dependencies.
    bytes32 public constant RISK_LOW = keccak256("RISK_LOW");

    /// @notice One reviewed external dependency with bounded downside.
    bytes32 public constant RISK_MEDIUM = keccak256("RISK_MEDIUM");

    /// @notice Unbounded downside or multiple external dependencies.
    bytes32 public constant RISK_HIGH = keccak256("RISK_HIGH");

    /// @notice Not yet reviewed for production use.
    bytes32 public constant RISK_EXPERIMENTAL = keccak256("RISK_EXPERIMENTAL");

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice Registry entry for one vault.
    /// @param vault The registered vault contract.
    /// @param asset Underlying asset, as reported by the vault's `asset()`:
    ///        an ERC-20 token address, or the ERC-7528 native-asset sentinel
    ///        for native-HYPE vaults.
    /// @param active Active/paused flag. Registration sets it active; only
    ///        the owner flips it. Pausing here is informational today — the
    ///        deployed vaults do not consult the registry.
    /// @param vaultType Free-form type identifier (bytes32; e.g.
    ///        `keccak256("ASCEND_VAULT_HYPE_V1")`). Zero is rejected so
    ///        every entry is categorizable.
    /// @param strategy Associated strategy address (zero = none). Validated
    ///        against the vault at registration and on every update.
    /// @param riskClass Protocol risk classification (bytes32 bucket; one of
    ///        the RISK_* constants).
    /// @param metadata Metadata/version identifier (bytes32; e.g.
    ///        `bytes32("V1")`). May be zero (unversioned).
    struct VaultEntry {
        address vault;
        address asset;
        bool active;
        bytes32 vaultType;
        address strategy;
        bytes32 riskClass;
        bytes32 metadata;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice Companion strategy registry used for cross-registry
    ///         consistency checks (zero address disables the cross-check).
    address public immutable strategyRegistry;

    /// @notice Entries keyed by vault address.
    mapping(address vault => VaultEntry entry) private _entries;

    /// @notice All registered vault addresses (for enumeration).
    address[] private _vaultList;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice Zero address passed where a real address is required.
    error VaultRegistryZeroAddress();

    /// @notice Address passed where a deployed contract is required.
    error VaultRegistryNotContract(address account);

    /// @notice The vault is already registered.
    error VaultRegistryAlreadyRegistered(address vault);

    /// @notice The vault is not registered.
    error VaultRegistryNotRegistered(address vault);

    /// @notice Activation attempted on an already-active vault.
    error VaultRegistryAlreadyActive(address vault);

    /// @notice Deactivation attempted on an already-paused vault.
    error VaultRegistryAlreadyPaused(address vault);

    /// @notice A zero vault-type identifier was given.
    error VaultRegistryVaultTypeEmpty(address vault);

    /// @notice The associated strategy reports a different vault binding.
    error VaultRegistryStrategyVaultMismatch(address strategy, address expectedVault, address actualVault);

    /// @notice The associated strategy reports a different asset than the
    ///         vault.
    error VaultRegistryStrategyAssetMismatch(address strategy, address expectedAsset, address actualAsset);

    /// @notice The strategy is registered in the companion strategy registry
    ///         against a DIFFERENT vault; the registries would disagree.
    error VaultRegistryStrategyRegistryMismatch(address strategy, address expectedVault, address actualVault);

    /// @notice An invalid risk-classification bucket was given (must be one
    ///         of the RISK_* constants — LOW/MEDIUM/HIGH/EXPERIMENTAL).
    error VaultRegistryInvalidRiskClass(bytes32 riskClass);

    /// @notice The new risk classification equals the current one (no-op
    ///         rejected so risk changes are always observable).
    error VaultRegistrySameRisk(address vault, bytes32 riskClass);

    /// @notice The new strategy equals the current one (no-op rejected so
    ///         strategy changes are always observable).
    error VaultRegistrySameStrategy(address vault, address strategy);

    /// @notice The new metadata identifier equals the current one (no-op
    ///         rejected so metadata changes are always observable).
    error VaultRegistrySameMetadata(address vault, bytes32 metadata);

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice A vault was registered (active by default).
    event VaultRegistered(
        address indexed vault,
        address indexed asset,
        bytes32 vaultType,
        address strategy,
        bytes32 riskClass,
        bytes32 metadata
    );

    /// @notice A registered vault's associated strategy changed.
    event VaultStrategyUpdated(address indexed vault, address oldStrategy, address newStrategy);

    /// @notice A registered vault was activated.
    event VaultActivated(address indexed vault);

    /// @notice A registered vault was deactivated (paused).
    event VaultDeactivated(address indexed vault);

    /// @notice A registered vault's risk classification changed.
    event VaultRiskUpdated(address indexed vault, bytes32 oldRiskClass, bytes32 newRiskClass);

    /// @notice A registered vault's metadata/version identifier changed.
    event VaultMetadataUpdated(address indexed vault, bytes32 oldMetadata, bytes32 newMetadata);

    /// @notice A registered vault was removed entirely.
    event VaultRemoved(address indexed vault, address asset, address strategy);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @notice Deploy the registry with `initialOwner` as its administrator
    ///         (supports an immutable multisig, like the vaults).
    /// @param initialOwner Administrator of this registry.
    /// @param strategyRegistry_ Companion {StrategyRegistry} used for
    ///        cross-registry consistency checks; pass the zero address to
    ///        deploy standalone (the cross-check is then skipped).
    constructor(address initialOwner, address strategyRegistry_) Ownable(initialOwner) {
        strategyRegistry = strategyRegistry_;
    }

    // ------------------------------------------------------------------
    // Registration (owner-only)
    // ------------------------------------------------------------------

    /// @notice Register a vault with no associated strategy.
    /// @dev See {registerVaultWithStrategy} for the validation contract.
    /// @param vault Vault contract to register.
    /// @param vaultType Nonzero type identifier for the entry.
    /// @param riskClass One of the RISK_* constants.
    /// @param metadata Metadata/version identifier (may be zero).
    function registerVault(address vault, bytes32 vaultType, bytes32 riskClass, bytes32 metadata) external onlyOwner {
        _register(vault, vaultType, riskClass, metadata, address(0));
    }

    /// @notice Register a vault with an associated strategy.
    /// @dev Validation: the vault must be a deployed contract with a callable
    ///      `asset()`; the strategy (if nonzero) must be a deployed contract
    ///      reporting `vault` as its binding and the vault's asset as its
    ///      own; duplicates are rejected. If the strategy is registered in
    ///      the companion {StrategyRegistry}, that entry must point at the
    ///      same vault.
    function registerVaultWithStrategy(
        address vault,
        bytes32 vaultType,
        bytes32 riskClass,
        bytes32 metadata,
        address strategy
    ) external onlyOwner {
        _register(vault, vaultType, riskClass, metadata, strategy);
    }

    /// @dev Shared registration path.
    function _register(address vault, bytes32 vaultType, bytes32 riskClass, bytes32 metadata, address strategy)
        private
    {
        if (vault == address(0)) {
            revert VaultRegistryZeroAddress();
        }
        if (vault.code.length == 0) {
            revert VaultRegistryNotContract(vault);
        }
        if (vaultType == bytes32(0)) {
            revert VaultRegistryVaultTypeEmpty(vault);
        }
        if (_entries[vault].vault != address(0)) {
            revert VaultRegistryAlreadyRegistered(vault);
        }
        _validateRiskClass(riskClass);

        // The vault's own asset() getter is the source of truth (token
        // address on the ERC-20 track, ERC-7528 sentinel on the native
        // track). A vault without asset() reverts here, which is the
        // documented outcome.
        address vaultAsset = IStrategy(vault).asset();

        if (strategy != address(0)) {
            _validateStrategyBinding(vault, vaultAsset, strategy);
        }

        _entries[vault] = VaultEntry({
            vault: vault,
            asset: vaultAsset,
            active: true,
            vaultType: vaultType,
            strategy: strategy,
            riskClass: riskClass,
            metadata: metadata
        });
        _vaultList.push(vault);

        emit VaultRegistered(vault, vaultAsset, vaultType, strategy, riskClass, metadata);
    }

    // ------------------------------------------------------------------
    // Lifecycle administration (owner-only)
    // ------------------------------------------------------------------

    /// @notice Update a registered vault's associated strategy.
    /// @dev Pass the zero address to clear the association. The new strategy
    ///      (if nonzero) must be a deployed contract reporting `vault` as
    ///      its binding, the vault's asset as its own, and — when registered
    ///      in the companion {StrategyRegistry} — the same vault there.
    ///      Re-setting the current strategy is rejected as a no-op so every
    ///      mutation is observable.
    function updateStrategy(address vault, address newStrategy) external onlyOwner {
        VaultEntry storage entry = _entries[vault];
        if (entry.vault == address(0)) {
            revert VaultRegistryNotRegistered(vault);
        }
        if (newStrategy == entry.strategy) {
            revert VaultRegistrySameStrategy(vault, newStrategy);
        }
        if (newStrategy != address(0)) {
            _validateStrategyBinding(vault, entry.asset, newStrategy);
        }

        address old = entry.strategy;
        entry.strategy = newStrategy;

        emit VaultStrategyUpdated(vault, old, newStrategy);
    }

    /// @notice Activate or pause a registered vault.
    /// @dev Informational today (the deployed vaults do not consult the
    ///      registry); it gives operators a single off-chain/integration-
    ///      facing kill switch per vault.
    function setActive(address vault, bool active) external onlyOwner {
        VaultEntry storage entry = _entries[vault];
        if (entry.vault == address(0)) {
            revert VaultRegistryNotRegistered(vault);
        }
        if (active) {
            if (entry.active) {
                revert VaultRegistryAlreadyActive(vault);
            }
            entry.active = true;
            emit VaultActivated(vault);
        } else {
            if (!entry.active) {
                revert VaultRegistryAlreadyPaused(vault);
            }
            entry.active = false;
            emit VaultDeactivated(vault);
        }
    }

    /// @notice Update a registered vault's protocol risk classification.
    /// @dev `riskClass` MUST be one of the RISK_* constants. These are
    ///      protocol classifications, not audited or quantitative risk
    ///      ratings.
    function setRiskClass(address vault, bytes32 riskClass) external onlyOwner {
        VaultEntry storage entry = _entries[vault];
        if (entry.vault == address(0)) {
            revert VaultRegistryNotRegistered(vault);
        }
        _validateRiskClass(riskClass);
        if (riskClass == entry.riskClass) {
            revert VaultRegistrySameRisk(vault, riskClass);
        }

        bytes32 old = entry.riskClass;
        entry.riskClass = riskClass;

        emit VaultRiskUpdated(vault, old, riskClass);
    }

    /// @notice Update a registered vault's metadata/version identifier.
    function setMetadata(address vault, bytes32 newMetadata) external onlyOwner {
        VaultEntry storage entry = _entries[vault];
        if (entry.vault == address(0)) {
            revert VaultRegistryNotRegistered(vault);
        }
        if (newMetadata == entry.metadata) {
            revert VaultRegistrySameMetadata(vault, newMetadata);
        }

        bytes32 old = entry.metadata;
        entry.metadata = newMetadata;

        emit VaultMetadataUpdated(vault, old, newMetadata);
    }

    /// @notice Remove a vault from the registry entirely. Re-registering the
    ///         same address afterwards starts a fresh entry.
    function removeVault(address vault) external onlyOwner {
        VaultEntry memory entry = _entries[vault];
        if (entry.vault == address(0)) {
            revert VaultRegistryNotRegistered(vault);
        }

        delete _entries[vault];

        uint256 len = _vaultList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_vaultList[i] == vault) {
                _vaultList[i] = _vaultList[len - 1];
                _vaultList.pop();
                break;
            }
        }

        emit VaultRemoved(vault, entry.asset, entry.strategy);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Full registry entry for `vault` (zeroed fields when
    ///         unregistered — check {isRegistered}).
    function getVault(address vault) external view returns (VaultEntry memory) {
        return _entries[vault];
    }

    /// @notice Whether `vault` is registered.
    function isRegistered(address vault) external view returns (bool) {
        return _entries[vault].vault != address(0);
    }

    /// @notice Whether `vault` is registered AND active.
    function isActive(address vault) external view returns (bool) {
        return _entries[vault].active;
    }

    /// @notice Number of registered vaults.
    function vaultCount() external view returns (uint256) {
        return _vaultList.length;
    }

    /// @notice All registered vault addresses.
    function allVaults() external view returns (address[] memory) {
        return _vaultList;
    }

    // ------------------------------------------------------------------
    // Internal validation
    // ------------------------------------------------------------------

    /// @dev Rejects anything outside the four explicit protocol buckets.
    function _validateRiskClass(bytes32 riskClass) private pure {
        if (
            riskClass != RISK_LOW && riskClass != RISK_MEDIUM && riskClass != RISK_HIGH
                && riskClass != RISK_EXPERIMENTAL
        ) {
            revert VaultRegistryInvalidRiskClass(riskClass);
        }
    }

    /// @dev Validates that `strategy` genuinely belongs to `vault`:
    ///      deployed contract, self-reported vault binding, matching asset,
    ///      and — when the companion strategy registry is wired and the
    ///      strategy is registered there — an agreeing recorded binding.
    function _validateStrategyBinding(address vault, address vaultAsset, address strategy) private view {
        if (strategy.code.length == 0) {
            revert VaultRegistryNotContract(strategy);
        }
        if (IStrategy(strategy).vault() != vault) {
            revert VaultRegistryStrategyVaultMismatch(strategy, vault, IStrategy(strategy).vault());
        }
        if (IStrategy(strategy).asset() != vaultAsset) {
            revert VaultRegistryStrategyAssetMismatch(strategy, vaultAsset, IStrategy(strategy).asset());
        }
        if (strategyRegistry != address(0)) {
            StrategyRegistry registry = StrategyRegistry(strategyRegistry);
            if (registry.isRegistered(strategy)) {
                address recordedVault = registry.getStrategy(strategy).vault;
                if (recordedVault != vault) {
                    revert VaultRegistryStrategyRegistryMismatch(strategy, vault, recordedVault);
                }
            }
        }
    }
}
