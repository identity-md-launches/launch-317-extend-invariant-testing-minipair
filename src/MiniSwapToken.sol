// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mini Swap launch token
/// @notice Fixed-supply ERC-20: name "Mini Swap", symbol "MSWAP", 18 decimals.
/// @dev The whole supply of 1,000,000,000 MSWAP (10^27 minor units) is minted once, in the
/// constructor, to `msg.sender`. During the launch that caller is the ProjectFactory, which then
/// splits the supply according to the pinned policy. There is no owner, no mint or burn entry
/// point, no initializer, no upgrade path, no transfer tax, no blacklist and no pause. The
/// constructor takes no arguments and no ETH, so the creation code is fully static.
contract MiniSwapToken is ERC20 {
    /// @notice Total supply in minor units: one billion tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("Mini Swap", "MSWAP") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
