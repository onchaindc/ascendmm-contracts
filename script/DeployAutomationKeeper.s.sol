// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AutomationKeeper} from "../src/automation/AutomationKeeper.sol";

/// @title DeployAutomationKeeper
/// @notice Deployment script for the Phase 2I automation keeper targeting
///         Elysium testnet. The keeper is anchored on the CANONICAL protocol
///         registries (Phase 2D deployments) — it must never be pointed at a
///         replacement directory without re-verifying every registered entry.
///
///         DEPLOYMENT POSTURE: NOT broadcast in Phase 2I. No live automation
///         need exists (no yield strategy is deployed on 99801 and the live
///         vaults are owner-controlled by an EOA). The script is provided
///         source-ready for when the protocol decides to operate automation.
///         After deployment, actual execution additionally requires the
///         protocol owner to DELEGATE each target contract's admin rights to
///         the keeper (e.g. ownership transfer) — the keeper never bypasses
///         a target's own authorization.
/// @dev Reads ALL configuration from environment variables. See `env.example`:
///        * DEPLOYER_PRIVATE_KEY (required) deployer key
///        * KEEPER_ADMIN          (optional) admin of the keeper (manages the
///                                keeper allowlist; ideally a multisig);
///                                defaults to the deployer
///        * VAULT_REGISTRY        (optional) canonical VaultRegistry; defaults
///                                to the Phase 2D deployment
///                                 0xEf46f925BCC546ECAB7Dae5DF965E3980fd4B6b8
///        * STRATEGY_REGISTRY     (optional) canonical StrategyRegistry;
///                                defaults to
///                                 0x14Af880C9d471C00077C9919035574d003D92bFf
///        * ELY_RPC_URL           (optional) sanity-checked chain id source
///        * ELY_CHAIN_ID          (optional, e.g. 99801) expected chain id
contract DeployAutomationKeeper is Script {
    // Canonical Phase 2D registry deployments on Elysium 99801 (defaults;
    // every value can be overridden via env).
    address constant DEFAULT_VAULT_REGISTRY = 0xEF46F925Bcc546ECAB7DaE5dF965E3980Fd4B6B8;
    address constant DEFAULT_STRATEGY_REGISTRY = 0x14Af880C9d471c00077C9919035574D003d92bFF;

    function run() external {
        // --- REQUIRED: deployer identity ---------------------------------
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- OPTIONAL: admin + registry anchors ---------------------------
        address admin = vm.envOr("KEEPER_ADMIN", deployer);
        string memory vaultRegistryRaw = vm.envOr("VAULT_REGISTRY", string(""));
        string memory strategyRegistryRaw = vm.envOr("STRATEGY_REGISTRY", string(""));

        address vaultRegistry =
            bytes(vaultRegistryRaw).length == 0 ? DEFAULT_VAULT_REGISTRY : vm.parseAddress(vaultRegistryRaw);
        address strategyRegistry =
            bytes(strategyRegistryRaw).length == 0 ? DEFAULT_STRATEGY_REGISTRY : vm.parseAddress(strategyRegistryRaw);

        require(vaultRegistry != address(0), "VAULT_REGISTRY cannot be zero");
        require(strategyRegistry != address(0), "STRATEGY_REGISTRY cannot be zero");

        // --- Network sanity check ----------------------------------------
        uint256 expectedChainId = vm.envOr("ELY_CHAIN_ID", uint256(0));
        if (expectedChainId != 0 && block.chainid != expectedChainId) {
            revert("chain id mismatch: the RPC answered with a different chain than ELY_CHAIN_ID");
        }

        // --- Deploy --------------------------------------------------------
        vm.startBroadcast(deployerKey);
        AutomationKeeper keeper = new AutomationKeeper(admin, vaultRegistry, strategyRegistry);
        vm.stopBroadcast();

        // --- Console summary ----------------------------------------------
        console2.log("AutomationKeeper (Phase 2I) deployed.");
        console2.log("  keeper:             ", address(keeper));
        console2.log("  admin:              ", keeper.owner());
        console2.log("  vault registry:     ", address(keeper.vaultRegistry()));
        console2.log("  strategy registry:  ", address(keeper.strategyRegistry()));
        console2.log("  chain id:           ", block.chainid);
        console2.log("  NOTE: not broadcast in Phase 2I dry-run posture; execution");
        console2.log("        additionally requires delegating each target's admin");
        console2.log("        rights to the keeper (e.g. ownership transfer).");
    }
}
