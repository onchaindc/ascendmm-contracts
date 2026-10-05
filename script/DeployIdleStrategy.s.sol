// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AscendVault} from "../src/AscendVault.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";

/// @title DeployIdleStrategy
/// @notice Dedicated deployment/configuration path for the IdleStrategy.
///         Deploys an IdleStrategy bound to an EXISTING vault and optionally
///         binds it via `setStrategy` (the broadcast key must then belong to
///         the vault owner).
/// @dev IMPORTANT — old foundation vaults: a vault deployed BEFORE the
///      strategy-accounting change (e.g. the 2026-10-04 Kinetiq testnet vault
///      0x3633E203A2E46C565E72d386c350ba7378384b49) has the placeholder
///      `setStrategy` only. Binding works there, but that bytecode never
///      invests idle assets and its `totalAssets()` is idle-only; use a fresh
///      vault (DeployAscendVault with DEPLOY_IDLE_STRATEGY=true) for the full
///      strategy flow.
///
///      Environment (see `env.example`):
///        * DEPLOYER_PRIVATE_KEY  (required) deployer; must be the vault
///                                owner when BIND_STRATEGY=true
///        * VAULT_ADDRESS         (required) target vault
///        * ELY_UNDERLYING_ASSET  (required) MUST equal the vault's asset
///                                (the vault's binding validation reverts
///                                otherwise; nothing gets deployed twice)
///        * STRATEGY_CAP          (optional) cap in asset units; unset or 0
///                                means unbounded
///        * BIND_STRATEGY         (optional, default false) call setStrategy
///                                right after deployment
///        * ELY_CHAIN_ID          (optional) chain-id sanity check
contract DeployIdleStrategy is Script {
    function run() external {
        // --- REQUIRED: deployer identity ---------------------------------
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- REQUIRED: target vault --------------------------------------
        string memory vaultRaw = vm.envString("VAULT_ADDRESS");
        require(bytes(vaultRaw).length > 0, "VAULT_ADDRESS must be set");
        address vaultAddr = vm.parseAddress(vaultRaw);
        require(vaultAddr != address(0), "VAULT_ADDRESS cannot be zero");

        // --- REQUIRED: underlying asset ----------------------------------
        string memory assetRaw = vm.envString("ELY_UNDERLYING_ASSET");
        require(bytes(assetRaw).length > 0, "ELY_UNDERLYING_ASSET must be set");
        address underlying = vm.parseAddress(assetRaw);
        require(underlying != address(0), "ELY_UNDERLYING_ASSET cannot be zero");

        // --- OPTIONAL: cap and binding ------------------------------------
        uint256 capRaw = vm.envOr("STRATEGY_CAP", uint256(0));
        uint256 cap = capRaw == 0 ? type(uint256).max : capRaw;
        bool bind = vm.envOr("BIND_STRATEGY", false);

        // --- Network sanity check (same policy as the other scripts) ------
        uint256 expectedChainId = vm.envOr("ELY_CHAIN_ID", uint256(0));
        if (expectedChainId != 0 && block.chainid != expectedChainId) {
            revert("chain id mismatch: the RPC answered with a different chain than ELY_CHAIN_ID");
        }

        // --- Deploy (and optionally bind) ---------------------------------
        vm.startBroadcast(deployerKey);
        IdleStrategy strategy = new IdleStrategy(vaultAddr, IERC20(underlying), cap);
        if (bind) {
            AscendVault(vaultAddr).setStrategy(strategy);
        }
        vm.stopBroadcast();

        // --- Console summary ----------------------------------------------
        console2.log("IdleStrategy deployed.");
        console2.log("  strategy:         ", address(strategy));
        console2.log("  bound vault:      ", vaultAddr);
        console2.log("  asset:            ", underlying);
        console2.log("  cap:              ", cap);
        console2.log("  bound via setStrategy:", bind);
        console2.log("  chain id:         ", block.chainid);
    }
}
