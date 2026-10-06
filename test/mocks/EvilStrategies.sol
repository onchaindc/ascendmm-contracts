// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

// -----------------------------------------------------------------------------
// TEST-ONLY adversarial IStrategy implementations.
//
// Each one binds CORRECTLY (passing the vault's setStrategy validation) but
// misbehaves on a specific axis, so the test suite can prove the vault's
// settlement checks contain the damage instead of corrupting accounting.
// NEVER deploy any of these.
// -----------------------------------------------------------------------------

/// @title GreedyPullStrategy
/// @notice Tries to pull TWICE the approved amount on invest. Must fail at the
///         ERC-20 allowance level — proving the vault's exact-amount approval
///         caps what a strategy can pull per investment.
contract GreedyPullStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override vault;
    address public immutable override asset;
    uint256 public immutable override cap;

    IERC20 private immutable _token;

    constructor(address vault_, IERC20 asset_) {
        vault = vault_;
        asset = address(asset_);
        cap = type(uint256).max;
        _token = asset_;
    }

    function totalAssets() external view returns (uint256) {
        return _token.balanceOf(address(this));
    }

    function invest(uint256 assets) external payable {
        SafeERC20.safeTransferFrom(_token, msg.sender, address(this), assets * 2);
        emit Invested(assets * 2);
    }

    function divest(uint256 assets) external {
        SafeERC20.safeTransfer(_token, msg.sender, assets);
        emit Divested(assets);
    }

    function divestAll() external {
        uint256 held = _token.balanceOf(address(this));
        if (held != 0) {
            SafeERC20.safeTransfer(_token, msg.sender, held);
        }
        emit Divested(held);
    }

    function harvest() external {
        emit Reported(0);
    }

    function report() external returns (int256) {
        return 0;
    }
}

/// @title StingyDivestStrategy
/// @notice Invests honestly (pulls the full approved amount) but returns only
///         HALF of what is requested on divest. Must make redemptions and
///         exits revert with `DivestShortfall`, leaving accounting untouched.
contract StingyDivestStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override vault;
    address public immutable override asset;
    uint256 public immutable override cap;

    IERC20 private immutable _token;

    constructor(address vault_, IERC20 asset_) {
        vault = vault_;
        asset = address(asset_);
        cap = type(uint256).max;
        _token = asset_;
    }

    function totalAssets() external view returns (uint256) {
        return _token.balanceOf(address(this));
    }

    function invest(uint256 assets) external payable {
        SafeERC20.safeTransferFrom(_token, msg.sender, address(this), assets);
        emit Invested(assets);
    }

    function divest(uint256 assets) external {
        SafeERC20.safeTransfer(_token, msg.sender, assets / 2);
        emit Divested(assets / 2);
    }

    /// @dev Stingy on the full-balance path too: returns only half.
    function divestAll() external {
        uint256 held = _token.balanceOf(address(this));
        if (held != 0) {
            SafeERC20.safeTransfer(_token, msg.sender, held / 2);
        }
        emit Divested(held / 2);
    }

    function harvest() external {
        emit Reported(0);
    }

    function report() external returns (int256) {
        return 0;
    }
}

/// @title HalfSettlingStrategy
/// @notice Under-settles on the INVEST side: pulls only half of what it was
///         approved for. Must trigger `InvestSettlementMismatch` so the ledger
///         cannot be inflated by a strategy that takes less but claims more.
contract HalfSettlingStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override vault;
    address public immutable override asset;
    uint256 public immutable override cap;

    IERC20 private immutable _token;

    constructor(address vault_, IERC20 asset_) {
        vault = vault_;
        asset = address(asset_);
        cap = type(uint256).max;
        _token = asset_;
    }

    function totalAssets() external view returns (uint256) {
        return _token.balanceOf(address(this));
    }

    function invest(uint256 assets) external payable {
        SafeERC20.safeTransferFrom(_token, msg.sender, address(this), assets / 2);
        emit Invested(assets / 2);
    }

    function divest(uint256 assets) external {
        SafeERC20.safeTransfer(_token, msg.sender, assets);
        emit Divested(assets);
    }

    function divestAll() external {
        uint256 held = _token.balanceOf(address(this));
        if (held != 0) {
            SafeERC20.safeTransfer(_token, msg.sender, held);
        }
        emit Divested(held);
    }

    function harvest() external {
        emit Reported(0);
    }

    function report() external returns (int256) {
        return 0;
    }
}

/// @title LyingStrategy
/// @notice Reports a massive self-declared `totalAssets()` (1e30) regardless of
///         its real holdings. Must have ZERO effect on the vault's share
///         pricing — the IStrategy interface forbids share pricing on
///         self-reported values, and the vault's ledger accounting honors it.
contract LyingStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override vault;
    address public immutable override asset;
    uint256 public immutable override cap;

    IERC20 private immutable _token;

    constructor(address vault_, IERC20 asset_) {
        vault = vault_;
        asset = address(asset_);
        cap = type(uint256).max;
        _token = asset_;
    }

    function totalAssets() external pure returns (uint256) {
        return 1e30;
    }

    function invest(uint256 assets) external payable {
        SafeERC20.safeTransferFrom(_token, msg.sender, address(this), assets);
        emit Invested(assets);
    }

    function divest(uint256 assets) external {
        SafeERC20.safeTransfer(_token, msg.sender, assets);
        emit Divested(assets);
    }

    function divestAll() external {
        uint256 held = _token.balanceOf(address(this));
        if (held != 0) {
            SafeERC20.safeTransfer(_token, msg.sender, held);
        }
        emit Divested(held);
    }

    function harvest() external {
        emit Reported(0);
    }

    function report() external returns (int256) {
        return 0;
    }
}
