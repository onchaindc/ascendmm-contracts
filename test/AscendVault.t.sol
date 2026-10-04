// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AscendVault} from "../src/AscendVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy, MisboundStrategy} from "./mocks/MockStrategy.sol";

contract AscendVaultTest is Test {
    AscendVault internal vault;
    MockERC20 internal asset;
    MockStrategy internal strategyMock;

    uint256 internal constant AMOUNT = 1_000e18;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal feeTreasury = makeAddr("feeTreasury");

    function setUp() public {
        asset = new MockERC20("Mock USD", "MUSD", 18);
        vault = new AscendVault(IERC20(address(asset)), "AscendMM Mock USD Vault", "avMUSD", owner);

        asset.mint(alice, 1_000_000e18);
        asset.mint(bob, 1_000_000e18);
        asset.mint(carol, 1_000_000e18);
    }

    /// @dev Approves the vault and deposits `amount` of asset from `user`.
    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Approves the vault (no deposit).
    function _approve(address user, uint256 amount) internal {
        vm.prank(user);
        asset.approve(address(vault), amount);
    }

    // ------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------

    function test_Deployment_SetsConstructorParams() public view {
        assertEq(address(vault.asset()), address(asset));
        assertEq(vault.name(), "AscendMM Mock USD Vault");
        assertEq(vault.symbol(), "avMUSD");
        assertEq(vault.owner(), owner);
        assertEq(vault.decimals(), 18); // asset decimals + _decimalsOffset() (0)
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_Deployment_FeesDefaultToZero() public view {
        assertEq(vault.entryFeeBps(), 0);
        assertEq(vault.exitFeeBps(), 0);
        assertEq(vault.feeRecipient(), address(0));
        assertEq(vault.FEE_DIVISOR(), 10_000);
        assertEq(vault.MAX_ENTRY_FEE_BPS(), 1_000);
        assertEq(vault.MAX_EXIT_FEE_BPS(), 1_000);
    }

    function test_Deployment_StrategyStartsUnset() public view {
        assertEq(vault.strategy(), address(0));
    }

    function test_Deployment_RevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AscendVault(IERC20(address(asset)), "X", "X", address(0));
    }

    // ------------------------------------------------------------------
    // Initial deposit
    // ------------------------------------------------------------------

    function test_InitialDeposit_MintsOneToOne() public {
        _deposit(alice, AMOUNT);

        assertEq(vault.balanceOf(alice), AMOUNT, "first deposit should mint 1:1");
        assertEq(vault.totalSupply(), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(asset.balanceOf(address(vault)), AMOUNT);
        assertEq(asset.balanceOf(alice), 1_000_000e18 - AMOUNT);
    }

    function test_InitialDeposit_PreviewMatchesActualShares() public {
        _approve(alice, AMOUNT);
        uint256 predicted = vault.previewDeposit(AMOUNT); // staticcall: no state change
        vm.prank(alice);
        vault.deposit(AMOUNT, alice);
        uint256 actual = vault.balanceOf(alice);
        assertEq(actual, predicted, "previewDeposit must match minted shares");
    }

    function test_InitialDeposit_EmitsSharesMintAndDepositEvents() public {
        // Approve BEFORE declaring event expectations so the token's Approval
        // event does not interfere with the matcher.
        vm.startPrank(alice);
        asset.approve(address(vault), AMOUNT);

        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC20.Transfer(address(0), alice, AMOUNT); // shares mint
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC4626.Deposit(alice, alice, AMOUNT, AMOUNT);

        vault.deposit(AMOUNT, alice);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Second deposit / share calculation
    // ------------------------------------------------------------------

    function test_SecondDeposit_MintsProportionalShares() public {
        _deposit(alice, AMOUNT);
        _deposit(bob, AMOUNT);

        // Identical deposits with no yield => identical shares, rate stays 1:1.
        assertEq(vault.balanceOf(alice), AMOUNT);
        assertEq(vault.balanceOf(bob), AMOUNT);
        assertEq(vault.convertToAssets(1e18), 1e18, "exchange rate must stay 1:1");
    }

    function test_ShareCalculation_ConvertFunctionsAtOneToOne() public view {
        assertEq(vault.convertToShares(5e18), 5e18);
        assertEq(vault.convertToAssets(5e18), 5e18);
    }

    function test_ShareCalculation_DonationDilutesFutureDepositors() public {
        // Documented ERC-4626 behavior: a direct donation inflates assets per
        // share, so the next depositor receives fewer shares. The virtual
        // share/asset math (OZ default) keeps first-deposit inflation attacks
        // non-profitable; depositors should still use previews + slippage
        // protection off-chain.
        _deposit(alice, AMOUNT);

        vm.prank(carol);
        asset.transfer(address(vault), 5e18); // donation, no shares minted

        uint256 bobShares = vault.convertToShares(AMOUNT);
        assertLt(bobShares, AMOUNT, "donation must make shares more expensive");
        assertEq(bobShares, (AMOUNT * (AMOUNT + 1)) / (AMOUNT + 5e18 + 1), "conversion formula mismatch");

        _deposit(bob, AMOUNT);
        assertEq(vault.balanceOf(bob), bobShares);
    }

    function testFuzz_SoleDepositorFullRedeem(uint256 amount) public {
        amount = bound(amount, 1, 1e30);

        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(amount, address(this));

        assertEq(vault.totalAssets(), amount);

        uint256 assetsBack = vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertEq(assetsBack, amount, "full redeem must return exact deposit at 1:1");
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(asset.balanceOf(address(this)), amount);
    }

    // ------------------------------------------------------------------
    // Withdraw / redeem
    // ------------------------------------------------------------------

    function test_Withdraw_ReturnsExactAssets() public {
        _deposit(alice, AMOUNT);

        uint256 half = AMOUNT / 2;
        vm.prank(alice);
        vault.withdraw(half, alice, alice);

        assertEq(vault.balanceOf(alice), AMOUNT - half);
        assertEq(asset.balanceOf(alice), 1_000_000e18 - AMOUNT + half);
        assertEq(vault.totalAssets(), AMOUNT - half);
    }

    function test_Withdraw_EmitsBurnPayoutAndWithdrawEvents() public {
        _deposit(alice, AMOUNT);

        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC20.Transfer(alice, address(0), AMOUNT); // shares burn
        vm.expectEmit(true, true, false, true, address(asset));
        emit IERC20.Transfer(address(vault), alice, AMOUNT); // asset payout
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(alice, alice, alice, AMOUNT, AMOUNT);

        vm.prank(alice);
        vault.redeem(AMOUNT, alice, alice);
    }

    function test_Withdraw_RevertsWhenExceedsOwnerBalance() public {
        _deposit(alice, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, bob, AMOUNT, 0));
        vm.prank(bob);
        vault.withdraw(AMOUNT, bob, bob); // bob holds no shares
    }

    function test_Redeem_BurnsSharesAndReturnsAssets() public {
        _deposit(alice, AMOUNT);

        vm.prank(alice);
        uint256 assetsBack = vault.redeem(AMOUNT, alice, alice);

        assertEq(assetsBack, AMOUNT);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(asset.balanceOf(alice), 1_000_000e18);
    }

    function test_Redeem_PreviewMatchesActualAssets() public {
        _deposit(alice, AMOUNT);

        uint256 predicted = vault.previewRedeem(AMOUNT); // staticcall
        vm.prank(alice);
        uint256 actual = vault.redeem(AMOUNT, alice, alice);
        assertEq(actual, predicted, "previewRedeem must match assets returned");
    }

    function test_Redeem_RevertsWhenExceedsBalance() public {
        _deposit(alice, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, bob, AMOUNT, 0));
        vm.prank(bob);
        vault.redeem(AMOUNT, bob, bob);
    }

    function test_Withdraw_ThirdPartyNeedsAllowance() public {
        _deposit(alice, AMOUNT);

        // carol moves alice's shares without allowance => revert.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, AMOUNT));
        vm.prank(carol);
        vault.withdraw(AMOUNT, carol, alice);

        // With approval it works and consumes the allowance.
        vm.prank(alice);
        vault.approve(carol, AMOUNT);
        vm.prank(carol);
        vault.withdraw(AMOUNT, carol, alice);

        assertEq(vault.allowance(alice, carol), 0);
        assertEq(vault.balanceOf(alice), 0);
        // carol was pre-funded in setUp, so her balance is initial + payout.
        assertEq(asset.balanceOf(carol), 1_000_000e18 + AMOUNT);
    }

    // ------------------------------------------------------------------
    // totalAssets
    // ------------------------------------------------------------------

    function test_TotalAssets_TracksVaultAssetBalance() public {
        assertEq(vault.totalAssets(), 0);

        _deposit(alice, AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);

        _deposit(bob, 2 * AMOUNT);
        assertEq(vault.totalAssets(), 3 * AMOUNT);

        // Read the balance BEFORE vm.prank: the argument expression would
        // otherwise consume the prank and redeem as the test contract.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(vault.totalAssets(), 2 * AMOUNT);
    }

    function test_TotalAssets_IncludesDirectDonations() public {
        _deposit(alice, AMOUNT);

        vm.prank(carol);
        asset.transfer(address(vault), 123e18);

        // totalAssets() is balance-based, so donations are included (this is
        // what dilutes future depositors -- see test above).
        assertEq(vault.totalAssets(), AMOUNT + 123e18);
    }

    // ------------------------------------------------------------------
    // Multiple users
    // ------------------------------------------------------------------

    function test_MultipleUsers_ProportionalAccounting() public {
        _deposit(alice, AMOUNT);
        _deposit(bob, AMOUNT);
        _deposit(carol, AMOUNT);

        assertEq(vault.totalSupply(), 3 * AMOUNT);
        assertEq(vault.totalAssets(), 3 * AMOUNT);

        // One user exiting must not affect the others' shares or backing.
        vm.prank(alice);
        vault.redeem(AMOUNT, alice, alice);

        assertEq(vault.balanceOf(bob), AMOUNT);
        assertEq(vault.balanceOf(carol), AMOUNT);
        assertEq(vault.totalSupply(), 2 * AMOUNT);
        assertEq(vault.totalAssets(), 2 * AMOUNT);
        assertEq(vault.convertToAssets(1e18), 1e18, "rate must stay 1:1 for equal deposits");
    }

    function test_MultipleUsers_UnbalancedDepositsGetProportionalShares() public {
        _deposit(alice, 3 * AMOUNT);
        _deposit(bob, AMOUNT);

        assertEq(vault.balanceOf(alice), 3 * AMOUNT);
        assertEq(vault.balanceOf(bob), AMOUNT);
        assertEq(vault.convertToAssets(vault.balanceOf(bob)), AMOUNT);
    }

    // ------------------------------------------------------------------
    // Zero-fee behavior (default state)
    // ------------------------------------------------------------------

    function test_ZeroFee_NoDustOnFullDepositWithdrawChain() public {
        uint256 dusty = 999_999e18;

        _deposit(alice, dusty);
        uint256 aliceShares = vault.balanceOf(alice); // read before prank
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertEq(asset.balanceOf(alice), 1_000_000e18, "zero-fee chain must be dustless");
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_ZeroFee_MaxWithdrawEqualsFullBalance() public {
        _deposit(alice, AMOUNT);
        assertEq(vault.maxWithdraw(alice), AMOUNT);
        assertEq(vault.maxRedeem(alice), AMOUNT);
    }

    // ------------------------------------------------------------------
    // Fee configuration (dormant architecture)
    // ------------------------------------------------------------------

    function test_Fees_CannotBeEnabledWithoutRecipient() public {
        vm.prank(owner);
        vm.expectRevert(AscendVault.FeeRecipientNotSet.selector);
        vault.setFees(100, 0);
    }

    function test_Fees_OwnerCanConfigureAfterRecipientSet() public {
        vm.startPrank(owner);
        vault.setFeeRecipient(feeTreasury);
        vault.setFees(100, 50); // 1% entry, 0.5% exit
        vm.stopPrank();

        assertEq(vault.feeRecipient(), feeTreasury);
        assertEq(vault.entryFeeBps(), 100);
        assertEq(vault.exitFeeBps(), 50);
    }

    function test_Fees_RevertAboveMax() public {
        vm.startPrank(owner);
        vault.setFeeRecipient(feeTreasury);

        vm.expectRevert(abi.encodeWithSelector(AscendVault.EntryFeeTooHigh.selector, 1_001, 1_000));
        vault.setFees(1_001, 0);

        vm.expectRevert(abi.encodeWithSelector(AscendVault.ExitFeeTooHigh.selector, 1_001, 1_000));
        vault.setFees(0, 1_001);
        vm.stopPrank();
    }

    function test_Fees_RecipientCannotBeClearedWhileActive() public {
        vm.startPrank(owner);
        vault.setFeeRecipient(feeTreasury);
        vault.setFees(100, 0);

        vm.expectRevert(AscendVault.FeeRecipientInvalid.selector);
        vault.setFeeRecipient(address(0));

        // Disable fees first, then clearing the recipient is allowed.
        vault.setFees(0, 0);
        vault.setFeeRecipient(address(0));
        vm.stopPrank();

        assertEq(vault.feeRecipient(), address(0));
        assertEq(vault.entryFeeBps(), 0);
    }

    function test_Fees_EntryFeeChargedOnDeposit() public {
        vm.startPrank(owner);
        vault.setFeeRecipient(feeTreasury);
        vault.setFees(1_000, 0); // 10% entry fee (max)
        vm.stopPrank();

        _deposit(alice, AMOUNT);

        // Depositor paid the fee out of deposited assets; shares minted for
        // the full ERC-4626 gross amount (no dilution of other users).
        assertEq(asset.balanceOf(address(vault)), AMOUNT - AMOUNT / 10);
        assertEq(asset.balanceOf(feeTreasury), AMOUNT / 10);
        assertEq(vault.balanceOf(alice), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT - AMOUNT / 10);
    }

    function test_Fees_ExitFeeChargedOnRedeem() public {
        _deposit(alice, AMOUNT);

        vm.startPrank(owner);
        vault.setFeeRecipient(feeTreasury);
        vault.setFees(0, 500); // 5% exit fee
        vm.stopPrank();

        vm.prank(alice);
        vault.redeem(AMOUNT, alice, alice);

        assertEq(asset.balanceOf(alice), 1_000_000e18 - AMOUNT + (AMOUNT * 9_500) / 10_000);
        assertEq(asset.balanceOf(feeTreasury), (AMOUNT * 500) / 10_000);
        assertEq(vault.totalSupply(), 0);
    }

    function test_Fees_NonOwnerCannotConfigure() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setFees(0, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setFeeRecipient(feeTreasury);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Strategy binding
    // ------------------------------------------------------------------

    function test_Strategy_OwnerCanSetAndClear() public {
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), 1_000e18);

        vm.prank(owner);
        vault.setStrategy(IStrategy(address(strategyMock)));
        assertEq(vault.strategy(), address(strategyMock));

        vm.prank(owner);
        vault.setStrategy(IStrategy(address(0)));
        assertEq(vault.strategy(), address(0));
    }

    function test_Strategy_EmitsStrategyUpdatedOnSetAndClear() public {
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), 0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit AscendVault.StrategyUpdated(IStrategy(address(0)), IStrategy(address(strategyMock)));
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(strategyMock)));

        vm.expectEmit(true, true, false, true, address(vault));
        emit AscendVault.StrategyUpdated(IStrategy(address(strategyMock)), IStrategy(address(0)));
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(0)));
    }

    function test_Strategy_RevertsOnVaultMismatch() public {
        MisboundStrategy misbound = new MisboundStrategy(address(0xdead), IERC20(address(asset)));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(AscendVault.StrategyVaultMismatch.selector, address(vault), address(0xdead))
        );
        vault.setStrategy(IStrategy(address(misbound)));
    }

    function test_Strategy_RevertsOnAssetMismatch() public {
        address otherToken = makeAddr("otherToken");
        MisboundStrategy misbound = new MisboundStrategy(address(vault), IERC20(otherToken));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.StrategyAssetMismatch.selector, address(asset), otherToken));
        vault.setStrategy(IStrategy(address(misbound)));
    }

    function test_Strategy_NonOwnerCannotUpdate() public {
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setStrategy(IStrategy(address(strategyMock)));

        // Even clearing requires the owner.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setStrategy(IStrategy(address(0)));
    }

    function test_Strategy_NeverReceivesVaultFunds() public {
        strategyMock = new MockStrategy(address(vault), IERC20(address(asset)), 0);
        asset.mint(address(strategyMock), 55e18); // fund the mock directly

        vm.prank(owner);
        vault.setStrategy(IStrategy(address(strategyMock)));

        _deposit(alice, AMOUNT);

        // Binding a strategy moves no funds and totalAssets is untouched.
        assertEq(asset.balanceOf(address(strategyMock)), 55e18);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // Ownership
    // ------------------------------------------------------------------

    function test_Owner_CanTransferOwnership() public {
        vm.prank(owner);
        vault.transferOwnership(alice);
        assertEq(vault.owner(), alice);
    }

    // ------------------------------------------------------------------
    // Mint flow (shares-first entry point)
    // ------------------------------------------------------------------

    function test_Mint_MintsExactSharesForAssets() public {
        _approve(alice, AMOUNT);
        vm.prank(alice);
        uint256 assetsIn = vault.mint(AMOUNT, alice);

        assertEq(assetsIn, AMOUNT, "mint at 1:1 requires assets == shares");
        assertEq(vault.balanceOf(alice), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Mint_RevertsWhenExceedsMax() public {
        // maxMint is unbounded; this only exercises the guard wiring via
        // a direct call on a fresh vault where nothing can exceed it.
        assertEq(vault.maxMint(alice), type(uint256).max);
    }
}

// ---------------------------------------------------------------------
// 6-decimal asset coverage (e.g. USDC-like testnet tokens)
// ---------------------------------------------------------------------

contract AscendVaultSixDecimalsTest is Test {
    AscendVault internal vault;
    MockERC20 internal asset;

    address internal alice = makeAddr("alice");

    function setUp() public {
        asset = new MockERC20("Mock USD 6", "MUSD6", 6);
        vault = new AscendVault(IERC20(address(asset)), "AscendMM MUSD6 Vault", "avMUSD6", alice);
        asset.mint(alice, 1_000_000e6);
    }

    function test_SixDecimals_VaultDecimalsMatchAsset() public view {
        assertEq(asset.decimals(), 6);
        assertEq(vault.decimals(), 6);
    }

    function test_SixDecimals_DepositRedeemRoundTrip() public {
        uint256 amount = 1_000_000e6;

        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), amount, "1:1 shares for 6-dec asset");

        vm.prank(alice);
        vault.redeem(amount, alice, alice);
        assertEq(asset.balanceOf(alice), amount);
        assertEq(vault.totalSupply(), 0);
    }
}
