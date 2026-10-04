// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Test-only ERC20 with permissionless mint/burn and configurable
///         decimals. Used to exercise AscendVault against both 18-decimal
///         (e.g. WETH-like) and 6-decimal (e.g. USDC-like) assets.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals_;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals_ = decimals_;
    }

    /// @notice Permissionless mint for test setup.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Permissionless burn for edge-case tests.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals_;
    }
}
