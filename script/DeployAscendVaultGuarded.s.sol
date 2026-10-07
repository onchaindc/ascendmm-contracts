// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AscendVaultGuarded} from "../src/AscendVaultGuarded.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";

/// @title DeployAscendVaultGuarded
/// @notice Deployment script for the GUARDED next-generation AscendVault
///         (Phase 2G risk + capital controls) targeting Elysium testnet.
///         Deploys a fresh {AscendVaultGuarded} — the ERC-4626 base vault
///         plus an owner-set total-asset cap, a deposits pause, and a
///         loss-aware emergency strategy exit.
///
///         DEPLOYMENT BOUNDARY (critical): the LIVE vaults
///         0xa49Ef74F7de5022340bE2f7DeD7bD2c54b344480 (ERC-20) and
///         0x8C68b40C6c553b41824F6F8d5E995FCBf809B2e7 (native HYPE) are
///         independent base-vault deployments. This script never interacts
///         with them, cannot upgrade them, and they do NOT gain cap/pause/
///         emergency functionality — those controls exist only on fresh
///         guarded deployments (migration = new vault + user flow).
/// @dev Reads ALL configuration from environment variables — no RPC URLs,
///      chain IDs, or token addresses are hardcoded. See `env.example`:
///        * DEPLOYER_PRIVATE_KEY  (required) deployer key; becomes vault
///                                owner unless VAULT_OWNER is set
///        * ELY_UNDERLYING_ASSET  (required) underlying ERC20 asset address
///        * VAULT_ASSET_CAP       (optional) initial total-asset cap; unset
///                                or 0 = unbounded (explicit default)
///        * ELY_INITIAL_STRATEGY  (optional) IStrategy bound at deployment
///        * DEPLOY_IDLE_STRATEGY  (optional, default false) deploy + bind an
///                                IdleStrategy (ignored when
///                                ELY_INITIAL_STRATEGY is set)
///        * STRATEGY_CAP          (optional) IdleStrategy cap; unset/0 =
///                                unbounded
///        * VAULT_OWNER           (optional) owner override (e.g. multisig)
///        * ELY_RPC_URL           (optional) sanity-checked chain id source
///        * ELY_CHAIN_ID          (optional, e.g. 99801) expected chain id
contract DeployAscendVaultGuarded is Script {
    // Share-token naming (kept as constants so renames stay one-line).
    // Distinct from the live base vault ("AscendMM Vault" / "asMMV") so the
    // guarded next-generation shares are never confused with live ones.
    string constant VAULT_NAME = "AscendMM Vault Guarded";
    string constant VAULT_SYMBOL = "asMMVG";

    function run() external {
        // --- REQUIRED: deployer identity ---------------------------------
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- REQUIRED: underlying asset ----------------------------------
        string memory assetRaw = vm.envString("ELY_UNDERLYING_ASSET");
        require(bytes(assetRaw).length > 0, "ELY_UNDERLYING_ASSET must be set");
        address underlying = vm.parseAddress(assetRaw);
        require(underlying != address(0), "ELY_UNDERLYING_ASSET cannot be zero");

        // --- OPTIONAL: cap, initial strategy, fresh idle strategy, owner -
        // 0 (or unset) is the EXPLICIT unbounded state; any nonzero value
        // is applied right after deployment via setTotalAssetCap.
        uint256 assetCap = vm.envOr("VAULT_ASSET_CAP", uint256(0));
        address initialStrategy = vm.envOr("ELY_INITIAL_STRATEGY", address(0));
        bool deployIdleStrategy = vm.envOr("DEPLOY_IDLE_STRATEGY", false);
        uint256 strategyCapRaw = vm.envOr("STRATEGY_CAP", uint256(0));
        address vaultOwner = vm.envOr("VAULT_OWNER", deployer);

        // --- Network sanity check ----------------------------------------
        uint256 expectedChainId = vm.envOr("ELY_CHAIN_ID", uint256(0));
        if (expectedChainId != 0 && block.chainid != expectedChainId) {
            revert("chain id mismatch: the RPC answered with a different chain than ELY_CHAIN_ID");
        }

        // --- Deploy and configure ----------------------------------------
        vm.startBroadcast(deployerKey);
        AscendVaultGuarded vault = new AscendVaultGuarded(IERC20(underlying), VAULT_NAME, VAULT_SYMBOL, vaultOwner);
        if (assetCap != 0) {
            vault.setTotalAssetCap(assetCap);
        }
        if (initialStrategy != address(0)) {
            vault.setStrategy(IStrategy(initialStrategy));
        } else if (deployIdleStrategy) {
            uint256 strategyCap = strategyCapRaw == 0 ? type(uint256).max : strategyCapRaw;
            IdleStrategy idle = new IdleStrategy(address(vault), IERC20(underlying), strategyCap);
            vault.setStrategy(idle);
            console2.log("  idle strategy:    ", address(idle));
        }
        vm.stopBroadcast();

        // --- Console summary ----------------------------------------------
        console2.log("AscendVaultGuarded (next-generation, Phase 2G) deployed.");
        console2.log("  vault:            ", address(vault));
        console2.log("  asset:            ", underlying);
        console2.log("  owner:            ", vault.owner());
        console2.log("  total asset cap:  ", vault.totalAssetCap());
        console2.log("  deposits paused:  ", vault.depositsPaused());
        console2.log("  strategy bound:   ", vault.strategy());
        console2.log("  chain id:         ", block.chainid);
        console2.log("  NOTE: live base vault 0xa49Ef74F7de5022340bE2f7DeD7bD2c54b344480 untouched");
        console2.log("        (the deployed base has NO cap/pause/emergency controls).");
    }
}
