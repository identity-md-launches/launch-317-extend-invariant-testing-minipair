// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MiniPair} from "../../src/MiniPair.sol";

/// @dev Liquidity provider / trader that re-enters the pair from `receive()`.
/// With `bubble = true` the reentrant revert propagates, so the pair's ETH send fails.
/// With `bubble = false` the attempt is caught and recorded so tests can inspect the reason.
contract ReentrantAttacker {
    enum Mode {
        None,
        RemoveLiquidity,
        SwapEthForTokens,
        SwapTokensForEth,
        AddLiquidity
    }

    MiniPair public immutable pair;
    IERC20 public immutable token;
    Mode public mode;
    bool public bubble;
    uint256 public attempts;
    bytes public lastError;

    constructor(MiniPair pair_) {
        pair = pair_;
        token = pair_.token();
        token.approve(address(pair_), type(uint256).max);
    }

    function setMode(Mode mode_, bool bubble_) external {
        mode = mode_;
        bubble = bubble_;
    }

    function addLiquidity(uint256 tokenAmount, uint256 minShares) external payable returns (uint256) {
        return pair.addLiquidity{value: msg.value}(tokenAmount, minShares);
    }

    function removeLiquidity(uint256 shares, uint256 minEth, uint256 minToken) external returns (uint256, uint256) {
        return pair.removeLiquidity(shares, minEth, minToken);
    }

    function swapExactTokensForETH(uint256 amountIn, uint256 minOut) external returns (uint256) {
        return pair.swapExactTokensForETH(amountIn, minOut);
    }

    receive() external payable {
        Mode current = mode;
        if (current == Mode.None) return;
        // Only re-enter once per outer call, so the attempt is deliberate and observable.
        mode = Mode.None;
        attempts += 1;
        if (bubble) {
            _reenter(current);
        } else {
            try this.reenter(current) {
                lastError = "";
            } catch (bytes memory reason) {
                lastError = reason;
            }
        }
    }

    function reenter(Mode current) external {
        require(msg.sender == address(this), "self only");
        _reenter(current);
    }

    function _reenter(Mode current) private {
        if (current == Mode.RemoveLiquidity) {
            pair.removeLiquidity(1, 0, 0);
        } else if (current == Mode.SwapEthForTokens) {
            pair.swapExactETHForTokens{value: 1}(0);
        } else if (current == Mode.SwapTokensForEth) {
            pair.swapExactTokensForETH(1, 0);
        } else if (current == Mode.AddLiquidity) {
            pair.addLiquidity{value: 1}(1, 0);
        }
    }
}

/// @dev A receiver that refuses ETH, to exercise the failed-send paths.
contract RejectingReceiver {
    MiniPair public immutable pair;

    constructor(MiniPair pair_) {
        pair = pair_;
        pair_.token().approve(address(pair_), type(uint256).max);
    }

    function addLiquidity(uint256 tokenAmount, uint256 minShares) external payable returns (uint256) {
        return pair.addLiquidity{value: msg.value}(tokenAmount, minShares);
    }

    function removeLiquidity(uint256 shares) external returns (uint256, uint256) {
        return pair.removeLiquidity(shares, 0, 0);
    }

    function swapExactTokensForETH(uint256 amountIn) external returns (uint256) {
        return pair.swapExactTokensForETH(amountIn, 0);
    }

    receive() external payable {
        revert("no ETH accepted");
    }
}

/// @dev ERC-20 that burns 1% on every transfer, to show the pair rejects nonstandard tokens.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {
        _mint(msg.sender, 1_000_000e18);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
