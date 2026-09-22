// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MiniSwapToken} from "../src/MiniSwapToken.sol";
import {MiniPair} from "../src/MiniPair.sol";
import {ReentrantAttacker, RejectingReceiver, FeeOnTransferToken} from "./mocks/Attackers.sol";

contract MiniPairTest is Test {
    uint256 internal constant FEE_BPS = 30;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_SHARES = 1_000;
    uint256 internal constant INITIAL_ETH = 10 ether;
    uint256 internal constant INITIAL_TOKEN = 1_000_000e18;

    MiniSwapToken internal token;
    MiniPair internal pair;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 tokenAmount, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 ethAmount, uint256 tokenAmount, uint256 shares);
    event Swap(address indexed trader, uint256 ethIn, uint256 tokenIn, uint256 ethOut, uint256 tokenOut);
    event Sync(uint256 reserveEth, uint256 reserveToken);

    function setUp() public {
        token = new MiniSwapToken();
        pair = new MiniPair(address(token), FEE_BPS);
        _fund(alice, 1_000 ether, 100_000_000e18);
        _fund(bob, 1_000 ether, 100_000_000e18);
        _fund(carol, 1_000 ether, 100_000_000e18);
    }

    // -----------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------

    function _fund(address who, uint256 eth, uint256 tokens) internal {
        vm.deal(who, eth);
        token.transfer(who, tokens);
        vm.prank(who);
        token.approve(address(pair), type(uint256).max);
    }

    function _seed() internal returns (uint256 shares) {
        vm.prank(alice);
        shares = pair.addLiquidity{value: INITIAL_ETH}(INITIAL_TOKEN, 0);
    }

    function _k() internal view returns (uint256) {
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        return rEth * rTok;
    }

    function _expectedOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 withFee = amountIn * (BPS - FEE_BPS);
        return (withFee * reserveOut) / (reserveIn * BPS + withFee);
    }

    // -----------------------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------------------

    function test_constructorStoresParameters() public view {
        assertEq(address(pair.token()), address(token));
        assertEq(pair.feeBps(), FEE_BPS);
        assertEq(pair.totalShares(), 0);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, 0);
        assertEq(rTok, 0);
        assertEq(pair.MINIMUM_SHARES(), MIN_SHARES);
        assertEq(pair.MAX_FEE_BPS(), 1_000);
    }

    function test_constructorRevertsOnZeroToken() public {
        vm.expectRevert(MiniPair.ZeroAddress.selector);
        new MiniPair(address(0), FEE_BPS);
    }

    function test_constructorRevertsOnExcessiveFee() public {
        vm.expectRevert(abi.encodeWithSelector(MiniPair.FeeTooHigh.selector, 1_001, 1_000));
        new MiniPair(address(token), 1_001);
        // The bound itself is accepted.
        new MiniPair(address(token), 1_000);
    }

    function test_constructorIsNotPayable() public {
        bytes memory code = abi.encodePacked(type(MiniPair).creationCode, abi.encode(address(token), FEE_BPS));
        address deployed;
        assembly {
            deployed := create(1, add(code, 0x20), mload(code))
        }
        assertEq(deployed, address(0), "constructor accepted ETH");
    }

    function test_plainEthTransferReverts() public {
        vm.prank(alice);
        (bool ok,) = address(pair).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(pair).balance, 0);
    }

    // -----------------------------------------------------------------------------------
    // addLiquidity
    // -----------------------------------------------------------------------------------

    function test_firstDepositMintsSqrtMinusLockedMinimum() public {
        uint256 expected = Math.sqrt(INITIAL_ETH * INITIAL_TOKEN) - MIN_SHARES;

        vm.expectEmit(true, true, true, true, address(pair));
        emit LiquidityAdded(alice, INITIAL_ETH, INITIAL_TOKEN, expected);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Sync(INITIAL_ETH, INITIAL_TOKEN);

        uint256 shares = _seed();

        assertEq(shares, expected);
        assertEq(pair.sharesOf(alice), expected);
        assertEq(pair.sharesOf(address(0)), MIN_SHARES);
        assertEq(pair.totalShares(), expected + MIN_SHARES);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, INITIAL_ETH);
        assertEq(rTok, INITIAL_TOKEN);
        assertEq(address(pair).balance, INITIAL_ETH);
        assertEq(token.balanceOf(address(pair)), INITIAL_TOKEN);
    }

    function test_firstDepositRevertsBelowLockedMinimum() public {
        // sqrt(1000 * 1000) == 1000 == MINIMUM_SHARES: nothing left for the depositor.
        vm.prank(alice);
        vm.expectRevert(MiniPair.InsufficientInitialLiquidity.selector);
        pair.addLiquidity{value: 1_000}(1_000, 0);

        // One unit more is enough for exactly one share.
        vm.prank(alice);
        uint256 shares = pair.addLiquidity{value: 1_001}(1_001, 0);
        assertEq(shares, 1);
    }

    function test_addLiquidityRevertsOnZeroAmounts() public {
        vm.prank(alice);
        vm.expectRevert(MiniPair.ZeroAmount.selector);
        pair.addLiquidity{value: 0}(1e18, 0);

        vm.prank(alice);
        vm.expectRevert(MiniPair.ZeroAmount.selector);
        pair.addLiquidity{value: 1 ether}(0, 0);
    }

    function test_addLiquidityEnforcesMinShares() public {
        uint256 expected = Math.sqrt(INITIAL_ETH * INITIAL_TOKEN) - MIN_SHARES;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientShares.selector, expected, expected + 1));
        pair.addLiquidity{value: INITIAL_ETH}(INITIAL_TOKEN, expected + 1);
    }

    function test_addLiquidityRevertsWithoutApproval() public {
        address dave = makeAddr("dave");
        vm.deal(dave, 1 ether);
        token.transfer(dave, 1e18);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pair), 0, 1e18)
        );
        pair.addLiquidity{value: 1 ether}(1e18, 0);
    }

    function test_laterDepositPullsOnlyTheNeededTokens() public {
        uint256 first = _seed();
        uint256 supply = pair.totalShares();

        // Bob sends 1 ETH and offers far more tokens than the ratio needs.
        uint256 offered = 5_000_000e18;
        uint256 needed = Math.mulDiv(1 ether, INITIAL_TOKEN, INITIAL_ETH, Math.Rounding.Ceil);
        uint256 expectedShares =
            Math.min(Math.mulDiv(1 ether, supply, INITIAL_ETH), Math.mulDiv(needed, supply, INITIAL_TOKEN));

        uint256 bobEth = bob.balance;
        uint256 bobTok = token.balanceOf(bob);

        vm.expectEmit(true, true, true, true, address(pair));
        emit LiquidityAdded(bob, 1 ether, needed, expectedShares);
        vm.prank(bob);
        uint256 shares = pair.addLiquidity{value: 1 ether}(offered, expectedShares);

        assertEq(shares, expectedShares);
        assertEq(bob.balance, bobEth - 1 ether, "all ETH used");
        assertEq(token.balanceOf(bob), bobTok - needed, "only needed tokens pulled");
        assertEq(pair.totalShares(), supply + shares);
        assertEq(pair.sharesOf(alice), first);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, INITIAL_ETH + 1 ether);
        assertEq(rTok, INITIAL_TOKEN + needed);
        // Share price did not fall for the existing provider.
        assertGe(Math.mulDiv(rEth, 1e18, pair.totalShares()), Math.mulDiv(INITIAL_ETH, 1e18, supply));
    }

    function test_laterDepositRefundsExcessEth() public {
        _seed();
        uint256 supply = pair.totalShares();

        // Bob sends 5 ETH but only offers tokens worth 1 ETH.
        uint256 offered = 100_000e18;
        uint256 ethNeeded = Math.mulDiv(offered, INITIAL_ETH, INITIAL_TOKEN);
        assertEq(ethNeeded, 1 ether);
        uint256 expectedShares =
            Math.min(Math.mulDiv(ethNeeded, supply, INITIAL_ETH), Math.mulDiv(offered, supply, INITIAL_TOKEN));

        uint256 bobEth = bob.balance;
        uint256 bobTok = token.balanceOf(bob);

        vm.expectEmit(true, true, true, true, address(pair));
        emit LiquidityAdded(bob, ethNeeded, offered, expectedShares);
        vm.prank(bob);
        uint256 shares = pair.addLiquidity{value: 5 ether}(offered, 0);

        assertEq(shares, expectedShares);
        assertEq(bob.balance, bobEth - ethNeeded, "excess ETH refunded");
        assertEq(token.balanceOf(bob), bobTok - offered, "all offered tokens pulled");
        assertEq(address(pair).balance, INITIAL_ETH + ethNeeded, "pair holds no stray ETH");
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, INITIAL_ETH + ethNeeded);
        assertEq(rTok, INITIAL_TOKEN + offered);
    }

    function test_laterDepositEnforcesMinShares() public {
        _seed();
        uint256 supply = pair.totalShares();
        uint256 expected = Math.mulDiv(1 ether, supply, INITIAL_ETH);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientShares.selector, expected, expected + 1));
        pair.addLiquidity{value: 1 ether}(INITIAL_TOKEN, expected + 1);
    }

    function test_laterDepositTooSmallForAnyShareReverts() public {
        _seed();
        // 1 wei of ETH needs 100,000 wei of token at this ratio; offering 1 token unit yields 0 ETH used.
        vm.prank(bob);
        vm.expectRevert(MiniPair.ZeroAmount.selector);
        pair.addLiquidity{value: 1 ether}(1, 0);
    }

    function test_addLiquidityRevertsWhenRefundIsRejected() public {
        _seed();
        RejectingReceiver rejecter = new RejectingReceiver(pair);
        vm.deal(address(rejecter), 5 ether);
        token.transfer(address(rejecter), 100_000e18);
        // Sends 5 ETH, only 1 ETH worth of tokens: the 4 ETH refund cannot be delivered.
        vm.expectRevert(MiniPair.EthTransferFailed.selector);
        rejecter.addLiquidity{value: 5 ether}(100_000e18, 0);
        // With exactly matching amounts there is no refund and the deposit works.
        rejecter.addLiquidity{value: 1 ether}(100_000e18, 0);
    }

    function test_pairRejectsFeeOnTransferToken() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        MiniPair feePair = new MiniPair(address(fee), FEE_BPS);
        fee.approve(address(feePair), type(uint256).max);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.UnexpectedTokenAmount.selector, 100e18, 99e18));
        feePair.addLiquidity{value: 1 ether}(100e18, 0);
    }

    // -----------------------------------------------------------------------------------
    // removeLiquidity
    // -----------------------------------------------------------------------------------

    function test_removeLiquidityIsProportional() public {
        uint256 shares = _seed();
        uint256 supply = pair.totalShares();
        uint256 burn = shares / 4;
        uint256 expectedEth = Math.mulDiv(burn, INITIAL_ETH, supply);
        uint256 expectedTok = Math.mulDiv(burn, INITIAL_TOKEN, supply);

        uint256 aliceEth = alice.balance;
        uint256 aliceTok = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(pair));
        emit LiquidityRemoved(alice, expectedEth, expectedTok, burn);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Sync(INITIAL_ETH - expectedEth, INITIAL_TOKEN - expectedTok);
        vm.prank(alice);
        (uint256 ethOut, uint256 tokOut) = pair.removeLiquidity(burn, expectedEth, expectedTok);

        assertEq(ethOut, expectedEth);
        assertEq(tokOut, expectedTok);
        assertEq(alice.balance, aliceEth + expectedEth);
        assertEq(token.balanceOf(alice), aliceTok + expectedTok);
        assertEq(pair.sharesOf(alice), shares - burn);
        assertEq(pair.totalShares(), supply - burn);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, INITIAL_ETH - expectedEth);
        assertEq(rTok, INITIAL_TOKEN - expectedTok);
        // Roughly a quarter left the pool.
        assertApproxEqRel(expectedEth, INITIAL_ETH / 4, 1e15);
        assertApproxEqRel(expectedTok, INITIAL_TOKEN / 4, 1e15);
    }

    function test_removeAllReturnsFundsMinusLockedMinimum() public {
        uint256 shares = _seed();
        uint256 supply = pair.totalShares();
        uint256 aliceEth = alice.balance;
        uint256 aliceTok = token.balanceOf(alice);

        vm.prank(alice);
        (uint256 ethOut, uint256 tokOut) = pair.removeLiquidity(shares, 0, 0);

        uint256 lockedEth = Math.mulDiv(MIN_SHARES, INITIAL_ETH, supply);
        uint256 lockedTok = Math.mulDiv(MIN_SHARES, INITIAL_TOKEN, supply);
        // Everything comes back except the slice owned by the locked minimum shares (plus rounding dust).
        assertEq(ethOut, Math.mulDiv(shares, INITIAL_ETH, supply));
        assertEq(tokOut, Math.mulDiv(shares, INITIAL_TOKEN, supply));
        assertGe(INITIAL_ETH - ethOut, lockedEth);
        assertGe(INITIAL_TOKEN - tokOut, lockedTok);
        assertLe(INITIAL_ETH - ethOut, lockedEth + 1);
        assertLe(INITIAL_TOKEN - tokOut, lockedTok + 1);
        assertEq(alice.balance, aliceEth + ethOut);
        assertEq(token.balanceOf(alice), aliceTok + tokOut);
        assertEq(pair.sharesOf(alice), 0);
        assertEq(pair.totalShares(), MIN_SHARES);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertGt(rEth, 0);
        assertGt(rTok, 0);
        assertEq(address(pair).balance, rEth);
        assertEq(token.balanceOf(address(pair)), rTok);

        // The pool stays alive: the next deposit follows the residual ratio, not the empty-pool path.
        vm.prank(bob);
        uint256 more = pair.addLiquidity{value: 1 ether}(100_000e18, 0);
        assertGt(more, 0);
        assertEq(pair.sharesOf(address(0)), MIN_SHARES);
    }

    function test_removeLiquidityRevertsOnZeroShares() public {
        _seed();
        vm.prank(alice);
        vm.expectRevert(MiniPair.ZeroAmount.selector);
        pair.removeLiquidity(0, 0, 0);
    }

    function test_removeLiquidityRevertsAboveBalance() public {
        uint256 shares = _seed();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientBalance.selector, shares + 1, shares));
        pair.removeLiquidity(shares + 1, 0, 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientBalance.selector, 1, 0));
        pair.removeLiquidity(1, 0, 0);
    }

    function test_removeLiquidityEnforcesMinimums() public {
        uint256 shares = _seed();
        uint256 supply = pair.totalShares();
        uint256 ethOut = Math.mulDiv(shares, INITIAL_ETH, supply);
        uint256 tokOut = Math.mulDiv(shares, INITIAL_TOKEN, supply);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientEthOut.selector, ethOut, ethOut + 1));
        pair.removeLiquidity(shares, ethOut + 1, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientTokenOut.selector, tokOut, tokOut + 1));
        pair.removeLiquidity(shares, 0, tokOut + 1);
    }

    function test_removeLiquidityRevertsWhenReceiverRejectsEth() public {
        _seed();
        RejectingReceiver rejecter = new RejectingReceiver(pair);
        vm.deal(address(rejecter), 1 ether);
        token.transfer(address(rejecter), 100_000e18);
        uint256 shares = rejecter.addLiquidity{value: 1 ether}(100_000e18, 0);

        vm.expectRevert(MiniPair.EthTransferFailed.selector);
        rejecter.removeLiquidity(shares);
        assertEq(pair.sharesOf(address(rejecter)), shares, "state rolled back");
    }

    // -----------------------------------------------------------------------------------
    // Swaps
    // -----------------------------------------------------------------------------------

    function test_swapExactETHForTokensMatchesQuoteAndKeepsK() public {
        _seed();
        uint256 kBefore = _k();
        uint256 amountIn = 1 ether;
        uint256 expected = _expectedOut(amountIn, INITIAL_ETH, INITIAL_TOKEN);
        assertEq(pair.quoteEthToToken(amountIn), expected);

        uint256 bobTok = token.balanceOf(bob);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Swap(bob, amountIn, 0, 0, expected);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Sync(INITIAL_ETH + amountIn, INITIAL_TOKEN - expected);
        vm.prank(bob);
        uint256 out = pair.swapExactETHForTokens{value: amountIn}(expected);

        assertEq(out, expected);
        assertEq(token.balanceOf(bob), bobTok + expected);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, INITIAL_ETH + amountIn);
        assertEq(rTok, INITIAL_TOKEN - expected);
        assertGe(_k(), kBefore, "k decreased");
        // The fee stayed in the pool: k strictly grew.
        assertGt(_k(), kBefore);
    }

    function test_swapExactTokensForETHMatchesQuoteAndKeepsK() public {
        _seed();
        uint256 kBefore = _k();
        uint256 amountIn = 50_000e18;
        uint256 expected = _expectedOut(amountIn, INITIAL_TOKEN, INITIAL_ETH);
        assertEq(pair.quoteTokenToEth(amountIn), expected);

        uint256 bobEth = bob.balance;
        uint256 bobTok = token.balanceOf(bob);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Swap(bob, 0, amountIn, expected, 0);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Sync(INITIAL_ETH - expected, INITIAL_TOKEN + amountIn);
        vm.prank(bob);
        uint256 out = pair.swapExactTokensForETH(amountIn, expected);

        assertEq(out, expected);
        assertEq(bob.balance, bobEth + expected);
        assertEq(token.balanceOf(bob), bobTok - amountIn);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, INITIAL_ETH - expected);
        assertEq(rTok, INITIAL_TOKEN + amountIn);
        assertGt(_k(), kBefore, "k did not grow by the fee");
    }

    function test_swapsRevertOnEmptyPool() public {
        assertEq(pair.quoteEthToToken(1 ether), 0);
        assertEq(pair.quoteTokenToEth(1e18), 0);

        vm.prank(bob);
        vm.expectRevert(MiniPair.PoolEmpty.selector);
        pair.swapExactETHForTokens{value: 1 ether}(0);

        vm.prank(bob);
        vm.expectRevert(MiniPair.PoolEmpty.selector);
        pair.swapExactTokensForETH(1e18, 0);
    }

    function test_swapsRevertOnZeroInput() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(MiniPair.ZeroAmount.selector);
        pair.swapExactETHForTokens{value: 0}(0);

        vm.prank(bob);
        vm.expectRevert(MiniPair.ZeroAmount.selector);
        pair.swapExactTokensForETH(0, 0);

        assertEq(pair.quoteEthToToken(0), 0);
        assertEq(pair.quoteTokenToEth(0), 0);
    }

    function test_swapsRevertWhenOutputRoundsToZero() public {
        _seed();
        // 1 wei of token buys far less than 1 wei of ETH.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientOutput.selector, 0, 0));
        pair.swapExactTokensForETH(1, 0);
    }

    function test_swapSlippageLimitsRevert() public {
        _seed();
        uint256 quoteEth = pair.quoteEthToToken(1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientOutput.selector, quoteEth, quoteEth + 1));
        pair.swapExactETHForTokens{value: 1 ether}(quoteEth + 1);

        uint256 quoteTok = pair.quoteTokenToEth(50_000e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientOutput.selector, quoteTok, quoteTok + 1));
        pair.swapExactTokensForETH(50_000e18, quoteTok + 1);

        // A front-run moves the price; a limit set from the stale quote now reverts.
        vm.prank(carol);
        pair.swapExactETHForTokens{value: 2 ether}(0);
        vm.prank(bob);
        vm.expectRevert();
        pair.swapExactETHForTokens{value: 1 ether}(quoteEth);
    }

    function test_swapTokensRevertsWithoutApproval() public {
        _seed();
        address dave = makeAddr("dave");
        token.transfer(dave, 1e18);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pair), 0, 1e18)
        );
        pair.swapExactTokensForETH(1e18, 0);
    }

    function test_swapTokensForEthRevertsWhenReceiverRejectsEth() public {
        _seed();
        RejectingReceiver rejecter = new RejectingReceiver(pair);
        token.transfer(address(rejecter), 1_000e18);
        vm.expectRevert(MiniPair.EthTransferFailed.selector);
        rejecter.swapExactTokensForETH(1_000e18);
        assertEq(token.balanceOf(address(rejecter)), 1_000e18, "tokens not taken");
    }

    function test_feesAccrueToLiquidityProviders() public {
        uint256 shares = _seed();
        uint256 aliceEth = alice.balance;
        uint256 aliceTok = token.balanceOf(alice);

        // Bob trades back and forth; every trade leaves a fee in the pool.
        for (uint256 i; i < 5; ++i) {
            vm.prank(bob);
            uint256 got = pair.swapExactETHForTokens{value: 1 ether}(0);
            vm.prank(bob);
            pair.swapExactTokensForETH(got, 0);
        }

        vm.prank(alice);
        (uint256 ethOut, uint256 tokOut) = pair.removeLiquidity(shares, 0, 0);
        uint256 supply = shares + MIN_SHARES;
        // Alice's value grew relative to what her shares were worth at deposit time.
        assertGt(ethOut, Math.mulDiv(shares, INITIAL_ETH, supply));
        assertGe(tokOut, Math.mulDiv(shares, INITIAL_TOKEN, supply) - 1);
        assertEq(alice.balance, aliceEth + ethOut);
        assertEq(token.balanceOf(alice), aliceTok + tokOut);
    }

    // -----------------------------------------------------------------------------------
    // Donations and reserve accounting
    // -----------------------------------------------------------------------------------

    function test_tokenDonationDoesNotChangeQuotesOrReserves() public {
        _seed();
        uint256 quoteEth = pair.quoteEthToToken(1 ether);
        uint256 quoteTok = pair.quoteTokenToEth(50_000e18);
        (uint256 rEth, uint256 rTok) = pair.getReserves();

        vm.prank(bob);
        token.transfer(address(pair), 10_000_000e18);

        (uint256 rEth2, uint256 rTok2) = pair.getReserves();
        assertEq(rEth2, rEth);
        assertEq(rTok2, rTok);
        assertEq(pair.quoteEthToToken(1 ether), quoteEth);
        assertEq(pair.quoteTokenToEth(50_000e18), quoteTok);
        assertEq(token.balanceOf(address(pair)), rTok + 10_000_000e18);

        // A real swap still pays out exactly the internal-reserve quote.
        vm.prank(carol);
        uint256 out = pair.swapExactETHForTokens{value: 1 ether}(quoteEth);
        assertEq(out, quoteEth);

        // Removing all shares does not hand out the donation either.
        uint256 shares = pair.sharesOf(alice);
        vm.prank(alice);
        (, uint256 tokOut) = pair.removeLiquidity(shares, 0, 0);
        assertLt(tokOut, rTok);
    }

    function test_ethDonationDoesNotChangeQuotesOrReserves() public {
        _seed();
        uint256 quoteEth = pair.quoteEthToToken(1 ether);
        uint256 quoteTok = pair.quoteTokenToEth(50_000e18);
        (uint256 rEth, uint256 rTok) = pair.getReserves();

        // Force ETH in (e.g. via SELFDESTRUCT or block rewards); plain transfers already revert.
        vm.deal(address(pair), address(pair).balance + 100 ether);

        (uint256 rEth2, uint256 rTok2) = pair.getReserves();
        assertEq(rEth2, rEth);
        assertEq(rTok2, rTok);
        assertEq(pair.quoteEthToToken(1 ether), quoteEth);
        assertEq(pair.quoteTokenToEth(50_000e18), quoteTok);

        vm.prank(carol);
        uint256 out = pair.swapExactTokensForETH(50_000e18, quoteTok);
        assertEq(out, quoteTok);
    }

    // -----------------------------------------------------------------------------------
    // First-depositor share inflation
    // -----------------------------------------------------------------------------------

    function test_firstDepositorInflationAttackIsNotProfitable() public {
        address attacker = bob;
        address victim = carol;
        uint256 attackerEthBefore = attacker.balance;
        uint256 attackerTokBefore = token.balanceOf(attacker);

        // 1. Attacker seeds the pool with dust: sqrt(1001 * 1001) - 1000 = 1 share.
        vm.prank(attacker);
        uint256 attackerShares = pair.addLiquidity{value: 1_001}(1_001, 0);
        assertEq(attackerShares, 1);

        // 2. Attacker "donates" a large amount of both assets to inflate the share price.
        vm.prank(attacker);
        token.transfer(address(pair), 1_000_000e18);
        vm.deal(address(pair), address(pair).balance + 10 ether);
        vm.deal(attacker, attacker.balance - 10 ether);

        // Internal reserves ignore the donation, so the victim's deposit is priced on 1001 wei each.
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(rEth, 1_001);
        assertEq(rTok, 1_001);

        // 3. Victim deposits normally and receives shares proportional to the real reserves.
        uint256 victimEthBefore = victim.balance;
        uint256 victimTokBefore = token.balanceOf(victim);
        vm.prank(victim);
        uint256 victimShares = pair.addLiquidity{value: 10 ether}(10 ether, 0);
        assertGt(victimShares, 1e15, "victim was not rounded down to nothing");

        // 4. Victim can withdraw essentially everything they put in (rounding dust at most).
        vm.prank(victim);
        (uint256 vEth, uint256 vTok) = pair.removeLiquidity(victimShares, 0, 0);
        assertApproxEqAbs(victim.balance, victimEthBefore, 1_001);
        assertApproxEqAbs(token.balanceOf(victim), victimTokBefore, 1_001);
        assertGe(vEth + 1_001, 10 ether);
        assertGe(vTok + 1_001, 10 ether);

        // 5. Attacker withdraws: gets back at most their dust, never the donation nor victim funds.
        vm.prank(attacker);
        pair.removeLiquidity(attackerShares, 0, 0);
        assertLt(attacker.balance, attackerEthBefore, "attacker lost ETH");
        assertLt(token.balanceOf(attacker), attackerTokBefore, "attacker lost tokens");
        assertLe(attackerEthBefore - attacker.balance - 10 ether, 1_001);
    }

    // -----------------------------------------------------------------------------------
    // Reentrancy
    // -----------------------------------------------------------------------------------

    function _deployAttacker() internal returns (ReentrantAttacker attacker, uint256 shares) {
        _seed();
        attacker = new ReentrantAttacker(pair);
        vm.deal(address(attacker), 10 ether);
        token.transfer(address(attacker), 1_000_000e18);
        shares = attacker.addLiquidity{value: 1 ether}(100_000e18, 0);
    }

    function test_reentrancyOnRemoveLiquidityIsBlocked() public {
        (ReentrantAttacker attacker, uint256 shares) = _deployAttacker();
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        uint256 supply = pair.totalShares();

        // Bubbling: the inner revert makes the ETH send fail and the whole call reverts.
        attacker.setMode(ReentrantAttacker.Mode.RemoveLiquidity, true);
        vm.expectRevert(MiniPair.EthTransferFailed.selector);
        attacker.removeLiquidity(shares / 2, 0, 0);
        assertEq(pair.sharesOf(address(attacker)), shares);
        assertEq(pair.totalShares(), supply);

        // Caught: the outer call completes exactly once; the inner attempt hit the guard.
        attacker.setMode(ReentrantAttacker.Mode.RemoveLiquidity, false);
        (uint256 ethOut, uint256 tokOut) = attacker.removeLiquidity(shares / 2, 0, 0);
        assertEq(attacker.attempts(), 1);
        assertEq(bytes4(attacker.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(pair.sharesOf(address(attacker)), shares - shares / 2);
        (uint256 rEth2, uint256 rTok2) = pair.getReserves();
        assertEq(rEth2, rEth - ethOut);
        assertEq(rTok2, rTok - tokOut);
        assertEq(address(pair).balance, rEth2);
    }

    function test_reentrancyOnSwapTokensForEthIsBlocked() public {
        (ReentrantAttacker attacker,) = _deployAttacker();
        uint256 attackerEth = address(attacker).balance;

        attacker.setMode(ReentrantAttacker.Mode.SwapEthForTokens, true);
        vm.expectRevert(MiniPair.EthTransferFailed.selector);
        attacker.swapExactTokensForETH(1_000e18, 0);

        attacker.setMode(ReentrantAttacker.Mode.SwapTokensForEth, true);
        vm.expectRevert(MiniPair.EthTransferFailed.selector);
        attacker.swapExactTokensForETH(1_000e18, 0);

        attacker.setMode(ReentrantAttacker.Mode.AddLiquidity, false);
        uint256 out = attacker.swapExactTokensForETH(1_000e18, 0);
        assertEq(bytes4(attacker.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(attacker).balance, attackerEth + out);
        (uint256 rEth,) = pair.getReserves();
        assertEq(address(pair).balance, rEth);
    }

    function test_reentrancyOnAddLiquidityRefundIsBlocked() public {
        (ReentrantAttacker attacker,) = _deployAttacker();
        uint256 supply = pair.totalShares();

        // Offer few tokens with lots of ETH so a refund (and the callback) happens.
        attacker.setMode(ReentrantAttacker.Mode.RemoveLiquidity, true);
        vm.expectRevert(MiniPair.EthTransferFailed.selector);
        attacker.addLiquidity{value: 5 ether}(10_000e18, 0);
        assertEq(pair.totalShares(), supply, "no shares minted on the failed call");

        attacker.setMode(ReentrantAttacker.Mode.SwapEthForTokens, false);
        uint256 shares = attacker.addLiquidity{value: 5 ether}(10_000e18, 0);
        assertGt(shares, 0);
        assertEq(bytes4(attacker.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(pair.totalShares(), supply + shares);
        (uint256 rEth,) = pair.getReserves();
        assertEq(address(pair).balance, rEth, "reserves match balance after refund");
    }

    // -----------------------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------------------

    function testFuzz_kNeverDecreasesAcrossSwaps(uint256[8] calldata amounts, uint8 directions) public {
        _seed();
        uint256 k = _k();
        for (uint256 i; i < amounts.length; ++i) {
            bool ethIn = (directions >> i) & 1 == 1;
            if (ethIn) {
                uint256 amountIn = bound(amounts[i], 1, 100 ether);
                uint256 quote = pair.quoteEthToToken(amountIn);
                vm.prank(bob);
                if (quote == 0) {
                    vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientOutput.selector, 0, 0));
                    pair.swapExactETHForTokens{value: amountIn}(0);
                } else {
                    pair.swapExactETHForTokens{value: amountIn}(quote);
                }
            } else {
                uint256 amountIn = bound(amounts[i], 1, 10_000_000e18);
                uint256 quote = pair.quoteTokenToEth(amountIn);
                vm.prank(bob);
                if (quote == 0) {
                    vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientOutput.selector, 0, 0));
                    pair.swapExactTokensForETH(amountIn, 0);
                } else {
                    pair.swapExactTokensForETH(amountIn, quote);
                }
            }
            uint256 k2 = _k();
            assertGe(k2, k, "k decreased");
            k = k2;
        }
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        assertEq(address(pair).balance, rEth);
        assertEq(token.balanceOf(address(pair)), rTok);
    }

    function testFuzz_roundTripEthNeverProfits(uint256 amountIn) public {
        _seed();
        amountIn = bound(amountIn, 1, 500 ether);
        uint256 ethBefore = bob.balance;
        uint256 tokBefore = token.balanceOf(bob);
        uint256 k = _k();

        vm.prank(bob);
        uint256 got = pair.swapExactETHForTokens{value: amountIn}(0);
        uint256 back = pair.quoteTokenToEth(got);
        if (back == 0) {
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientOutput.selector, 0, 0));
            pair.swapExactTokensForETH(got, 0);
            assertLt(bob.balance, ethBefore);
        } else {
            vm.prank(bob);
            pair.swapExactTokensForETH(got, 0);
            assertLt(bob.balance, ethBefore, "round trip must cost the fee");
            assertEq(token.balanceOf(bob), tokBefore);
        }
        assertGe(_k(), k);
    }

    function testFuzz_roundTripTokenNeverProfits(uint256 amountIn) public {
        _seed();
        amountIn = bound(amountIn, 1, 50_000_000e18);
        uint256 ethBefore = bob.balance;
        uint256 tokBefore = token.balanceOf(bob);
        uint256 k = _k();

        uint256 quote = pair.quoteTokenToEth(amountIn);
        if (quote == 0) {
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(MiniPair.InsufficientOutput.selector, 0, 0));
            pair.swapExactTokensForETH(amountIn, 0);
            return;
        }
        vm.prank(bob);
        uint256 got = pair.swapExactTokensForETH(amountIn, 0);
        vm.prank(bob);
        pair.swapExactETHForTokens{value: got}(0);
        assertLt(token.balanceOf(bob), tokBefore, "round trip must cost the fee");
        assertEq(bob.balance, ethBefore);
        assertGe(_k(), k);
    }

    function testFuzz_addThenRemoveNeverProfits(uint256 eth, uint256 tokens) public {
        _seed();
        eth = bound(eth, 1, 500 ether);
        tokens = bound(tokens, 1, 50_000_000e18);
        uint256 ethBefore = bob.balance;
        uint256 tokBefore = token.balanceOf(bob);
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        uint256 supply = pair.totalShares();

        vm.prank(bob);
        try pair.addLiquidity{value: eth}(tokens, 0) returns (uint256 shares) {
            assertGt(shares, 0);
            // Neither side can be over-consumed.
            assertLe(ethBefore - bob.balance, eth);
            assertLe(tokBefore - token.balanceOf(bob), tokens);
            // Share price for existing providers never falls.
            (uint256 rEth2, uint256 rTok2) = pair.getReserves();
            uint256 supply2 = pair.totalShares();
            assertGe(Math.mulDiv(rEth2, supply, 1), Math.mulDiv(rEth, supply2, 1));
            assertGe(Math.mulDiv(rTok2, supply, 1), Math.mulDiv(rTok, supply2, 1));

            vm.prank(bob);
            try pair.removeLiquidity(shares, 0, 0) {}
            catch (bytes memory reason) {
                // Dust positions whose payout rounds to zero on either side stay in the pool.
                assertEq(bytes4(reason), MiniPair.ZeroAmount.selector);
                assertEq(pair.sharesOf(bob), shares);
            }
        } catch (bytes memory reason) {
            // The only acceptable failures are amounts too small to earn a share.
            bytes4 selector = bytes4(reason);
            assertTrue(selector == MiniPair.ZeroAmount.selector || selector == MiniPair.InsufficientShares.selector);
        }
        assertLe(bob.balance, ethBefore, "ETH profit from add/remove");
        assertLe(token.balanceOf(bob), tokBefore, "token profit from add/remove");
        (uint256 rEthEnd, uint256 rTokEnd) = pair.getReserves();
        assertEq(address(pair).balance, rEthEnd);
        assertEq(token.balanceOf(address(pair)), rTokEnd);
    }

    function testFuzz_quotesMatchSwaps(uint256 ethIn, uint256 tokIn) public {
        _seed();
        ethIn = bound(ethIn, 1, 100 ether);
        tokIn = bound(tokIn, 1, 10_000_000e18);

        uint256 q1 = pair.quoteEthToToken(ethIn);
        assertEq(q1, _expectedOut(ethIn, INITIAL_ETH, INITIAL_TOKEN));
        if (q1 > 0) {
            vm.prank(bob);
            assertEq(pair.swapExactETHForTokens{value: ethIn}(q1), q1);
        }
        (uint256 rEth, uint256 rTok) = pair.getReserves();
        uint256 q2 = pair.quoteTokenToEth(tokIn);
        assertEq(q2, _expectedOut(tokIn, rTok, rEth));
        if (q2 > 0) {
            vm.prank(bob);
            assertEq(pair.swapExactTokensForETH(tokIn, q2), q2);
        }
    }

    function testFuzz_firstDepositSharesFollowSqrt(uint256 eth, uint256 tokens) public {
        eth = bound(eth, 1, 1_000 ether);
        tokens = bound(tokens, 1, 100_000_000e18);
        uint256 root = Math.sqrt(eth * tokens);
        vm.prank(alice);
        if (root <= MIN_SHARES) {
            vm.expectRevert(MiniPair.InsufficientInitialLiquidity.selector);
            pair.addLiquidity{value: eth}(tokens, 0);
        } else {
            uint256 shares = pair.addLiquidity{value: eth}(tokens, 0);
            assertEq(shares, root - MIN_SHARES);
            assertEq(pair.totalShares(), root);
        }
    }
}
