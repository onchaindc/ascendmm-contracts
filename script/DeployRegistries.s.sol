// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";

/// @title DeployRegistries
/// @notice Deploys the AscendMM registry layer for Kinetiq Elysium and
///         registers the EXISTING live vaults/strategies (Phase 2D):
///           * ERC-20 track:  AscendVault + IdleStrategy (asMMT)
///           * Native track:  AscendVaultHype + HypeIdleStrategy (native HYPE)
///         The vaults/strategies themselves are NEVER deployed or modified
///         here — they must already be live at the configured addresses and
///         stay untouched. The registries are bookkeeping-only directories:
///         they hold no funds and the vaults never consult them.
/// @dev Reads ALL configuration from environment variables (see env.example):
///        * DEPLOYER_PRIVATE_KEY  (required) deployer key; becomes registry
///                                owner unless REGISTRY_OWNER is set
///        * REGISTRY_OWNER        (optional) owner override (e.g. multisig)
///        * ELY_CHAIN_ID          (optional, 99801) chain-id fail-fast
///        * STRATEGY_REGISTRY     (optional) pre-existing StrategyRegistry to
///                                register against (profile re-runs; only
///                                works when it is still owned by the
///                                broadcaster). Fresh deploy when unset.
///      Live infrastructure addresses (defaults; overridable, e.g. for other
///      profiles) — the companion ERC-20 asset is resolved from the vault's
///      own `asset()`:
///        * HYPE_VAULT            default 0x8C68b40C…B2e7
///        * HYPE_STRATEGY         default 0x5bC48661…Ed97
///        * ERC20_VAULT           default 0xa49Ef74F…4480
///        * ERC20_STRATEGY        default 0xE6662124…329a
///      Registration metadata (deterministic, matching test/VaultRegistry
///      test constants; labels exist only on strategies — vaults carry the
///      `metadata` bytes32 "V1"):
///        * strategyType  keccak256("ASCEND_IDLE_V1")
///        * vaultTypes    keccak256("ASCEND_VAULT_HYPE_V1") /
///                        keccak256("ASCEND_VAULT_ERC20_V1")
///        * metadata      bytes32("V1")
///        * riskClass     keccak256("RISK_LOW") for all four entries —
///                        protocol bucket only, NOT an audited rating
///        * labels        "AscendMM HypeIdleStrategy V1" /
///                        "AscendMM IdleStrategy (asMMT) V1"
///      The Kinetiq kHYPE adapter (KinetiqLstStrategy) is deliberately NOT
///      registered here: no kHYPE/StakingManager/StakingAccountant deployment
///      exists on chain 99801 and inventing addresses is forbidden.
contract DeployRegistries is Script {
    // ---------------------------------------------------------------------
    // Live infrastructure defaults (Elysium testnet, chain 99801)
    // ---------------------------------------------------------------------
    address constant HYPE_VAULT_DEFAULT = 0x8C68b40C6c553b41824F6F8d5E995FCBf809B2e7;
    address constant HYPE_STRATEGY_DEFAULT = 0x5bC48661a4CD27FF226295e3D226c11E7C06Ed97;
    address constant ERC20_VAULT_DEFAULT = 0xa49Ef74F7de5022340bE2f7DeD7bD2c54b344480;
    address constant ERC20_STRATEGY_DEFAULT = 0xE6662124835F0927245697459fd90e77ac58329a;

    // ---------------------------------------------------------------------
    // Deterministic registration metadata (matches test constants)
    // ---------------------------------------------------------------------
    bytes32 constant STRATEGY_TYPE_IDLE = keccak256("ASCEND_IDLE_V1");
    bytes32 constant VAULT_TYPE_HYPE = keccak256("ASCEND_VAULT_HYPE_V1");
    bytes32 constant VAULT_TYPE_ERC20 = keccak256("ASCEND_VAULT_ERC20_V1");
    bytes32 constant METADATA_V1 = bytes32("V1");
    bytes32 constant RISK_LOW = keccak256("RISK_LOW");

    string constant LABEL_HYPE = "AscendMM HypeIdleStrategy V1";
    string constant LABEL_ERC20 = "AscendMM IdleStrategy (asMMT) V1";

    function run() external {
        // --- REQUIRED: deployer identity ---------------------------------
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- OPTIONAL: owner override + re-run passthrough ---------------
        address owner = vm.envOr("REGISTRY_OWNER", deployer);
        address strategyRegistryAddr = vm.envOr("STRATEGY_REGISTRY", address(0));

        // --- Live infrastructure (defaults with env override) ------------
        address hypeVault = vm.envOr("HYPE_VAULT", HYPE_VAULT_DEFAULT);
        address hypeStrategy = vm.envOr("HYPE_STRATEGY", HYPE_STRATEGY_DEFAULT);
        address erc20Vault = vm.envOr("ERC20_VAULT", ERC20_VAULT_DEFAULT);
        address erc20Strategy = vm.envOr("ERC20_STRATEGY", ERC20_STRATEGY_DEFAULT);
        require(hypeVault != address(0) && hypeStrategy != address(0), "HYPE track address unset");
        require(erc20Vault != address(0) && erc20Strategy != address(0), "ERC20 track address unset");
        require(hypeVault != erc20Vault, "vault addresses must differ");

        // --- Network sanity check (same policy as the other scripts) -----
        uint256 expectedChainId = vm.envOr("ELY_CHAIN_ID", uint256(0));
        if (expectedChainId != 0 && block.chainid != expectedChainId) {
            revert("chain id mismatch: the RPC answered with a different chain than ELY_CHAIN_ID");
        }

        // --- Deploy (only if not re-running against an existing registry) -
        vm.startBroadcast(deployerKey);
        StrategyRegistry strategyRegistry;
        VaultRegistry vaultRegistry;
        if (strategyRegistryAddr == address(0)) {
            strategyRegistry = new StrategyRegistry(owner);
        } else {
            strategyRegistry = StrategyRegistry(strategyRegistryAddr);
        }
        vaultRegistry = new VaultRegistry(owner, address(strategyRegistry));

        // Register STRATEGIES first: VaultRegistry's companion cross-check
        // requires registered strategies to be present there (see test
        // VaultRegistryStrategyRegistryMismatch), and this ordering makes
        // registerVaultWithStrategy pass for both tracks.
        strategyRegistry.registerStrategy(hypeStrategy, hypeVault, STRATEGY_TYPE_IDLE, LABEL_HYPE);
        strategyRegistry.registerStrategy(erc20Strategy, erc20Vault, STRATEGY_TYPE_IDLE, LABEL_ERC20);

        vaultRegistry.registerVaultWithStrategy(hypeVault, VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1, hypeStrategy);
        vaultRegistry.registerVaultWithStrategy(erc20Vault, VAULT_TYPE_ERC20, RISK_LOW, METADATA_V1, erc20Strategy);
        vm.stopBroadcast();

        // --- Console summary ---------------------------------------------
        console2.log("AscendMM registries deployed + live infrastructure registered.");
        console2.log("  chain id:                 ", block.chainid);
        console2.log("  deployer:                 ", deployer);
        console2.log("  registry owner:           ", owner);
        console2.log("  StrategyRegistry:         ", address(strategyRegistry));
        console2.log("  VaultRegistry:            ", address(vaultRegistry));
        console2.log("  strategies registered:    ", strategyRegistry.strategyCount());
        console2.log("  vaults registered:        ", vaultRegistry.vaultCount());
        console2.log("  HYPE vault (registered):  ", hypeVault);
        console2.log("  HYPE strategy (registered):", hypeStrategy);
        console2.log("  asMMT vault (registered): ", erc20Vault);
        console2.log("  asMMT strategy (registered):", erc20Strategy);
        if (strategyRegistryAddr != address(0)) {
            console2.log("  NOTE: reused pre-existing StrategyRegistry via STRATEGY_REGISTRY.");
        }
        console2.log("  NOTE: KinetiqLstStrategy stays UNREGISTERED/INACTIVE (no kHYPE on 99801).");
    }
}
