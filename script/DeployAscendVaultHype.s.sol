// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AscendVaultHype} from "../src/AscendVaultHype.sol";
import {HypeIdleStrategy} from "../src/strategies/HypeIdleStrategy.sol";

/// @title DeployAscendVaultHype
/// @notice Deploys the native-HYPE (ERC-7535) AscendMM vault track for
///         Kinetiq Elysium: a fresh {AscendVaultHype} plus a bound
///         {HypeIdleStrategy}. No ERC-20 token is deployed or involved —
///         the underlying asset is native HYPE (msg.value), exposed via the
///         ERC-7528 sentinel `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.
/// @dev Reads ALL configuration from environment variables — no RPC URLs,
///      chain IDs, or token addresses are hardcoded. See `env.example`:
///        * DEPLOYER_PRIVATE_KEY (required) deployer key; becomes vault
///                              owner unless VAULT_OWNER is set
///        * HYPE_STRATEGY_CAP    (optional) strategy cap in wei of HYPE;
///                               unset or 0 means unbounded
///        * VAULT_OWNER          (optional) owner override (e.g. multisig)
///        * ELY_RPC_URL          (optional) sanity-checked chain id source
///        * ELY_CHAIN_ID         (optional, e.g. 99801) expected chain id
///      This script NEVER touches the ERC-20 track: no asMMT vault, no
///      IdleStrategy, no migration. The existing ERC-20 vault at
///      0xa49Ef74F7de5022340bE2f7DeD7bD2c54b344480 remains untouched.
contract DeployAscendVaultHype is Script {
    // Share-token naming (kept as constants so renames stay one-line).
    string constant VAULT_NAME = "AscendMM HYPE Vault";
    string constant VAULT_SYMBOL = "asHYPEV";

    function run() external {
        // --- REQUIRED: deployer identity ---------------------------------
        // vm.envUint reverts with a clear message if the key is unset.
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- OPTIONAL: strategy cap + owner override ---------------------
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
        AscendVaultHype vault = new AscendVaultHype(VAULT_NAME, VAULT_SYMBOL, vaultOwner);
        HypeIdleStrategy strategy = new HypeIdleStrategy(address(vault), strategyCap);
        vault.setStrategy(strategy);
        vm.stopBroadcast();

        // --- Console summary ----------------------------------------------
        console2.log("AscendVaultHype (native HYPE, ERC-7535) deployed.");
        console2.log("  vault:            ", address(vault));
        console2.log("  strategy:         ", address(strategy));
        console2.log("  asset (sentinel): ", vault.asset());
        console2.log("  owner:            ", vault.owner());
        console2.log("  share decimals:   ", vault.decimals());
        console2.log("  strategy cap:     ", strategy.cap());
        console2.log("  chain id:         ", block.chainid);
        console2.log("  NOTE: ERC-20 track vault 0xa49Ef74F7de5022340bE2f7DeD7bD2c54b344480 untouched.");
    }
}
