// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title DeployTestAsset
/// @notice TEST-ONLY helper: deploys a mock ERC20 on Elysium testnet so
///         AscendVault can be exercised end-to-end. The official Elysium docs
///         list canonical ERC20s (WELY, PYR) for MAINNET only — no testnet
///         ERC20 is documented — so this mock is the documented fallback for
///         vault testing. Clearly labelled test-only.
/// @dev `MockERC20.mint()` is permissionless (anyone can mint more). NEVER
///      deploy this on mainnet or attach real value to it.
contract DeployTestAsset is Script {
    function run() external {
        // --- REQUIRED: deployer identity ---------------------------------
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- OPTIONAL: mock asset configuration ---------------------------
        string memory assetName = vm.envOr("TEST_ASSET_NAME", string("AscendMM Test Asset"));
        string memory assetSymbol = vm.envOr("TEST_ASSET_SYMBOL", string("asMMT"));
        uint8 assetDecimals = uint8(vm.envOr("TEST_ASSET_DECIMALS", uint256(18)));
        uint256 initialMint = vm.envOr("TEST_ASSET_INITIAL_MINT", uint256(1_000_000 ether));

        // --- Network sanity check (same policy as DeployAscendVault) ------
        uint256 expectedChainId = vm.envOr("ELY_CHAIN_ID", uint256(0));
        if (expectedChainId != 0 && block.chainid != expectedChainId) {
            revert("chain id mismatch: the RPC answered with a different chain than ELY_CHAIN_ID");
        }

        // --- Deploy and seed -----------------------------------------------
        vm.startBroadcast(deployerKey);
        MockERC20 asset = new MockERC20(assetName, assetSymbol, assetDecimals);
        asset.mint(deployer, initialMint);
        vm.stopBroadcast();

        // --- Console summary ------------------------------------------------
        console2.log("TEST-ONLY MockERC20 deployed (not for production use).");
        console2.log("  asset:            ", address(asset));
        console2.log("  name:             ", assetName);
        console2.log("  symbol:           ", assetSymbol);
        console2.log("  decimals:         ", uint256(assetDecimals));
        console2.log("  seeded to:        ", deployer);
        console2.log("  seeded amount:    ", initialMint);
        console2.log("  chain id:         ", block.chainid);
    }
}
