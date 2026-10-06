// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IHypeStrategy} from "../src/interfaces/IHypeStrategy.sol";
import {AscendVault} from "../src/AscendVault.sol";
import {AscendVaultHype} from "../src/AscendVaultHype.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {HypeIdleStrategy} from "../src/strategies/HypeIdleStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MisboundStrategy} from "./mocks/MockStrategy.sol";
import {MisboundHypeStrategy} from "./mocks/EvilHypeStrategies.sol";

/// @dev Vault-type identifier shared by the VaultRegistry suites.
bytes32 constant VAULT_TYPE_HYPE = keccak256("ASCEND_VAULT_HYPE_V1");
bytes32 constant VAULT_TYPE_ERC20 = keccak256("ASCEND_VAULT_ERC20_V1");
bytes32 constant IDLE_TYPE = keccak256("ASCEND_IDLE_V1");
bytes32 constant METADATA_V1 = bytes32("V1");

/// @dev Mirrors {VaultRegistry.RISK_*} (identical keccak inputs, so values
///      are bit-for-bit equal) as compile-time constants: type-name access
///      to the contracts' keccak-initialized constants does not resolve
///      under solc 0.8.24, and the instance getters would be external calls
///      evaluated inside prank/expectRevert arguments (known gotcha).
bytes32 constant RISK_LOW = keccak256("RISK_LOW");
bytes32 constant RISK_MEDIUM = keccak256("RISK_MEDIUM");
bytes32 constant RISK_HIGH = keccak256("RISK_HIGH");
bytes32 constant RISK_EXPERIMENTAL = keccak256("RISK_EXPERIMENTAL");

/// @dev Test-only strategy whose vault binding is MUTABLE: used to simulate a
///      strategy that was registered against one vault and later rebound to
///      another, so the cross-registry consistency check can be exercised
///      (the production strategies have immutable bindings).
contract MockMutableStrategy is IStrategy {
    address public immutable override asset;
    uint256 public immutable override cap;
    address private _vault;

    constructor(address asset_) {
        asset = asset_;
        cap = type(uint256).max;
    }

    function setVault(address v) external {
        _vault = v;
    }

    function vault() external view override returns (address) {
        return _vault;
    }

    function totalAssets() external view override returns (uint256) {
        return 0;
    }

    function invest(uint256) external payable override {}

    function divest(uint256) external override {
        revert("unused");
    }

    function divestAll() external override {
        revert("unused");
    }

    function harvest() external override {
        revert("unused");
    }

    function report() external override returns (int256) {
        return 0;
    }
}

/// @notice Core suite: {VaultRegistry} x {AscendVaultHype} + {HypeIdleStrategy},
///         wired to a companion {StrategyRegistry} (the intended deploy shape).
contract VaultRegistryHypeTest is Test {
    StrategyRegistry internal sRegistry;
    VaultRegistry internal vRegistry;
    AscendVaultHype internal vault;
    HypeIdleStrategy internal strategy;

    address internal owner_ = makeAddr("owner");
    address internal alice = makeAddr("alice");

    receive() external payable {}

    function setUp() public {
        vault = new AscendVaultHype("AscendMM HYPE Vault", "asHYPEV", owner_);
        strategy = new HypeIdleStrategy(address(vault), type(uint256).max);
        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(strategy)));
        sRegistry = new StrategyRegistry(owner_);
        vRegistry = new VaultRegistry(owner_, address(sRegistry));
    }

    function _registerDefault() internal {
        vm.prank(owner_);
        vRegistry.registerVault(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1);
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    function test_Register_VaultWithStrategy() public {
        vm.startPrank(owner_);
        sRegistry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);
        vm.expectEmit(true, true, false, true, address(vRegistry));
        emit VaultRegistry.VaultRegistered(
            address(vault), vault.NATIVE_ASSET_SENTINEL(), VAULT_TYPE_HYPE, address(strategy), RISK_LOW, METADATA_V1
        );
        vRegistry.registerVaultWithStrategy(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1, address(strategy));
        vm.stopPrank();

        assertTrue(vRegistry.isRegistered(address(vault)));
        assertTrue(vRegistry.isActive(address(vault)));
        VaultRegistry.VaultEntry memory e = vRegistry.getVault(address(vault));
        assertEq(e.vault, address(vault));
        assertEq(e.asset, vault.NATIVE_ASSET_SENTINEL());
        assertEq(e.vaultType, VAULT_TYPE_HYPE);
        assertEq(e.strategy, address(strategy));
        assertEq(e.riskClass, RISK_LOW);
        assertEq(e.metadata, METADATA_V1);
        assertEq(vRegistry.vaultCount(), 1);
    }

    function test_Register_VaultWithoutStrategy() public {
        _registerDefault();

        assertTrue(vRegistry.isRegistered(address(vault)));
        assertEq(vRegistry.getVault(address(vault)).strategy, address(0));
        assertEq(vRegistry.getVault(address(vault)).asset, vault.NATIVE_ASSET_SENTINEL());
        assertEq(vRegistry.strategyRegistry(), address(sRegistry));
    }

    function test_Register_DuplicateReverted() public {
        vm.startPrank(owner_);
        vRegistry.registerVault(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryAlreadyRegistered.selector, address(vault)));
        vRegistry.registerVault(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1);
        vm.stopPrank();
    }

    function test_Register_InvalidVaultReverted() public {
        vm.startPrank(owner_);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryNotContract.selector, alice));
        vRegistry.registerVault(alice, VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1);
        vm.expectRevert(VaultRegistry.VaultRegistryZeroAddress.selector);
        vRegistry.registerVault(address(0), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryVaultTypeEmpty.selector, address(vault)));
        vRegistry.registerVault(address(vault), bytes32(0), RISK_LOW, METADATA_V1);
        vm.expectRevert(
            abi.encodeWithSelector(VaultRegistry.VaultRegistryInvalidRiskClass.selector, bytes32("NOT_A_BUCKET"))
        );
        vRegistry.registerVault(address(vault), VAULT_TYPE_HYPE, bytes32("NOT_A_BUCKET"), METADATA_V1);
        vm.stopPrank();
    }

    function test_Register_InvalidStrategyReverted() public {
        // EOA strategy.
        vm.startPrank(owner_);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryNotContract.selector, alice));
        vRegistry.registerVaultWithStrategy(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1, alice);
        vm.stopPrank();

        // Strategy bound to a different vault.
        MisboundHypeStrategy misbound = new MisboundHypeStrategy(address(0xdead), address(0xdead));
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultRegistry.VaultRegistryStrategyVaultMismatch.selector,
                address(misbound),
                address(vault),
                address(0xdead)
            )
        );
        vRegistry.registerVaultWithStrategy(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1, address(misbound));

        // Strategy reports the vault correctly but a WRONG asset.
        address wrongAsset = makeAddr("wrongAsset");
        MisboundHypeStrategy misAsset = new MisboundHypeStrategy(address(vault), wrongAsset);
        address sentinel = vault.NATIVE_ASSET_SENTINEL();
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultRegistry.VaultRegistryStrategyAssetMismatch.selector, address(misAsset), sentinel, wrongAsset
            )
        );
        vRegistry.registerVaultWithStrategy(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1, address(misAsset));
    }

    function test_Register_StrategyRegistryDisagreementReverted() public {
        // The mutable-bound strategy is registered in the companion registry
        // while bound to vault A, then rebound to THIS vault. The vault-side
        // binding/asset checks pass, but the companion registry still
        // records vault A — the cross-check must reject the registration.
        address sentinel = vault.NATIVE_ASSET_SENTINEL();

        AscendVaultHype vaultA = new AscendVaultHype("Vault A", "asAV1", owner_);
        MockMutableStrategy mutableStrategy = new MockMutableStrategy(sentinel);

        vm.startPrank(owner_);
        // Registered in the companion registry while bound to vaultA.
        mutableStrategy.setVault(address(vaultA));
        sRegistry.registerStrategy(address(mutableStrategy), address(vaultA), IDLE_TYPE);

        // Rebind the strategy to the main vault: the vault-side checks
        // (vault() == vault, asset() == sentinel) now pass, but the companion
        // registry still records vaultA — the registries would disagree.
        mutableStrategy.setVault(address(vault));

        vm.expectRevert(
            abi.encodeWithSelector(
                VaultRegistry.VaultRegistryStrategyRegistryMismatch.selector,
                address(mutableStrategy),
                address(vault),
                address(vaultA)
            )
        );
        vRegistry.registerVaultWithStrategy(
            address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1, address(mutableStrategy)
        );
        vm.stopPrank();

        assertFalse(vRegistry.isRegistered(address(vault)));
    }

    function test_UpdateStrategy_ReassignAndClear() public {
        _registerDefault();

        HypeIdleStrategy strategy2 = new HypeIdleStrategy(address(vault), type(uint256).max);
        vm.startPrank(owner_);
        // Unset → strategy2.
        vm.expectEmit(true, false, false, true, address(vRegistry));
        emit VaultRegistry.VaultStrategyUpdated(address(vault), address(0), address(strategy2));
        vRegistry.updateStrategy(address(vault), address(strategy2));
        assertEq(vRegistry.getVault(address(vault)).strategy, address(strategy2));

        // Clearing is allowed (no strategy association).
        vm.expectEmit(true, false, false, true, address(vRegistry));
        emit VaultRegistry.VaultStrategyUpdated(address(vault), address(strategy2), address(0));
        vRegistry.updateStrategy(address(vault), address(0));
        assertEq(vRegistry.getVault(address(vault)).strategy, address(0));

        // Re-association after clearing.
        vm.expectEmit(true, false, false, true, address(vRegistry));
        emit VaultRegistry.VaultStrategyUpdated(address(vault), address(0), address(strategy));
        vRegistry.updateStrategy(address(vault), address(strategy));
        vm.stopPrank();
        assertEq(vRegistry.getVault(address(vault)).strategy, address(strategy));
    }

    function test_UpdateStrategy_Rejections() public {
        _registerDefault();
        HypeIdleStrategy strategy2 = new HypeIdleStrategy(address(vault), type(uint256).max);

        vm.startPrank(owner_);
        // Associate the strategy first so the no-op case is reachable.
        vRegistry.updateStrategy(address(vault), address(strategy));

        // Same strategy: rejected as an unobservable no-op.
        vm.expectRevert(
            abi.encodeWithSelector(VaultRegistry.VaultRegistrySameStrategy.selector, address(vault), address(strategy))
        );
        vRegistry.updateStrategy(address(vault), address(strategy));

        // Unregistered vault.
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryNotRegistered.selector, alice));
        vRegistry.updateStrategy(alice, address(strategy2));

        // Strategy bound elsewhere.
        MisboundHypeStrategy misbound = new MisboundHypeStrategy(address(0xdead), address(0xdead));
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultRegistry.VaultRegistryStrategyVaultMismatch.selector,
                address(misbound),
                address(vault),
                address(0xdead)
            )
        );
        vRegistry.updateStrategy(address(vault), address(misbound));

        // EOA strategy.
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryNotContract.selector, alice));
        vRegistry.updateStrategy(address(vault), alice);
        vm.stopPrank();

        assertEq(vRegistry.getVault(address(vault)).strategy, address(strategy));
    }

    // ------------------------------------------------------------------
    // Pause / activate
    // ------------------------------------------------------------------

    function test_SetActive_Lifecycle() public {
        _registerDefault();

        vm.startPrank(owner_);
        vm.expectEmit(true, false, false, true, address(vRegistry));
        emit VaultRegistry.VaultDeactivated(address(vault));
        vRegistry.setActive(address(vault), false);
        assertFalse(vRegistry.isActive(address(vault)));
        assertTrue(vRegistry.isRegistered(address(vault)));

        vm.expectEmit(true, false, false, true, address(vRegistry));
        emit VaultRegistry.VaultActivated(address(vault));
        vRegistry.setActive(address(vault), true);
        assertTrue(vRegistry.isActive(address(vault)));
        vm.stopPrank();
    }

    function test_SetActive_IdempotenceAndUnknownReverted() public {
        _registerDefault();

        vm.startPrank(owner_);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryAlreadyActive.selector, address(vault)));
        vRegistry.setActive(address(vault), true);
        vRegistry.setActive(address(vault), false);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryAlreadyPaused.selector, address(vault)));
        vRegistry.setActive(address(vault), false);
        vm.stopPrank();

        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryNotRegistered.selector, alice));
        vRegistry.setActive(alice, true);
    }

    // ------------------------------------------------------------------
    // Risk classification
    // ------------------------------------------------------------------

    function test_SetRiskClass_LifecycleAndValidation() public {
        _registerDefault();

        vm.startPrank(owner_);
        vm.expectEmit(true, true, false, true, address(vRegistry));
        emit VaultRegistry.VaultRiskUpdated(address(vault), RISK_LOW, RISK_HIGH);
        vRegistry.setRiskClass(address(vault), RISK_HIGH);
        assertEq(vRegistry.getVault(address(vault)).riskClass, RISK_HIGH);

        // Invalid bucket.
        vm.expectRevert(
            abi.encodeWithSelector(VaultRegistry.VaultRegistryInvalidRiskClass.selector, bytes32("NOT_A_BUCKET"))
        );
        vRegistry.setRiskClass(address(vault), bytes32("NOT_A_BUCKET"));
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryInvalidRiskClass.selector, bytes32(0)));
        vRegistry.setRiskClass(address(vault), bytes32(0));

        // No-op transition.
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistrySameRisk.selector, address(vault), RISK_HIGH));
        vRegistry.setRiskClass(address(vault), RISK_HIGH);
        vm.stopPrank();
    }

    function test_SetRiskClass_UnregisteredReverted() public {
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.VaultRegistryNotRegistered.selector, address(vault)));
        vRegistry.setRiskClass(address(vault), RISK_HIGH);
    }

    // ------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------

    function test_SetMetadata_UpdateAndNoOpReverted() public {
        _registerDefault();

        vm.startPrank(owner_);
        vm.expectEmit(true, false, false, true, address(vRegistry));
        emit VaultRegistry.VaultMetadataUpdated(address(vault), METADATA_V1, bytes32("V2"));
        vRegistry.setMetadata(address(vault), bytes32("V2"));
        assertEq(vRegistry.getVault(address(vault)).metadata, bytes32("V2"));

        vm.expectRevert(
            abi.encodeWithSelector(VaultRegistry.VaultRegistrySameMetadata.selector, address(vault), bytes32("V2"))
        );
        vRegistry.setMetadata(address(vault), bytes32("V2"));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Removal + enumeration
    // ------------------------------------------------------------------

    function test_RemoveVault_RemovesEntry() public {
        _registerDefault();

        vm.startPrank(owner_);
        vm.expectEmit(true, false, false, true, address(vRegistry));
        emit VaultRegistry.VaultRemoved(address(vault), vault.NATIVE_ASSET_SENTINEL(), address(0));
        vRegistry.removeVault(address(vault));
        vm.stopPrank();

        assertFalse(vRegistry.isRegistered(address(vault)));
        assertFalse(vRegistry.isActive(address(vault)));
        VaultRegistry.VaultEntry memory e = vRegistry.getVault(address(vault));
        assertEq(e.vault, address(0));
        assertEq(e.asset, address(0));
        assertEq(vRegistry.vaultCount(), 0);
        assertEq(vRegistry.allVaults().length, 0);

        // Fresh registration after removal.
        _registerDefault();
        assertTrue(vRegistry.isRegistered(address(vault)));
        assertEq(vRegistry.vaultCount(), 1);
    }

    function test_Enumeration_TailSwapIntegrity() public {
        AscendVaultHype v2 = new AscendVaultHype("V2", "asHYPEV2", owner_);
        AscendVaultHype v3 = new AscendVaultHype("V3", "asHYPEV3", owner_);

        vm.startPrank(owner_);
        vRegistry.registerVault(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1);
        vRegistry.registerVault(address(v2), VAULT_TYPE_HYPE, RISK_MEDIUM, METADATA_V1);
        vRegistry.registerVault(address(v3), VAULT_TYPE_HYPE, RISK_HIGH, METADATA_V1);
        vRegistry.removeVault(address(vault));
        vm.stopPrank();

        address[] memory all = vRegistry.allVaults();
        assertEq(all.length, 2);
        assertTrue(all[0] == address(v3));
        assertTrue(all[1] == address(v2));
        assertEq(vRegistry.vaultCount(), 2);
    }

    // ------------------------------------------------------------------
    // Unauthorized administration
    // ------------------------------------------------------------------

    function test_Unauthorized_NonOwnerCannotAdminister() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vRegistry.registerVault(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vRegistry.registerVaultWithStrategy(address(vault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1, address(strategy));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vRegistry.updateStrategy(address(vault), address(strategy));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vRegistry.setActive(address(vault), false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vRegistry.setRiskClass(address(vault), RISK_HIGH);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vRegistry.setMetadata(address(vault), bytes32("V2"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vRegistry.removeVault(address(vault));
        vm.stopPrank();

        assertEq(vRegistry.vaultCount(), 0);
    }

    // ------------------------------------------------------------------
    // Registry is bookkeeping-only; the vault's own flow is untouched
    // ------------------------------------------------------------------

    function test_RegistryDoesNotAffectHypeVaultMigrationFlow() public {
        uint256 AMOUNT = 10e18;
        _registerDefault();

        deal(alice, AMOUNT);
        vm.prank(alice);
        vault.deposit{value: AMOUNT}(AMOUNT, alice);
        vm.startPrank(owner_);
        vault.investIdle(AMOUNT);
        assertEq(vault.strategyInvested(), AMOUNT);

        // Full migration flow with registry bookkeeping alongside:
        // exitStrategy → setStrategy → investIdle (+ updateStrategy).
        HypeIdleStrategy fresh = new HypeIdleStrategy(address(vault), type(uint256).max);
        vault.exitStrategy();
        vault.setStrategy(IHypeStrategy(address(fresh)));
        vRegistry.updateStrategy(address(vault), address(fresh));
        vault.investIdle(AMOUNT);
        vm.stopPrank();

        assertEq(address(vault.strategy()), address(fresh));
        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(vRegistry.getVault(address(vault)).strategy, address(fresh));

        // Deactivating the registry entry does not block the vault.
        vm.prank(owner_);
        vRegistry.setActive(address(vault), false);
        vm.prank(owner_);
        vault.exitStrategy();
        assertEq(vault.strategyInvested(), 0);
    }

    function test_RegistryHoldsNoFunds() public {
        _registerDefault();
        assertEq(address(vRegistry).balance, 0);

        // Plain native transfers to the registry are rejected (no payable
        // surface, no receive()): it can never custody funds.
        deal(address(this), address(this).balance + 1e18);
        (bool ok,) = address(vRegistry).call{value: 1e18}("");
        assertFalse(ok, "registry must reject native value");
        assertEq(address(vRegistry).balance, 0);
    }
}

/// @notice ERC-20-track suite (standalone registry, no companion): proves the
///         validation logic is track-agnostic.
contract VaultRegistryErc20Test is Test {
    VaultRegistry internal vRegistry;
    AscendVault internal vault;
    IdleStrategy internal strategy;
    MockERC20 internal asset;

    address internal owner_ = makeAddr("erc20Owner");
    address internal alice = makeAddr("erc20Alice");

    function setUp() public {
        asset = new MockERC20("Mock HYPE", "MHYPE", 18);
        vault = new AscendVault(IERC20(address(asset)), "AscendMM Vault", "asMMT", owner_);
        strategy = new IdleStrategy(address(vault), asset, type(uint256).max);
        vm.prank(owner_);
        vault.setStrategy(IStrategy(address(strategy)));
        vRegistry = new VaultRegistry(owner_, address(0));
    }

    function test_Register_Erc20VaultAndStrategy() public {
        vm.startPrank(owner_);
        vm.expectEmit(true, true, false, true, address(vRegistry));
        emit VaultRegistry.VaultRegistered(
            address(vault), address(asset), VAULT_TYPE_ERC20, address(strategy), RISK_LOW, METADATA_V1
        );
        vRegistry.registerVaultWithStrategy(address(vault), VAULT_TYPE_ERC20, RISK_LOW, METADATA_V1, address(strategy));
        vm.stopPrank();

        assertEq(vRegistry.getVault(address(vault)).asset, address(asset));
        assertEq(vRegistry.getVault(address(vault)).strategy, address(strategy));
        assertTrue(vRegistry.isRegistered(address(vault)));
    }

    function test_Register_StrategyAssetMismatchReverted() public {
        // Strategy bound to OUR vault but reporting a different asset.
        address otherToken = makeAddr("otherToken");
        MisboundStrategy misbound = new MisboundStrategy(address(vault), IERC20(otherToken));

        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultRegistry.VaultRegistryStrategyAssetMismatch.selector, address(misbound), address(asset), otherToken
            )
        );
        vRegistry.registerVaultWithStrategy(address(vault), VAULT_TYPE_ERC20, RISK_LOW, METADATA_V1, address(misbound));
    }

    function test_UpdateStrategy_WithSecondBoundStrategy() public {
        vm.startPrank(owner_);
        vRegistry.registerVault(address(vault), VAULT_TYPE_ERC20, RISK_LOW, METADATA_V1);
        IdleStrategy strategy2 = new IdleStrategy(address(vault), asset, type(uint256).max);
        vRegistry.updateStrategy(address(vault), address(strategy2));
        vm.stopPrank();

        assertEq(vRegistry.getVault(address(vault)).strategy, address(strategy2));
    }

    function test_Unauthorized_RegisterReverted() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vRegistry.registerVault(address(vault), VAULT_TYPE_ERC20, RISK_LOW, METADATA_V1);
        assertFalse(vRegistry.isRegistered(address(vault)));
    }
}

/// @notice Metadata extension suite for the Phase-1 {StrategyRegistry}.
contract StrategyRegistryMetadataTest is Test {
    StrategyRegistry internal sRegistry;
    AscendVaultHype internal vault;
    HypeIdleStrategy internal strategy;

    address internal owner_ = makeAddr("metaOwner");
    address internal alice = makeAddr("metaAlice");

    function setUp() public {
        vault = new AscendVaultHype("AscendMM HYPE Vault", "asHYPEV", owner_);
        strategy = new HypeIdleStrategy(address(vault), type(uint256).max);
        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(strategy)));
        sRegistry = new StrategyRegistry(owner_);
    }

    function test_Registration_DefaultsRiskLowAndVersionV1() public {
        vm.prank(owner_);
        sRegistry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        StrategyRegistry.Entry memory e = sRegistry.getStrategy(address(strategy));
        assertEq(e.riskClass, RISK_LOW);
        assertEq(e.version, bytes32("V1"));
    }

    function test_SetRiskClass_TransitionsAndValidation() public {
        vm.startPrank(owner_);
        sRegistry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        vm.expectEmit(true, true, false, true, address(sRegistry));
        emit StrategyRegistry.StrategyRiskUpdated(address(strategy), RISK_LOW, RISK_HIGH);
        sRegistry.setRiskClass(address(strategy), RISK_HIGH);
        assertEq(sRegistry.getStrategy(address(strategy)).riskClass, RISK_HIGH);

        // Invalid bucket.
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryInvalidRiskClass.selector, bytes32("NOT_A_BUCKET"))
        );
        sRegistry.setRiskClass(address(strategy), bytes32("NOT_A_BUCKET"));
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyRegistryInvalidRiskClass.selector, bytes32(0)));
        sRegistry.setRiskClass(address(strategy), bytes32(0));

        // Same-value transition.
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistrySameRisk.selector, address(strategy), RISK_HIGH)
        );
        sRegistry.setRiskClass(address(strategy), RISK_HIGH);

        // Unregistered strategy.
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyRegistryNotRegistered.selector, alice));
        sRegistry.setRiskClass(alice, RISK_LOW);
        vm.stopPrank();
    }

    function test_SetVersion_TransitionsAndValidation() public {
        vm.startPrank(owner_);
        sRegistry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        vm.expectEmit(true, true, false, true, address(sRegistry));
        emit StrategyRegistry.StrategyVersionUpdated(address(strategy), bytes32("V1"), bytes32("V2"));
        sRegistry.setVersion(address(strategy), bytes32("V2"));
        assertEq(sRegistry.getStrategy(address(strategy)).version, bytes32("V2"));

        // Zero version.
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryStrategyTypeEmpty.selector, address(strategy))
        );
        sRegistry.setVersion(address(strategy), bytes32(0));

        // Same version.
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyRegistry.StrategyRegistrySameVersion.selector, address(strategy), bytes32("V2")
            )
        );
        sRegistry.setVersion(address(strategy), bytes32("V2"));

        // Unregistered strategy.
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyRegistryNotRegistered.selector, alice));
        sRegistry.setVersion(alice, bytes32("V9"));
        vm.stopPrank();
    }

    function test_Unauthorized_MetadataAdminReverted() public {
        vm.startPrank(owner_);
        sRegistry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        sRegistry.setRiskClass(address(strategy), RISK_HIGH);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        sRegistry.setVersion(address(strategy), bytes32("V2"));
        vm.stopPrank();

        assertEq(sRegistry.getStrategy(address(strategy)).riskClass, RISK_LOW);
        assertEq(sRegistry.getStrategy(address(strategy)).version, bytes32("V1"));
    }
}
