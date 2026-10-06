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
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {HypeIdleStrategy} from "../src/strategies/HypeIdleStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MisboundStrategy} from "./mocks/MockStrategy.sol";
import {MisboundHypeStrategy} from "./mocks/EvilHypeStrategies.sol";

/// @dev Registry-entry type identifiers shared by the registry suites.
bytes32 constant IDLE_TYPE = keccak256("ASCEND_IDLE_V1");
bytes32 constant OTHER_TYPE = keccak256("ASCEND_REAL_YIELD_V1");

/// @notice Integration suite: {StrategyRegistry} x {AscendVault} +
///         {IdleStrategy} (ERC-20 track). Proves registration validation,
///         duplicate/invalid rejection, lifecycle, and that the registry is
///         pure bookkeeping — the vault's own strategy flow is untouched.
contract StrategyRegistryErc20Test is Test {
    StrategyRegistry internal registry;
    AscendVault internal vault;
    IdleStrategy internal strategy;
    MockERC20 internal asset;

    address internal owner_ = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        asset = new MockERC20("Mock HYPE", "MHYPE", 18);
        vault = new AscendVault(IERC20(address(asset)), "AscendMM Vault", "asMMT", owner_);
        strategy = new IdleStrategy(address(vault), asset, type(uint256).max);
        vm.prank(owner_);
        vault.setStrategy(IStrategy(address(strategy)));
        registry = new StrategyRegistry(owner_);
    }

    // ------------------------------------------------------------------
    // Valid registration
    // ------------------------------------------------------------------

    function test_Register_ValidErc20Strategy() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit StrategyRegistry.StrategyRegistered(
            address(strategy), address(vault), address(asset), IDLE_TYPE, "Idle ERC-20 custody"
        );
        vm.prank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE, "Idle ERC-20 custody");

        assertTrue(registry.isRegistered(address(strategy)));
        StrategyRegistry.Entry memory entry = registry.getStrategy(address(strategy));
        assertEq(entry.strategy, address(strategy));
        assertEq(entry.vault, address(vault));
        assertEq(entry.asset, address(asset));
        assertTrue(entry.active);
        assertEq(entry.strategyType, IDLE_TYPE);
        assertEq(entry.label, "Idle ERC-20 custody");
        assertEq(registry.strategyCount(), 1);
    }

    function test_Register_TwoParamVariant_ActiveEntry() public {
        vm.prank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        assertTrue(registry.isRegistered(address(strategy)));
        assertTrue(registry.isActive(address(strategy)));
        assertEq(registry.getStrategy(address(strategy)).label, "");
    }

    function test_Register_AllViewsConsistent() public {
        vm.prank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        address[] memory all = registry.allStrategies();
        assertEq(all.length, 1);
        assertEq(all[0], address(strategy));
        assertEq(registry.strategyCount(), 1);
    }

    // ------------------------------------------------------------------
    // Duplicate / invalid rejection
    // ------------------------------------------------------------------

    function test_Register_DuplicateReverted() public {
        vm.startPrank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryAlreadyRegistered.selector, address(strategy))
        );
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);
        vm.stopPrank();
    }

    function test_Register_VaultBindingMismatchReverted() public {
        MisboundStrategy misbound = new MisboundStrategy(address(0xdead), IERC20(address(asset)));
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyRegistry.StrategyRegistryVaultMismatch.selector, address(vault), address(0xdead)
            )
        );
        registry.registerStrategy(address(misbound), address(vault), IDLE_TYPE);
    }

    function test_Register_AssetMismatchReverted() public {
        address otherToken = makeAddr("otherToken");
        MisboundStrategy misbound = new MisboundStrategy(address(vault), IERC20(otherToken));
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryAssetMismatch.selector, address(asset), otherToken)
        );
        registry.registerStrategy(address(misbound), address(vault), IDLE_TYPE);
    }

    function test_Register_EoaStrategyReverted() public {
        address eoa = makeAddr("notAContract");
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyRegistryNotContract.selector, eoa));
        registry.registerStrategy(eoa, address(vault), IDLE_TYPE);
    }

    function test_Register_EoaVaultReverted() public {
        address eoa = makeAddr("notAVault");
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyRegistryNotContract.selector, eoa));
        registry.registerStrategy(address(strategy), eoa, IDLE_TYPE);
    }

    function test_Register_ZeroAddressesReverted() public {
        vm.startPrank(owner_);
        vm.expectRevert(StrategyRegistry.StrategyRegistryZeroAddress.selector);
        registry.registerStrategy(address(0), address(vault), IDLE_TYPE);
        vm.expectRevert(StrategyRegistry.StrategyRegistryZeroAddress.selector);
        registry.registerStrategy(address(strategy), address(0), IDLE_TYPE);
        vm.stopPrank();
    }

    function test_Register_EmptyTypeReverted() public {
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryStrategyTypeEmpty.selector, address(strategy))
        );
        registry.registerStrategy(address(strategy), address(vault), bytes32(0));
    }

    function test_Register_CrossTrackCombinationReverted() public {
        // Invalid strategy/vault/asset combination: an ERC-20 strategy bound
        // to the ERC-20 vault cannot be registered against a native-HYPE
        // vault. The binding check rejects it first (the strategy reports
        // the ERC-20 vault, not the native one); the asset equality check
        // would reject it too (token vs ERC-7528 sentinel).
        AscendVaultHype hypeVault = new AscendVaultHype("H", "asHYPEV", owner_);
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyRegistry.StrategyRegistryVaultMismatch.selector, address(hypeVault), address(vault)
            )
        );
        registry.registerStrategy(address(strategy), address(hypeVault), IDLE_TYPE);
    }

    function test_Register_NativeVaultAndStrategyAcceptedByUnifiedPath() public {
        // The unified path registers native-track pairs too: both vault and
        // strategy report the ERC-7528 sentinel as their asset.
        AscendVaultHype hypeVault = new AscendVaultHype("H", "asHYPEV", owner_);
        HypeIdleStrategy hypeStrategy = new HypeIdleStrategy(address(hypeVault), type(uint256).max);

        vm.prank(owner_);
        registry.registerStrategy(address(hypeStrategy), address(hypeVault), IDLE_TYPE, "native");

        assertTrue(registry.isRegistered(address(hypeStrategy)));
        assertEq(registry.getStrategy(address(hypeStrategy)).asset, hypeVault.NATIVE_ASSET_SENTINEL());
        assertTrue(registry.isActive(address(hypeStrategy)));
        assertEq(registry.strategyCount(), 1);
    }

    // ------------------------------------------------------------------
    // Activation / deactivation
    // ------------------------------------------------------------------

    function test_SetActive_ToggleLifecycle() public {
        vm.startPrank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        vm.expectEmit(true, false, false, true, address(registry));
        emit StrategyRegistry.StrategyDeactivated(address(strategy));
        registry.setActive(address(strategy), false);
        assertFalse(registry.isActive(address(strategy)));
        // Registered but paused.
        assertTrue(registry.isRegistered(address(strategy)));

        vm.expectEmit(true, false, false, true, address(registry));
        emit StrategyRegistry.StrategyActivated(address(strategy));
        registry.setActive(address(strategy), true);
        assertTrue(registry.isActive(address(strategy)));
        vm.stopPrank();
    }

    function test_SetActive_IdempotenceReverted() public {
        vm.startPrank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryAlreadyActive.selector, address(strategy))
        );
        registry.setActive(address(strategy), true);

        registry.setActive(address(strategy), false);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryAlreadyPaused.selector, address(strategy))
        );
        registry.setActive(address(strategy), false);
        vm.stopPrank();
    }

    function test_SetActive_UnregisteredReverted() public {
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryNotRegistered.selector, address(strategy))
        );
        registry.setActive(address(strategy), false);
    }

    function test_SetType_UpdateAndValidation() public {
        vm.startPrank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        vm.expectEmit(true, true, true, false, address(registry));
        emit StrategyRegistry.StrategyTypeUpdated(address(strategy), IDLE_TYPE, OTHER_TYPE);
        registry.setType(address(strategy), OTHER_TYPE);
        assertEq(registry.getStrategy(address(strategy)).strategyType, OTHER_TYPE);

        // Guard rails: zero and same-value types.
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryStrategyTypeEmpty.selector, address(strategy))
        );
        registry.setType(address(strategy), bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistrySameType.selector, address(strategy), OTHER_TYPE)
        );
        registry.setType(address(strategy), OTHER_TYPE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Removal
    // ------------------------------------------------------------------

    function test_RemoveStrategy_RemovesEntryAndUnregisters() public {
        vm.startPrank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);

        vm.expectEmit(true, false, false, true, address(registry));
        emit StrategyRegistry.StrategyRemoved(address(strategy), address(vault), address(asset));
        registry.removeStrategy(address(strategy));
        vm.stopPrank();

        assertFalse(registry.isRegistered(address(strategy)));
        assertFalse(registry.isActive(address(strategy)));
        StrategyRegistry.Entry memory entry = registry.getStrategy(address(strategy));
        assertEq(entry.strategy, address(0));
        assertEq(entry.vault, address(0));
        assertEq(entry.asset, address(0));
        assertEq(registry.strategyCount(), 0);
        assertEq(registry.allStrategies().length, 0);

        // Fresh entry after removal.
        vm.prank(owner_);
        registry.registerStrategy(address(strategy), address(vault), OTHER_TYPE);
        assertTrue(registry.isRegistered(address(strategy)));
        assertEq(registry.strategyCount(), 1);
    }

    function test_RemoveStrategy_UnregisteredReverted() public {
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryNotRegistered.selector, address(strategy))
        );
        registry.removeStrategy(address(strategy));
    }

    function test_RemoveStrategy_ListIntegrityAfterTailSwap() public {
        IdleStrategy s2 = new IdleStrategy(address(vault), asset, type(uint256).max);
        IdleStrategy s3 = new IdleStrategy(address(vault), asset, type(uint256).max);

        vm.startPrank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE, "first");
        registry.registerStrategy(address(s2), address(vault), IDLE_TYPE, "second");
        registry.registerStrategy(address(s3), address(vault), IDLE_TYPE, "third");

        // Removing the FIRST entry swaps the tail in.
        registry.removeStrategy(address(strategy));
        address[] memory all = registry.allStrategies();
        assertEq(all.length, 2);
        assertFalse(all[0] == address(strategy));
        assertTrue(all[0] == address(s3));
        assertTrue(all[1] == address(s2));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Unauthorized administration
    // ------------------------------------------------------------------

    function test_Unauthorized_NonOwnerCannotAdminister() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setActive(address(strategy), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setType(address(strategy), OTHER_TYPE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.removeStrategy(address(strategy));
        vm.stopPrank();

        assertEq(registry.strategyCount(), 0);
    }

    // ------------------------------------------------------------------
    // Registry is pure bookkeeping: vault flow untouched
    // ------------------------------------------------------------------

    function test_RegistryDoesNotAffectVaultStrategyFlow() public {
        uint256 AMOUNT = 1_000e18;
        asset.mint(alice, AMOUNT);

        vm.startPrank(alice);
        asset.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets(), AMOUNT);

        // Registration happens: nothing moves in the vault.
        vm.prank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE);
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(asset.balanceOf(address(vault)), AMOUNT);
        assertEq(vault.strategyInvested(), 0);

        // The vault's own owner-driven flow works exactly as before.
        vm.startPrank(owner_);
        vault.investIdle(AMOUNT);
        assertEq(vault.strategyInvested(), AMOUNT);
        vault.exitStrategy();
        assertEq(vault.strategyInvested(), 0);
        vm.stopPrank();
        assertEq(vault.totalAssets(), AMOUNT);

        // Deactivating in the registry does not block the vault's own flow.
        vm.prank(owner_);
        registry.setActive(address(strategy), false);
        vm.prank(owner_);
        vault.investIdle(AMOUNT);
        assertEq(vault.strategyInvested(), AMOUNT);
    }
}

/// @notice Registry suite for the native-HYPE track: {StrategyRegistry} x
///         {AscendVaultHype} + {HypeIdleStrategy} via the unified
///         {registerStrategy} path (native vault + strategy both report the
///         ERC-7528 sentinel as their asset).
contract StrategyRegistryHypeTest is Test {
    StrategyRegistry internal registry;
    AscendVaultHype internal vault;
    HypeIdleStrategy internal strategy;

    address internal owner_ = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vault = new AscendVaultHype("AscendMM HYPE Vault", "asHYPEV", owner_);
        strategy = new HypeIdleStrategy(address(vault), type(uint256).max);
        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(strategy)));
        registry = new StrategyRegistry(owner_);
    }

    function test_RegisterNative_ValidStrategy() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit StrategyRegistry.StrategyRegistered(
            address(strategy), address(vault), vault.NATIVE_ASSET_SENTINEL(), IDLE_TYPE, "Idle HYPE custody"
        );
        vm.prank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE, "Idle HYPE custody");

        StrategyRegistry.Entry memory entry = registry.getStrategy(address(strategy));
        assertEq(entry.strategy, address(strategy));
        assertEq(entry.vault, address(vault));
        assertEq(entry.asset, vault.NATIVE_ASSET_SENTINEL());
        assertTrue(entry.active);
        assertEq(registry.strategyCount(), 1);
    }

    function test_RegisterNative_DuplicateReverted() public {
        vm.startPrank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE, "");
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryAlreadyRegistered.selector, address(strategy))
        );
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE, "");
        vm.stopPrank();
    }

    function test_RegisterNative_VaultBindingMismatchReverted() public {
        MisboundHypeStrategy misbound = new MisboundHypeStrategy(address(0xdead), address(0xdead));
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyRegistry.StrategyRegistryVaultMismatch.selector, address(vault), address(0xdead)
            )
        );
        registry.registerStrategy(address(misbound), address(vault), IDLE_TYPE, "");
    }

    function test_RegisterNative_NonSentinelAssetReverted() public {
        // Compute external values BEFORE vm.prank: the sentinel getter and
        // the mock constructor are external calls from this contract, so
        // evaluating them inside the expectRevert arguments would consume
        // the prank (known Foundry gotcha).
        address sentinel = vault.NATIVE_ASSET_SENTINEL();
        address wrongAsset = makeAddr("erc20");
        MisboundHypeStrategy misbound = new MisboundHypeStrategy(address(vault), wrongAsset);
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRegistry.StrategyRegistryAssetMismatch.selector, sentinel, wrongAsset)
        );
        registry.registerStrategy(address(misbound), address(vault), IDLE_TYPE, "");
    }

    function test_RegisterNative_EoaVaultReverted() public {
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyRegistryNotContract.selector, alice));
        registry.registerStrategy(address(strategy), alice, IDLE_TYPE, "");
    }

    function test_RegisterNative_LifecycleAndRemoval() public {
        vm.startPrank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE, "");

        registry.setActive(address(strategy), false);
        assertFalse(registry.isActive(address(strategy)));
        registry.setActive(address(strategy), true);
        assertTrue(registry.isActive(address(strategy)));
        registry.removeStrategy(address(strategy));
        vm.stopPrank();

        assertFalse(registry.isRegistered(address(strategy)));
        assertEq(registry.strategyCount(), 0);
    }

    function test_RegistryDoesNotAffectHypeVaultMigrationFlow() public {
        uint256 AMOUNT = 10e18;

        // The registry records the deployed binding (bookkeeping only).
        vm.prank(owner_);
        registry.registerStrategy(address(strategy), address(vault), IDLE_TYPE, "");

        deal(alice, AMOUNT);
        vm.prank(alice);
        vault.deposit{value: AMOUNT}(AMOUNT, alice);
        vm.startPrank(owner_);
        vault.investIdle(AMOUNT);
        assertEq(vault.strategyInvested(), AMOUNT);

        // The migration flow `exitStrategy → setStrategy → investIdle`
        // works with the registry present, exactly as before.
        HypeIdleStrategy fresh = new HypeIdleStrategy(address(vault), type(uint256).max);
        vault.exitStrategy();
        vault.setStrategy(IHypeStrategy(address(fresh)));
        vault.investIdle(AMOUNT);
        vm.stopPrank();

        assertEq(address(vault.strategy()), address(fresh));
        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(address(strategy).balance, 0);
        assertEq(address(fresh).balance, AMOUNT);

        // Registry still describes the (now unbound) old strategy; the
        // registry does not mutate itself or the vault.
        assertTrue(registry.isRegistered(address(strategy)));
        assertEq(address(registry.getStrategy(address(strategy)).vault), address(vault));
    }
}

/// @notice Unit tests pinning {HypeIdleStrategy} compliance with the unified
///         {IStrategy} surface (the two interface functions the deployed
///         contract gained in the modular-strategy phase).
contract HypeIdleStrategyIStrategyTest is Test {
    AscendVaultHype internal vault;
    HypeIdleStrategy internal strategy;
    address internal owner_ = makeAddr("owner");
    address internal alice = makeAddr("alice");

    /// @dev Accept native value: some tests below act as the strategy's
    ///      bound vault, which pushes value back on divestAll.
    receive() external payable {}

    function setUp() public {
        vault = new AscendVaultHype("AscendMM HYPE Vault", "asHYPEV", owner_);
        strategy = new HypeIdleStrategy(address(vault), type(uint256).max);
        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(strategy)));
    }

    function test_IStrategy_InterfaceComplianceViaIStrategyType() public view {
        // The native idle strategy IS an IStrategy.
        IStrategy s = IStrategy(address(strategy));
        assertEq(s.vault(), address(vault));
        assertEq(s.asset(), 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        assertEq(s.cap(), type(uint256).max);
        assertEq(s.totalAssets(), 0);
    }

    function test_DivestAll_PushesEntireBalanceToVault() public {
        // Direct behavioral test with a gate-free custodian (this test
        // contract as the bound vault): divestAll pushes the ENTIRE native
        // balance to msg.sender.
        HypeIdleStrategy custodial = new HypeIdleStrategy(address(this), type(uint256).max);
        uint256 held = 4e18;
        deal(address(custodial), held);
        assertEq(custodial.totalAssets(), held);

        // Foundry test contracts start with a large default balance, so
        // assert on the DELTA, not the absolute balance.
        uint256 before = address(this).balance;

        vm.expectEmit(false, false, false, true, address(custodial));
        emit IStrategy.Divested(held);
        custodial.divestAll();

        assertEq(address(custodial).balance, 0);
        assertEq(address(this).balance - before, held);
    }

    function test_DivestAll_ZeroBalanceIsIdempotentNoOp() public {
        HypeIdleStrategy custodial = new HypeIdleStrategy(address(this), type(uint256).max);

        vm.expectEmit(false, false, false, true, address(custodial));
        emit IStrategy.Divested(0);
        custodial.divestAll();

        assertEq(address(custodial).balance, 0);
    }

    function test_DivestAll_OnLiveVault_RespectsVaultReceiveGate() public {
        // Security pin: with funds invested, a DIRECT divestAll from the
        // vault is correctly rejected — the deployed vault accepts native
        // value only while its own divest flow has the receive() gate open,
        // so an unsolicited strategy push reverts (HypeTransferFailed) and
        // the funds stay in the strategy.
        uint256 AMOUNT = 5e18;
        deal(address(this), AMOUNT);
        vault.deposit{value: AMOUNT}(AMOUNT, address(this));
        vm.prank(owner_);
        vault.investIdle(AMOUNT);
        assertEq(address(strategy).balance, AMOUNT);

        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(HypeIdleStrategy.HypeTransferFailed.selector, AMOUNT));
        strategy.divestAll();

        // Nothing moved.
        assertEq(address(strategy).balance, AMOUNT);
        assertEq(vault.strategyInvested(), AMOUNT);
    }

    function test_VaultExitFlow_ReturnsFullInvestment() public {
        uint256 AMOUNT = 5e18;
        deal(address(this), AMOUNT);
        vault.deposit{value: AMOUNT}(AMOUNT, address(this));
        vm.prank(owner_);
        vault.investIdle(AMOUNT);
        assertEq(address(strategy).balance, AMOUNT);

        uint256 vaultBefore = address(vault).balance;
        vm.prank(owner_);
        vault.exitStrategy();

        assertEq(address(vault).balance - vaultBefore, AMOUNT, "full invested amount returned");
        assertEq(address(strategy).balance, 0);
        assertEq(vault.strategyInvested(), 0);
    }

    function test_Harvest_IsVaultOnlyAndFlatNoYield() public {
        // Vault-only.
        vm.expectRevert();
        strategy.harvest();

        uint256 before = address(alice).balance;
        vm.prank(address(vault));
        strategy.harvest();
        // No funds moved anywhere.
        assertEq(address(alice).balance, before);
        assertEq(address(strategy).balance, 0);
        assertEq(address(vault).balance, 0);
    }

    function test_Harvest_DoesNotFabricateYield_AfterRealInvestment() public {
        uint256 AMOUNT = 3e18;
        deal(address(this), AMOUNT);
        vault.deposit{value: AMOUNT}(AMOUNT, address(this));
        vm.prank(owner_);
        vault.investIdle(AMOUNT);
        assertEq(address(strategy).balance, AMOUNT);
        assertEq(strategy.totalAssets(), AMOUNT);

        // Harvest claims nothing: strategy balance is unchanged.
        vm.prank(address(vault));
        strategy.harvest();
        assertEq(address(strategy).balance, AMOUNT, "no yield was fabricated or moved");
        assertEq(vault.totalAssets(), AMOUNT, "vault accounting untouched by harvest");
    }
}
