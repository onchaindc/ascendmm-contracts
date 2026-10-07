// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AscendVaultHypeGuarded} from "../src/AscendVaultHypeGuarded.sol";
import {HypeIdleStrategy} from "../src/strategies/HypeIdleStrategy.sol";

/// @title DeployAscendVaultHypeGuarded
/// @notice Deploys the GUARDED next-generation native-HYPE (ERC-7535)
///         AscendMM vault (Phase 2G risk + capital controls): a fresh
///         {AscendVaultHypeGuarded} plus a bound {HypeIdleStrategy}, with an
///         optional owner-set total-asset cap. No ERC-20 token is deployed
///         or involved — the underlying asset is native HYPE (msg.value),
///         exposed via the ERC-7528 sentinel.
///
///         DEPLOYMENT BOUNDARY (critical): the LIVE native vault
///         0x8C68b40C6c553b41824F6F8d5E995FCBf809B2e7 is an independent
///         base-vault deployment. This script never interacts with it,
///         cannot upgrade it, and it does NOT gain cap/pause/emergency
///         functionality — those controls exist only on fresh guarded
///         deployments (migration = new vault + user flow).
/// @dev Reads ALL configuration from environment variables — no RPC URLs,
///      chain IDs, or token addresses are hardcoded. See `env.example`:
///        * DEPLOYER_PRIVATE_KEY (required) deployer key; becomes vault
///                              owner unless VAULT_OWNER is set
///        * VAULT_ASSET_CAP     (optional) initial total-asset cap in wei of
///                              HYPE; unset or 0 = unbounded (explicit
///                              default)
///        * HYPE_STRATEGY_CAP   (optional) strategy cap in wei of HYPE;
///                              unset or 0 means unbounded
///        * VAULT_OWNER         (optional) owner override (e.g. multisig)
///        * ELY_RPC_URL         (optional) sanity-checked chain id source
///        * ELY_CHAIN_ID        (optional, e.g. 99801) expected chain id
contract DeployAscendVaultHypeGuarded is Script {
    // Share-token naming (kept as constants so renames stay one-line).
    // Distinct from the live base vault ("AscendMM HYPE Vault" / "asHYPEV")
    // so the guarded next-generation shares are never confused with live
    // ones.
    string constant VAULT_NAME = "AscendMM HYPE Vault Guarded";
    string constant VAULT_SYMBOL = "asHYPEVG";

    function run() external {
        // --- REQUIRED: deployer identity ---------------------------------
        // vm.envUint reverts with a clear message if the key is unset.
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- OPTIONAL: cap, strategy cap, owner override ------------------
        // 0 (or unset) is the EXPLICIT unbounded state for both caps.
        uint256 assetCap = vm.envOr("VAULT_ASSET_CAP", uint256(0));
        uint256 strategyCapRaw = vm.envOr("HYPE_STRATEGY_CAP", uint256(0));
        uint256 strategyCap = strategyCapRaw == 0 ? type(uint256).max : strategyCapRaw;
        address vaultOwner = vm.envOr("VAULT_OWNER", deployer);

        // --- Network sanity check ----------------------------------------
        // If ELY_CHAIN_ID is set (recommended on real networks: 99801 for the
        // Kinetiq Elysium testnet), fail fast when the target RPC answers
        // with a different chain id. Left unset, the check is skipped so
        // plain local dry-runs (`forge script ...`) still work.
        uint256 expectedChainId = vm.envOr("ELY_CHAIN_ID", uint256(0));
        if (expectedChainId != 0 && block.chainid != expectedChainId) {
            revert("chain id mismatch: the RPC answered with a different chain than ELY_CHAIN_ID");
        }

        // --- Deploy and configure ----------------------------------------
        vm.startBroadcast(deployerKey);
        AscendVaultHypeGuarded vault = new AscendVaultHypeGuarded(VAULT_NAME, VAULT_SYMBOL, vaultOwner);
        if (assetCap != 0) {
            vault.setTotalAssetCap(assetCap);
        }
        HypeIdleStrategy strategy = new HypeIdleStrategy(address(vault), strategyCap);
        vault.setStrategy(strategy);
        vm.stopBroadcast();

        // --- Console summary ----------------------------------------------
        console2.log("AscendVaultHypeGuarded (native HYPE, next-generation, Phase 2G) deployed.");
        console2.log("  vault:            ", address(vault));
        console2.log("  strategy:         ", address(strategy));
        console2.log("  asset (sentinel): ", vault.asset());
        console2.log("  owner:            ", vault.owner());
        console2.log("  total asset cap:  ", vault.totalAssetCap());
        console2.log("  deposits paused:  ", vault.depositsPaused());
        console2.log("  share decimals:   ", vault.decimals());
        console2.log("  strategy cap:     ", strategy.cap());
        console2.log("  chain id:         ", block.chainid);
        console2.log("  NOTE: live base vault 0x8C68b40C6c553b41824F6F8d5E995FCBf809B2e7 untouched");
        console2.log("        (the deployed base has NO cap/pause/emergency controls).");
    }
}
