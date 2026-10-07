// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AscendVault} from "../src/AscendVault.sol";
import {AscendVaultGuarded} from "../src/AscendVaultGuarded.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {StingyDivestStrategy} from "./mocks/EvilStrategies.sol";

/// @title AscendVaultGuardedTest
/// @notice Phase 2G risk + capital controls for the ERC-20 track: vault
///         capacity cap, deposits pause, and the loss-aware emergency
///         strategy exit / abandon path.
contract AscendVaultGuardedTest is Test {
    AscendVaultGuarded internal vault;
    MockERC20 internal asset;
    MockStrategy internal strategyMock;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant AMOUNT = 100e18;

    function setUp() public {
        asset = new MockERC20("AscendMM Test Asset", "asMMT", 18);
        vault = new AscendVaultGuarded(IERC20(address(asset)), "AscendMM Vault Guarded", "asMMVG", owner);
        asset.mint(alice, 1_000_000e18);
        asset.mint(bob, 1_000_000e18);
        asset.mint(carol, 1_000_000e18);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deposit(address to, uint256 amount) internal {
        vm.startPrank(to);
        asset.approve(address(vault), amount);
        vault.deposit(amount, to);
        vm.stopPrank();
    }

    function _bind(address strategyAddress) internal {
        vm.prank(owner);
        vault.setStrategy(IStrategy(strategyAddress));
    }

    function _invest(uint256 amount) internal {
        vm.prank(owner);
        vault.investIdle(amount);
    }

    // ------------------------------------------------------------------
    // Cap: defaults, setting, events
    // ------------------------------------------------------------------

    function test_Cap_DefaultIsUnbounded() public view {
        assertEq(vault.totalAssetCap(), 0, "fresh vault must be explicitly unbounded");
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
        assertEq(vault.depositsPaused(), false);
    }

    function test_Cap_OwnerSetsAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit AscendVaultGuarded.VaultCapUpdated(0, 150e18);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);
        assertEq(vault.totalAssetCap(), 150e18);
    }

    function test_Cap_ZeroIsExplicitUnbounded() public {
        vm.startPrank(owner);
        vault.setTotalAssetCap(150e18);
        vm.expectEmit(false, false, false, true, address(vault));
        emit AscendVaultGuarded.VaultCapUpdated(150e18, 0);
        vault.setTotalAssetCap(0);
        vm.stopPrank();

        assertEq(vault.totalAssetCap(), 0);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        _deposit(bob, 500e18); // far beyond the old cap
        assertEq(vault.totalAssets(), 500e18);
    }

    function test_Cap_NonOwnerCannotSet() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setTotalAssetCap(150e18);
    }

    function test_Cap_SetBelowTotalAssetsReverts() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVaultGuarded.CapBelowTotalAssets.selector, 99e18, AMOUNT));
        vault.setTotalAssetCap(99e18);
    }

    // ------------------------------------------------------------------
    // Cap: deposit / mint enforcement
    // ------------------------------------------------------------------

    function test_Cap_DepositWithinHeadroom() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);

        _deposit(bob, 40e18);
        assertEq(vault.totalAssets(), 140e18);
        assertEq(vault.maxDeposit(carol), 10e18);
    }

    function test_Cap_DepositAtExactCap() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);

        _deposit(bob, 50e18); // exactly fills the cap
        assertEq(vault.totalAssets(), 150e18);
        assertEq(vault.maxDeposit(carol), 0);
    }

    function test_Cap_DepositOverCapReverts() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);
        _deposit(bob, 50e18); // at cap

        vm.startPrank(carol);
        asset.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, carol, 1e18, 0));
        vault.deposit(1e18, carol);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 150e18);
    }

    function test_Cap_MintWithinHeadroom() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);

        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        uint256 assetsIn = vault.mint(30e18, bob); // 1:1 rate on equal deposits
        vm.stopPrank();
        assertEq(assetsIn, 30e18);
        assertEq(vault.totalAssets(), 130e18);
    }

    function test_Cap_MintOverCapReverts() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);
        _deposit(bob, 50e18); // at cap

        vm.startPrank(carol);
        asset.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, carol, 1e18, 0));
        vault.mint(1e18, carol);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 150e18);
    }

    function test_Cap_RaiseReopensDeposits() public {
        _deposit(alice, AMOUNT);
        vm.startPrank(owner);
        vault.setTotalAssetCap(150e18);
        vault.setTotalAssetCap(200e18);
        vm.stopPrank();

        _deposit(bob, 50e18); // would exceed the 150 cap, fits under 200
        assertEq(vault.totalAssets(), 150e18);
    }

    function test_Cap_AtCapAllowsWithdrawals() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(AMOUNT); // cap == current totals: allowed

        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(alice);
        vault.withdraw(60e18, alice, alice); // withdrawals unaffected
        assertEq(vault.totalAssets(), 40e18);

        // Freed headroom reopens deposits.
        assertEq(vault.maxDeposit(bob), 60e18);
        _deposit(bob, 60e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_Cap_InvestIdleCannotBypassCap() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(AMOUNT);
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        _bind(address(strategyMock));
        _invest(60e18); // relocates idle -> ledger; total unchanged

        assertEq(vault.totalAssets(), AMOUNT, "investIdle must not change total assets");
        assertEq(vault.maxDeposit(bob), 0, "cap must still bind after investIdle");
        vm.startPrank(bob);
        asset.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1e18, 0));
        vault.deposit(1e18, bob);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Deposits pause
    // ------------------------------------------------------------------

    function test_Pause_BlocksDepositAndMint() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultGuarded.DepositsPausedUpdated(true);
        vm.prank(owner);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());

        vm.startPrank(alice);
        asset.approve(address(vault), 1e18);
        vm.expectRevert(AscendVaultGuarded.DepositsPaused.selector);
        vault.deposit(1e18, alice);
        vm.expectRevert(AscendVaultGuarded.DepositsPaused.selector);
        vault.mint(1e18, alice);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 0);
    }

    function test_Pause_UnpauseRestoresDeposits() public {
        vm.startPrank(owner);
        vault.setDepositsPaused(true);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultGuarded.DepositsPausedUpdated(false);
        vault.setDepositsPaused(false);
        vm.stopPrank();

        assertFalse(vault.depositsPaused());
        _deposit(alice, AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Pause_WithdrawalsStillWork() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setDepositsPaused(true);

        vm.prank(alice);
        vault.withdraw(60e18, alice, alice);
        assertEq(vault.totalAssets(), 40e18);
        assertEq(asset.balanceOf(alice), 1_000_000e18 - AMOUNT + 60e18);
    }

    function test_Pause_StrategyTapStillWorks() public {
        _deposit(alice, AMOUNT);
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        _bind(address(strategyMock));
        _invest(60e18); // idle 40, ledger 60

        vm.prank(owner);
        vault.setDepositsPaused(true);

        vm.prank(alice);
        vault.withdraw(80e18, alice, alice); // taps strategy for 40 via shortfall path
        assertEq(vault.totalAssets(), 20e18);
        assertEq(vault.strategyInvested(), 20e18);
    }

    function test_Pause_InvestIdleStillWorks() public {
        _deposit(alice, AMOUNT);
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        _bind(address(strategyMock));

        vm.prank(owner);
        vault.setDepositsPaused(true);

        _invest(60e18); // explicitly preserved during a deposit freeze
        assertEq(vault.strategyInvested(), 60e18);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Pause_NonOwnerCannotSet() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setDepositsPaused(true);
        assertFalse(vault.depositsPaused());
    }

    // ------------------------------------------------------------------
    // Emergency exit (loss-aware)
    // ------------------------------------------------------------------

    function test_Emergency_NoStrategyReverts() public {
        vm.prank(owner);
        vm.expectRevert(AscendVault.NoStrategySet.selector);
        vault.emergencyExitStrategy();

        vm.prank(owner);
        vm.expectRevert(AscendVault.NoStrategySet.selector);
        vault.abandonStrategy();
    }

    function test_Emergency_NothingInvestedReverts() public {
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        _bind(address(strategyMock));

        vm.prank(owner);
        vm.expectRevert(AscendVaultGuarded.NothingInvested.selector);
        vault.emergencyExitStrategy();

        vm.prank(owner);
        vm.expectRevert(AscendVaultGuarded.NothingInvested.selector);
        vault.abandonStrategy();
    }

    function test_Emergency_FullSettleEventAndAccounting() public {
        _deposit(alice, AMOUNT);
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        _bind(address(strategyMock));
        _invest(60e18);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultGuarded.StrategyForfeited(address(strategyMock), 60e18, 0);
        vm.prank(owner);
        vault.emergencyExitStrategy();

        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), AMOUNT, "full settle must preserve totals");
        assertEq(asset.balanceOf(address(strategyMock)), 0);
    }

    function test_Emergency_PartialSettleKeepsLedgerHonest() public {
        _deposit(alice, AMOUNT);
        StingyDivestStrategy stingy = new StingyDivestStrategy(address(vault), IERC20(address(asset)));
        _bind(address(stingy));
        _invest(60e18);

        // The strict base exit refuses to under-settle: whole op reverts.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.DivestShortfall.selector, 60e18, 30e18));
        vault.exitStrategy();

        // The emergency exit accepts reality: 30 returned, 30 still owed.
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultGuarded.StrategyForfeited(address(stingy), 30e18, 30e18);
        vm.prank(owner);
        vault.emergencyExitStrategy();

        assertEq(vault.strategyInvested(), 30e18, "unreturned remainder stays ledgered");
        assertEq(vault.totalAssets(), AMOUNT, "still-owed capital keeps pricing honest");
        assertEq(vault.strategy(), address(stingy));
    }

    function test_Emergency_RepeatedSqueezeThenAbandon() public {
        _deposit(alice, AMOUNT);
        StingyDivestStrategy stingy = new StingyDivestStrategy(address(vault), IERC20(address(asset)));
        _bind(address(stingy));
        _invest(60e18);

        vm.prank(owner);
        vault.emergencyExitStrategy(); // settles 30, ledger 30
        vm.prank(owner);
        vault.emergencyExitStrategy(); // settles 15 more (halves again), ledger 15

        assertEq(vault.strategyInvested(), 15e18);
        assertEq(vault.totalAssets(), AMOUNT);

        // Give up on the remainder: explicit full write-off of what is left.
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultGuarded.StrategyForfeited(address(stingy), 0, 15e18);
        vm.prank(owner);
        vault.abandonStrategy();

        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), 85e18, "abandon realizes the remaining 15 as loss");
        assertEq(asset.balanceOf(address(stingy)), 15e18, "strategy keeps its leftover tokens");
    }

    function test_Emergency_AbandonDirectFullLoss() public {
        _deposit(alice, AMOUNT);
        StingyDivestStrategy stingy = new StingyDivestStrategy(address(vault), IERC20(address(asset)));
        _bind(address(stingy));
        _invest(60e18);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultGuarded.StrategyForfeited(address(stingy), 0, 60e18);
        vm.prank(owner);
        vault.abandonStrategy();

        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), 40e18);
    }

    function test_Emergency_NonOwnerReverts() public {
        _deposit(alice, AMOUNT);
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        _bind(address(strategyMock));
        _invest(60e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.emergencyExitStrategy();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.abandonStrategy();
    }

    function test_Pause_EmergencyExitAllowedWhilePaused() public {
        _deposit(alice, AMOUNT);
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        _bind(address(strategyMock));
        _invest(60e18);

        vm.startPrank(owner);
        vault.setDepositsPaused(true);
        vault.emergencyExitStrategy(); // emergency action, not a deposit
        vm.stopPrank();

        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // Migration invariants around the emergency path
    // ------------------------------------------------------------------

    function test_Emergency_RebindAfterFullSettle() public {
        _deposit(alice, AMOUNT);
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        _bind(address(strategyMock));
        _invest(60e18);

        vm.prank(owner);
        vault.emergencyExitStrategy();

        // Ledger is zero: rebinding is immediately possible.
        MockStrategy fresh = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(fresh)));
        assertEq(vault.strategy(), address(fresh));

        _invest(30e18); // new strategy lifecycle works
        assertEq(vault.strategyInvested(), 30e18);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Migration_StillBlockedWhileLedgerNonzero() public {
        _deposit(alice, AMOUNT);
        StingyDivestStrategy stingy = new StingyDivestStrategy(address(vault), IERC20(address(asset)));
        _bind(address(stingy));
        _invest(60e18);

        vm.prank(owner);
        vault.emergencyExitStrategy(); // partial: ledger 30 remains

        MockStrategy fresh = new MockStrategy(address(vault), IERC20(address(asset)), type(uint256).max);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.StrategyStillInvested.selector, address(stingy), 30e18));
        vault.setStrategy(IStrategy(address(fresh)));
    }

    // ------------------------------------------------------------------
    // Guarded vault still behaves like the base vault
    // ------------------------------------------------------------------

    function test_Guarded_NormalLifecycleUnchanged() public {
        _deposit(alice, AMOUNT);
        _deposit(bob, AMOUNT);
        vm.prank(alice);
        vault.redeem(AMOUNT, alice, alice);
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(vault.balanceOf(bob), AMOUNT);
    }

    function test_Guarded_DepositThenFullWithdrawRoundTrip() public {
        _deposit(alice, 999_999e18);
        vm.prank(alice);
        vault.redeem(999_999e18, alice, alice);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(asset.balanceOf(alice), 1_000_000e18, "zero-fee chain must be dustless");
    }
}
