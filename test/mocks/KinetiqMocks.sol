// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStakingManager, IStakingAccountant, IKHYPE} from "../../src/interfaces/IKinetiqStaking.sol";

/// @title Kinetiq test doubles
/// @notice Minimal mocks for the OFFICIAL Kinetiq integration interfaces
///         ({IStakingManager}, {IStakingAccountant}, {IKHYPE}), used to
///         exercise {KinetiqLstStrategy} without any real protocol deployment
///         (none exists on Elysium). They implement exactly the transcribed
///         signatures and model the documented behavior:
///          * `stake()` accepts native HYPE and mints kHYPE at the current
///            accountant rate (no stake fee — only unstakes cost a fee).
///          * `instantUnstake` burns kHYPE and pays HYPE from the buffer
///            minus the protocol's unstake fee, honoring `minHYPEOut`.
///          * The exchange rate rises over time to model accrued yield —
///            the ONLY source of value movement, mirroring the real
///            accountant. No yield is fabricated anywhere else.
///         Deliberate failure modes simulate malformed protocol responses so
///         the strategy's fail-closed checks can be proven.

/// @dev Permissionless mint/burn kHYPE (the real token gates these behind
///      MINTER_ROLE/BURNER_ROLE held by the protocol; the mock is permissive
///      so tests can arrange balances directly).
contract MockKHYPE is ERC20 {
    constructor() ERC20("Mock Kinetiq HYPE", "kHYPE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Official {IStakingAccountant} with a single exchange-rate knob
///      (`rate` = HYPE per kHYPE, 18-dec scaled, starts at 1:1). The two
///      conversions are exact inverses up to rounding, like the real pair.
contract MockStakingAccountant is IStakingAccountant {
    uint256 public rate = 1e18;

    function setRate(uint256 newRate) external {
        require(newRate != 0, "MockStakingAccountant: zero rate");
        rate = newRate;
    }

    function kHYPEToHYPE(uint256 kHYPEAmount) external view override returns (uint256) {
        return kHYPEAmount * rate / 1e18;
    }

    function HYPEToKHYPE(uint256 HYPEAmount) external view override returns (uint256) {
        return HYPEAmount * 1e18 / rate;
    }

    // Informational views (unused by the strategy; stubbed).
    function totalStaked() external pure override returns (uint256) {
        return 0;
    }

    function totalClaimed() external pure override returns (uint256) {
        return 0;
    }

    function totalRewards() external pure override returns (uint256) {
        return 0;
    }

    function totalSlashing() external pure override returns (uint256) {
        return 0;
    }
}

/// @dev Official {IStakingManager} mock. Honest behavior plus a single
///      switchable failure mode for malformed-response tests. The async
///      withdrawal queue (`queueWithdrawal`/`confirmWithdrawal`) is stubbed
///      as unsupported: {KinetiqLstStrategy} deliberately never calls it
///      (synchronous settlement constraint — see the strategy's NatSpec).
contract MockStakingManager is IStakingManager {
    enum MockFailure {
        None, // honest behavior
        StakeReverts, // stake() reverts outright
        StakeNoMint, // stake() accepts HYPE but mints zero kHYPE
        StakeUndermint, // stake() mints 99% of the official quote
        UnstakeShortpay, // instantUnstake ignores minHYPEOut and pays half
        UnstakeNoPay, // instantUnstake burns kHYPE but pays nothing
        UnstakeExtraFee // charges 5% MORE fee than unstakeFeeRate() reports
    }

    uint256 private constant _BASIS_POINTS = 10_000;
    uint256 private constant _EXTRA_FEE_BPS = 500;

    IKHYPE public immutable khypeToken;
    IStakingAccountant public immutable accountant;

    MockFailure public failureMode;
    uint256 public unstakeFeeRateBps;
    uint256 public hypeBuffer_ = 0;
    uint256 public totalStaked_;

    error MockStakeFailed();
    error MockStakeZeroValue();
    error MockInsufficientKHYPE();
    error MockInsufficientBuffer();
    error MockUnstakeSlippage(uint256 hypeOut, uint256 minHYPEOut);
    error MockTransferFailed();
    error MockUnsupported();

    constructor(address khype_, address accountant_) {
        khypeToken = IKHYPE(khype_);
        accountant = IStakingAccountant(accountant_);
    }

    // ------------------------------------------------------------------
    // Test configuration
    // ------------------------------------------------------------------

    function setFailure(MockFailure mode) external {
        failureMode = mode;
    }

    function setUnstakeFeeRateBps(uint256 feeRateBps) external {
        unstakeFeeRateBps = feeRateBps;
    }

    /// @dev Fund the manager with `deal(address(manager), ...)` first: the
    ///      buffer is paid out of the manager's own native balance.
    function setHypeBuffer(uint256 amount) external {
        require(address(this).balance >= amount, "MockStakingManager: buffer exceeds balance");
        hypeBuffer_ = amount;
    }

    // ------------------------------------------------------------------
    // Official views
    // ------------------------------------------------------------------

    function totalStaked() external view override returns (uint256) {
        return totalStaked_;
    }

    function hypeBuffer() external view override returns (uint256) {
        return hypeBuffer_;
    }

    function minStakeAmount() external pure override returns (uint256) {
        return 0;
    }

    function minWithdrawalAmount() external pure override returns (uint256) {
        return 0;
    }

    function withdrawalDelay() external pure override returns (uint256) {
        return 8 days; // documented ~8-9 day standard-unstake window
    }

    function quickWithdrawalDelay() external pure override returns (uint256) {
        return 1 days; // documented 1-day delegation lockup
    }

    function withdrawalRequests(address, uint256) external pure override returns (WithdrawalRequest memory) {
        return WithdrawalRequest({hypeAmount: 0, kHYPEAmount: 0, kHYPEFee: 0, bufferUsed: 0, timestamp: 0});
    }

    function nextWithdrawalId(address) external pure override returns (uint256) {
        return 0;
    }

    function unstakeFeeRate() external view override returns (uint256) {
        return unstakeFeeRateBps;
    }

    function BASIS_POINTS() external pure override returns (uint256) {
        return _BASIS_POINTS;
    }

    function instantUnstakePool() external view override returns (address) {
        return address(this); // buffer custody modeled by the manager itself
    }

    // ------------------------------------------------------------------
    // Official mutative functions
    // ------------------------------------------------------------------

    /// @notice Honest: mints kHYPE at the current accountant rate. No stake
    ///         fee (only unstakes cost a fee per the documented model).
    function stake() external payable override {
        if (failureMode == MockFailure.StakeReverts) {
            revert MockStakeFailed();
        }
        if (msg.value == 0) {
            revert MockStakeZeroValue();
        }
        totalStaked_ += msg.value;

        uint256 khypeOut = accountant.HYPEToKHYPE(msg.value);
        if (failureMode == MockFailure.StakeNoMint) {
            khypeOut = 0;
        } else if (failureMode == MockFailure.StakeUndermint) {
            khypeOut = khypeOut * 99 / 100;
        }
        if (khypeOut != 0) {
            khypeToken.mint(msg.sender, khypeOut);
        }
        emit StakeReceived(address(this), msg.sender, msg.value);
    }

    /// @notice Honest: burns kHYPE from the caller (protocol burner
    ///         authority — no allowance needed, mirroring the real model),
    ///         pays HYPE out of the buffer minus the unstake fee, and honors
    ///         `minHYPEOut` (unless the failure mode suppresses it).
    function instantUnstake(uint256 kHYPEAmount, uint256 minHYPEOut) external override {
        if (khypeToken.balanceOf(msg.sender) < kHYPEAmount) {
            revert MockInsufficientKHYPE();
        }
        khypeToken.burn(msg.sender, kHYPEAmount);

        uint256 gross = accountant.kHYPEToHYPE(kHYPEAmount);
        uint256 feeRate = unstakeFeeRateBps;
        if (failureMode == MockFailure.UnstakeExtraFee) {
            feeRate += _EXTRA_FEE_BPS;
        }
        uint256 fee = gross * feeRate / _BASIS_POINTS;
        uint256 hypeOut = gross - fee;

        if (hypeBuffer_ < hypeOut) {
            revert MockInsufficientBuffer();
        }
        if (failureMode == MockFailure.UnstakeShortpay) {
            // Malformed: suppress min-out protection and pay half.
            hypeOut /= 2;
        } else if (hypeOut < minHYPEOut) {
            revert MockUnstakeSlippage(hypeOut, minHYPEOut);
        }

        hypeBuffer_ -= hypeOut;

        if (failureMode == MockFailure.UnstakeNoPay) {
            // Malformed: burn accepted, nothing paid back.
            emit InstantUnstakeExecuted(msg.sender, kHYPEAmount, 0, fee, feeRate, fee, 0);
            return;
        }
        (bool ok,) = msg.sender.call{value: hypeOut}(new bytes(0));
        if (!ok) {
            revert MockTransferFailed();
        }
        emit InstantUnstakeExecuted(msg.sender, kHYPEAmount, hypeOut, fee, feeRate, fee, 0);
    }

    /// @notice Async queue path: NOT modeled and NEVER called by the adapter.
    function queueWithdrawal(uint256) external pure override {
        revert MockUnsupported();
    }

    function confirmWithdrawal(uint256) external pure override {
        revert MockUnsupported();
    }
}
