// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AscendVault} from "../src/AscendVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

/// @title DeployAscendVault
/// @notice Deployment script for AscendVault targeting Elysium testnet.
/// @dev Reads ALL configuration from environment variables — no RPC URLs,
///      chain IDs, explorers, or token addresses are hardcoded. See
///      `env.example` for the full list and documentation:
///        * DEPLOYER_PRIVATE_KEY  (required) deployer key; becomes vault
///                                owner unless VAULT_OWNER is set
///        * ELY_UNDERLYING_ASSET   (required) underlying ERC20 asset address
///        * ELY_INITIAL_STRATEGY   (optional) IStrategy bound at deployment
///        * VAULT_OWNER            (optional) owner override (e.g. multisig)
///        * ELY_RPC_URL            (optional) sanity-checked chain id source
///        * ELY_CHAIN_ID           (optional, default 1338) expected chain id
contract DeployAscendVault is Script {
    // Share-token naming (kept as constants so renames stay one-line).
    string constant VAULT_NAME = "AscendMM Vault";
    string constant VAULT_SYMBOL = "asMMV";

    function run() external {
        // --- REQUIRED: deployer identity ---------------------------------
        // vm.envUint reverts with a clear message if the key is unset.
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- REQUIRED: underlying asset ----------------------------------
        string memory assetRaw = vm.envString("ELY_UNDERLYING_ASSET");
        require(bytes(assetRaw).length > 0, "ELY_UNDERLYING_ASSET must be set");
        address underlying = vm.parseAddress(assetRaw);
        require(underlying != address(0), "ELY_UNDERLYING_ASSET cannot be zero");

        // --- OPTIONAL: initial strategy and owner override ----------------
        address initialStrategy = vm.envOr("ELY_INITIAL_STRATEGY", address(0));
        address vaultOwner = vm.envOr("VAULT_OWNER", deployer);

        // --- Network sanity check ----------------------------------------
        // If ELY_CHAIN_ID is set (recommended on real networks: 1338 for the
        // Elysium Atlantis testnet per official docs), fail fast when the
        // target RPC answers with a different chain id. Left unset, the check
        // is skipped so plain local dry-runs (`forge script ...`) still work.
        uint256 expectedChainId = vm.envOr("ELY_CHAIN_ID", uint256(0));
        if (expectedChainId != 0 && block.chainid != expectedChainId) {
            revert("chain id mismatch: the RPC answered with a different chain than ELY_CHAIN_ID");
        }

        // --- Deploy and configure ----------------------------------------
        vm.startBroadcast(deployerKey);
        AscendVault vault = new AscendVault(IERC20(underlying), VAULT_NAME, VAULT_SYMBOL, vaultOwner);
        if (initialStrategy != address(0)) {
            vault.setStrategy(IStrategy(initialStrategy));
        }
        vm.stopBroadcast();

        // --- Console summary ----------------------------------------------
        console2.log("AscendVault deployed.");
        console2.log("  vault:            ", address(vault));
        console2.log("  asset:            ", underlying);
        console2.log("  owner:            ", vault.owner());
        console2.log("  entry fee (bps):  ", vault.entryFeeBps());
        console2.log("  exit fee (bps):   ", vault.exitFeeBps());
        console2.log("  strategy bound:   ", initialStrategy);
        console2.log("  chain id:         ", block.chainid);
    }
}
