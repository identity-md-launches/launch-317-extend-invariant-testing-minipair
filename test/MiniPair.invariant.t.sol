// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MiniSwapToken} from "../src/MiniSwapToken.sol";
import {MiniPair} from "../src/MiniPair.sol";

/// @dev Drives the pair with bounded, valid actions from a small set of actors.
contract MiniPairHandler is Test {
    MiniSwapToken public token;
    MiniPair public pair;
    address[] public actors;

    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public tokenIn;
    uint256 public tokenOut;
    uint256 public swaps;
    uint256 public lastK;

    constructor(MiniSwapToken token_, MiniPair pair_) {
        token = token_;
        pair = pair_;
        for (uint256 i; i < 4; ++i) {
            address actor = address(uint160(0xA11CE0 + i));
            actors.push(actor);
            vm.deal(actor, 1_000_000 ether);
            vm.prank(actor);
            token_.approve(address(pair_), type(uint256).max);
        }
    }

    /// @dev Called once by the test after the handler has been given tokens.
    function fundActors() external {
        uint256 each = token.balanceOf(address(this)) / actors.length;
        for (uint256 i; i < actors.length; ++i) {
            token.transfer(actors[i], each);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function addLiquidity(uint256 seed, uint256 eth, uint256 tokens) external {
        address actor = _actor(seed);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        if (pair.totalShares() == 0) {
            eth = bound(eth, 1e6, 100 ether);
            tokens = bound(tokens, 1e6, Math.min(10_000_000e18, balance));
        } else {
            eth = bound(eth, 1, 100 ether);
            // Offer enough tokens for the ETH at the current ratio (plus a random surplus) so the
            // ETH side is fully used, or fewer so the refund path is exercised.
            uint256 needed = Math.mulDiv(eth, rTok, rEth, Math.Rounding.Ceil);
            tokens = bound(tokens, 1, Math.min(needed * 2 + 1, balance));
            uint256 ethUsed = needed <= tokens ? eth : Math.mulDiv(tokens, rEth, rTok);
            uint256 tokUsed = needed <= tokens ? needed : tokens;
            if (ethUsed == 0 || tokUsed == 0) return;
            uint256 supply = pair.totalShares();
            if (Math.min(Math.mulDiv(ethUsed, supply, rEth), Math.mulDiv(tokUsed, supply, rTok)) == 0) return;
        }
        uint256 ethBefore = actor.balance;
        uint256 tokBefore = token.balanceOf(actor);
        vm.prank(actor);
        pair.addLiquidity{value: eth}(tokens, 0);
        ethIn += ethBefore - actor.balance;
        tokenIn += tokBefore - token.balanceOf(actor);
        lastK = _k();
    }

    function removeLiquidity(uint256 seed, uint256 shares) external {
        address actor = _actor(seed);
        uint256 held = pair.sharesOf(actor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        uint256 supply = pair.totalShares();
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        if (Math.mulDiv(shares, rEth, supply) == 0 || Math.mulDiv(shares, rTok, supply) == 0) return;
        vm.prank(actor);
        (uint256 e, uint256 t) = pair.removeLiquidity(shares, 0, 0);
        ethOut += e;
        tokenOut += t;
        lastK = _k();
    }

    function swapEthForTokens(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        amount = bound(amount, 1, 50 ether);
        uint256 quote = pair.quoteEthToToken(amount);
        if (quote == 0) return;
        uint256 kBefore = _k();
        vm.prank(actor);
        uint256 out = pair.swapExactETHForTokens{value: amount}(quote);
        ethIn += amount;
        tokenOut += out;
        swaps += 1;
        assertGe(_k(), kBefore, "swap decreased k");
        lastK = _k();
    }

    function swapTokensForEth(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        amount = bound(amount, 1, 5_000_000e18);
        if (token.balanceOf(actor) < amount) return;
        uint256 quote = pair.quoteTokenToEth(amount);
        if (quote == 0) return;
        uint256 kBefore = _k();
        vm.prank(actor);
        uint256 out = pair.swapExactTokensForETH(amount, quote);
        tokenIn += amount;
        ethOut += out;
        swaps += 1;
        assertGe(_k(), kBefore, "swap decreased k");
        lastK = _k();
    }

    function _k() private view returns (uint256) {
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        return rEth * rTok;
    }
}

contract MiniPairInvariantTest is Test {
    MiniSwapToken internal token;
    MiniPair internal pair;
    MiniPairHandler internal handler;

    function setUp() public {
        token = new MiniSwapToken();
        pair = new MiniPair(address(token), 30);
        handler = new MiniPairHandler(token, pair);
        token.transfer(address(handler), 400_000_000e18);
        handler.fundActors();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MiniPairHandler.addLiquidity.selector;
        selectors[1] = MiniPairHandler.removeLiquidity.selector;
        selectors[2] = MiniPairHandler.swapEthForTokens.selector;
        selectors[3] = MiniPairHandler.swapTokensForEth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Internal reserves are exactly backed by real balances (no donations in this model).
    function invariant_reservesAreBackedByBalances() public view {
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(address(pair).balance, rEth, "ETH balance != reserve");
        assertEq(token.balanceOf(address(pair)), rTok, "token balance != reserve");
    }

    /// @dev Reserves equal net flows: what came in minus what went out.
    function invariant_reservesEqualNetFlows() public view {
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, handler.ethIn() - handler.ethOut());
        assertEq(rTok, handler.tokenIn() - handler.tokenOut());
    }

    /// @dev Shares are conserved and the minimum stays locked once the pool is live.
    function invariant_sharesAreConserved() public view {
        uint256 sum = pair.sharesOf(address(0));
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += pair.sharesOf(handler.actors(i));
        }
        assertEq(sum, pair.totalShares(), "share supply mismatch");
        if (pair.totalShares() > 0) {
            assertEq(pair.sharesOf(address(0)), pair.MINIMUM_SHARES(), "locked minimum changed");
            (uint256 rEth, uint256 rTok) = pair.getReserves();
            assertGt(rEth, 0, "live pool with no ETH reserve");
            assertGt(rTok, 0, "live pool with no token reserve");
        }
    }

    /// @dev Quotes are always consistent with the constant-product formula on internal reserves.
    function invariant_quotesFollowInternalReserves() public view {
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        if (rEth == 0 || rTok == 0) {
            assertEq(pair.quoteEthToToken(1 ether), 0);
            assertEq(pair.quoteTokenToEth(1e18), 0);
            return;
        }
        uint256 withFee = 1 ether * (10_000 - 30);
        assertEq(pair.quoteEthToToken(1 ether), (withFee * rTok) / (rEth * 10_000 + withFee));
        withFee = 1e18 * (10_000 - 30);
        assertEq(pair.quoteTokenToEth(1e18), (withFee * rEth) / (rTok * 10_000 + withFee));
    }
}
