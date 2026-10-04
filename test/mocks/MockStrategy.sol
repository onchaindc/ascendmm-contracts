// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @title MockStrategy
/// @notice Test-only IStrategy implementation. Holds underlying tokens and
///         reports its raw balance. The current AscendVault iteration never
///         moves funds to the strategy, so this mock only needs to satisfy the
///         interface for binding-validation tests.
contract MockStrategy is IStrategy {
    address public immutable override vault;
    address public immutable override asset;
    uint256 public immutable override cap;

    IERC20 private immutable _asset;
    int256 private _reportedProfit;

    constructor(address vault_, IERC20 asset_, uint256 cap_) {
        vault = vault_;
        asset = address(asset_);
        _asset = asset_;
        cap = cap_;
    }

    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /// @notice Set the profit value returned by the next `report()` call.
    function setReportedProfit(int256 profit) external {
        _reportedProfit = profit;
    }

    function invest(uint256 assets) external {
        SafeERC20.safeTransferFrom(_asset, msg.sender, address(this), assets);
        emit Invested(assets);
    }

    function divest(uint256 assets) external {
        SafeERC20.safeTransfer(_asset, msg.sender, assets);
        emit Divested(assets);
    }

    function report() external returns (int256 profit) {
        profit = _reportedProfit;
        emit Reported(profit);
    }
}

/// @title MisboundStrategy
/// @notice Test-only strategy that reports WRONG bindings, used to verify the
///         vault's validation reverts on mismatched vault/asset.
contract MisboundStrategy is IStrategy {
    address public immutable override vault;
    address public immutable override asset;
    uint256 public immutable override cap;

    constructor(address vault_, IERC20 asset_) {
        vault = vault_;
        asset = address(asset_);
        cap = 0;
    }

    function totalAssets() external pure returns (uint256) {
        return 0;
    }

    function invest(uint256) external pure {
        revert("unused");
    }

    function divest(uint256) external pure {
        revert("unused");
    }

    function report() external pure returns (int256) {
        revert("unused");
    }
}
