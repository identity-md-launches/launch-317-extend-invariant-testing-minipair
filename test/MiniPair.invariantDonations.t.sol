// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MiniSwapToken} from "../src/MiniSwapToken.sol";
import {MiniPair} from "../src/MiniPair.sol";

/// @dev Calls originate from real contracts, including a provider which always refuses ETH.
contract DonationActor {
    MiniPair public immutable pair;
    MiniSwapToken public immutable token;
    bool public immutable rejectsEth;

    constructor(MiniPair pair_, MiniSwapToken token_, bool rejectsEth_) {
        pair = pair_;
        token = token_;
        rejectsEth = rejectsEth_;
    }

    function approve(uint256 amount) external {
        token.approve(address(pair), amount);
    }

    function add(uint256 eth, uint256 tokens) external returns (uint256) {
        return pair.addLiquidity{value: eth}(tokens, 0);
    }

    function remove(uint256 shares) external returns (uint256, uint256) {
        return pair.removeLiquidity(shares, 0, 0);
    }

    function buy(uint256 eth, uint256 minOut) external returns (uint256) {
        return pair.swapExactETHForTokens{value: eth}(minOut);
    }

    function sell(uint256 tokens, uint256 minOut) external returns (uint256) {
        return pair.swapExactTokensForETH(tokens, minOut);
    }

    function donate(uint256 tokens) external {
        require(token.transfer(address(pair), tokens));
    }

    function plainEth(uint256 eth) external returns (bool) {
        (bool ok,) = address(pair).call{value: eth}("");
        return ok;
    }

    receive() external payable {
        require(!rejectsEth, "reject ETH");
    }
}

contract MiniPairDonationsHandler is Test {
    MiniSwapToken public immutable token;
    MiniPair public immutable pair;
    DonationActor[4] public actors;

    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public tokenIn;
    uint256 public tokenOut;
    uint256 public donatedEth;
    uint256 public donatedTokens;
    bool public everLive;

    uint256 public lastKBefore;
    uint256 public lastNormalizedK;
    uint256 public shareValueChecks;
    bytes32 public failedStateBefore;
    bytes32 public failedStateAfter;

    uint256 public initialDeposits;
    uint256 public tokenSurplusDeposits;
    uint256 public ethRefundDeposits;
    uint256 public removals;
    uint256 public buys;
    uint256 public sells;
    uint256 public failedRemovals;
    uint256 public failedSells;
    uint256 public failedRefunds;
    uint256 public rejectedPlainEth;

    struct Balances {
        uint256 eth;
        uint256 tokens;
    }

    constructor(MiniSwapToken token_, MiniPair pair_) {
        token = token_;
        pair = pair_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = new DonationActor(pair_, token_, i == 3);
            vm.deal(address(actors[i]), 1_000_000 ether);
        }
    }

    /// @dev Check each transition, including donations and caught reverts, rather than just
    /// comparing the endpoints of a fuzz sequence. The first deposit has no preceding share price.
    /// ETH funding is finite (4e24 wei), MSWAP supply is 1e27, and each input is capped below:
    /// k and supply squared fit uint256; their cross product needs Math.mulDiv's 512-bit arithmetic.
    modifier preservesShareValue() {
        uint256 supplyBefore = pair.totalShares();
        uint256 kBefore = _k();
        _;
        uint256 supplyAfter = pair.totalShares();
        if (supplyBefore != 0) {
            assertGe(supplyAfter, 1_000, "lost locked shares");
            lastKBefore = kBefore;
            lastNormalizedK = Math.mulDiv(_k(), supplyBefore * supplyBefore, supplyAfter * supplyAfter);
            assertGe(lastNormalizedK, kBefore, "k / totalShares^2 decreased");
            ++shareValueChecks;
        }
        if (supplyAfter != 0) everLive = true;
        if (everLive) {
            assertGe(supplyAfter, 1_000);
            (uint256 re, uint256 rt) = pair.getReserves();
            assertGt(re, 0, "live ETH reserve vanished");
            assertGt(rt, 0, "live token reserve vanished");
        }
    }

    function addWithTokenSurplus(uint256 who, uint256 ethSeed, uint256 surplusSeed) external preservesShareValue {
        DonationActor actor = actors[who % actors.length];
        uint256 balance = token.balanceOf(address(actor));
        uint256 eth;
        uint256 offered;
        uint256 used;
        bool initial = pair.totalShares() == 0;
        if (initial) {
            if (balance < 1_001 || address(actor).balance < 1_001) return;
            eth = bound(ethSeed, 1_001, Math.min(100 ether, address(actor).balance));
            offered = bound(surplusSeed, 1_001, Math.min(10_000_000e18, balance));
            used = offered;
        } else {
            (uint256 re, uint256 rt) = pair.getReserves();
            if (balance < 2) return;
            uint256 minimum = Math.ceilDiv(re, pair.totalShares());
            uint256 maximum = Math.min(100 ether, address(actor).balance);
            maximum = Math.min(maximum, Math.mulDiv(balance - 1, re, rt));
            if (minimum > maximum) return; // No affordable deposit that can mint even one share.
            eth = bound(ethSeed, minimum, maximum);
            used = Math.mulDiv(eth, rt, re, Math.Rounding.Ceil);
            offered = used + bound(surplusSeed, 1, balance - used);
            assertGt(offered, used, "must offer a strict token surplus");
        }
        actor.approve(offered);
        Balances memory before = _balances();
        uint256 actorEth = address(actor).balance;
        uint256 actorTokens = token.balanceOf(address(actor));
        assertGt(actor.add(eth, offered), 0);
        assertEq(actorEth - address(actor).balance, eth, "unexpected ETH refund");
        assertEq(actorTokens - token.balanceOf(address(actor)), used, "wrong token pull");
        _recordFlows(before);
        if (initial) ++initialDeposits;
        else ++tokenSurplusDeposits;
    }

    function addWithEthRefund(uint256 who, uint256 tokenSeed, uint256 surplusSeed) external preservesShareValue {
        DonationActor actor = actors[who % 3];
        (uint256 eth, uint256 tokens, uint256 used) = _refundAmounts(actor, tokenSeed, surplusSeed);
        if (eth == 0) return;
        actor.approve(tokens);
        Balances memory before = _balances();
        uint256 actorEth = address(actor).balance;
        uint256 actorTokens = token.balanceOf(address(actor));
        assertGt(actor.add(eth, tokens), 0);
        assertLt(used, eth, "must refund a strict ETH surplus");
        assertEq(actorEth - address(actor).balance, used, "wrong ETH refund");
        assertEq(actorTokens - token.balanceOf(address(actor)), tokens, "not all tokens used");
        _recordFlows(before);
        ++ethRefundDeposits;
    }

    function remove(uint256 who, uint256 seed) external preservesShareValue {
        DonationActor actor = actors[who % 3];
        uint256 shares = _removable(actor, seed);
        if (shares == 0) return;
        Balances memory before = _balances();
        actor.remove(shares);
        _recordFlows(before);
        ++removals;
    }

    function buy(uint256 who, uint256 seed) external preservesShareValue {
        DonationActor actor = actors[who % actors.length];
        (uint256 re, uint256 rt) = pair.getReserves();
        uint256 amount = _swapInput(seed, re, rt, Math.min(100 ether, address(actor).balance));
        if (amount == 0) return;
        uint256 expected = _quote(amount, re, rt);
        assertEq(pair.quoteEthToToken(amount), expected);
        Balances memory before = _balances();
        assertEq(actor.buy(amount, expected), expected);
        _recordFlows(before);
        ++buys;
    }

    function sell(uint256 who, uint256 seed) external preservesShareValue {
        DonationActor actor = actors[who % 3];
        (uint256 re, uint256 rt) = pair.getReserves();
        uint256 amount = _swapInput(seed, rt, re, Math.min(5_000_000e18, token.balanceOf(address(actor))));
        if (amount == 0) return;
        uint256 expected = _quote(amount, rt, re);
        assertEq(pair.quoteTokenToEth(amount), expected);
        actor.approve(amount);
        Balances memory before = _balances();
        assertEq(actor.sell(amount, expected), expected);
        _recordFlows(before);
        ++sells;
    }

    function donateTokens(uint256 who, uint256 seed) external preservesShareValue {
        DonationActor actor = actors[who % actors.length];
        uint256 maximum = Math.min(1_000_000e18, token.balanceOf(address(actor)));
        if (maximum == 0) return;
        uint256 amount = bound(seed, 1, maximum);
        bytes32 before = _pricingState();
        actor.donate(amount);
        donatedTokens += amount;
        assertEq(_pricingState(), before, "token donation changed reserves, shares or quotes");
    }

    function forceEth(uint256 seed) external preservesShareValue {
        uint256 amount = bound(seed, 1, 1_000 ether);
        bytes32 before = _pricingState();
        vm.deal(address(pair), address(pair).balance + amount);
        donatedEth += amount;
        assertEq(_pricingState(), before, "forced ETH changed reserves, shares or quotes");
    }

    function rejectRemove(uint256 seed) external preservesShareValue {
        DonationActor actor = actors[3];
        uint256 shares = _removable(actor, seed);
        if (shares == 0) return;
        bytes32 before = stateHash();
        try actor.remove(shares) returns (uint256, uint256) {
            assertTrue(false, "rejecting provider received ETH");
        } catch (bytes memory reason) {
            _assertFailedSend(before, reason);
        }
        ++failedRemovals;
    }

    function rejectSell(uint256 seed) external preservesShareValue {
        DonationActor actor = actors[3];
        (uint256 re, uint256 rt) = pair.getReserves();
        uint256 amount = _swapInput(seed, rt, re, Math.min(5_000_000e18, token.balanceOf(address(actor))));
        if (amount == 0) return;
        // A finite allowance proves transferFrom's allowance decrement is rolled back as well.
        actor.approve(amount);
        bytes32 before = stateHash();
        try actor.sell(amount, _quote(amount, rt, re)) returns (uint256) {
            assertTrue(false, "rejecting trader received ETH");
        } catch (bytes memory reason) {
            _assertFailedSend(before, reason);
        }
        ++failedSells;
    }

    function rejectRefund(uint256 tokenSeed, uint256 surplusSeed) external preservesShareValue {
        DonationActor actor = actors[3];
        (uint256 eth, uint256 tokens,) = _refundAmounts(actor, tokenSeed, surplusSeed);
        if (eth == 0) return;
        actor.approve(tokens);
        bytes32 before = stateHash();
        try actor.add(eth, tokens) returns (uint256) {
            assertTrue(false, "rejecting provider accepted an ETH refund");
        } catch (bytes memory reason) {
            _assertFailedSend(before, reason);
        }
        ++failedRefunds;
    }

    function plainEth(uint256 who, uint256 seed) external preservesShareValue {
        DonationActor actor = actors[who % actors.length];
        uint256 maximum = Math.min(1 ether, address(actor).balance);
        if (maximum == 0) return;
        uint256 amount = bound(seed, 1, maximum);
        bytes32 before = stateHash();
        assertFalse(actor.plainEth(amount), "pair accepted a plain ETH transfer");
        assertEq(stateHash(), before, "plain ETH rejection changed state");
        ++rejectedPlainEth;
    }

    /// @dev Hash all financial state, including every actor, locked shares and finite allowances.
    /// Hashes are compared immediately at the failure site; later actions cannot mask a failure.
    function stateHash() public view returns (bytes32 result) {
        result = keccak256(abi.encode(_pricingState(), _balances(), token.totalSupply()));
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(actors[i]);
            result = keccak256(
                abi.encode(
                    result,
                    actor.balance,
                    token.balanceOf(actor),
                    pair.sharesOf(actor),
                    token.allowance(actor, address(pair))
                )
            );
        }
    }

    function _assertFailedSend(bytes32 before, bytes memory reason) private {
        assertEq(reason, abi.encodeWithSelector(MiniPair.EthTransferFailed.selector), "wrong failure path");
        failedStateBefore = before;
        failedStateAfter = stateHash();
        assertEq(failedStateAfter, before, "failed ETH send changed financial state");
    }

    function _pricingState() private view returns (bytes32) {
        (uint256 re, uint256 rt) = pair.getReserves();
        return keccak256(
            abi.encode(
                re,
                rt,
                pair.totalShares(),
                pair.sharesOf(address(0)),
                pair.quoteEthToToken(1 ether),
                pair.quoteTokenToEth(1e18)
            )
        );
    }

    function _balances() private view returns (Balances memory) {
        return Balances(address(pair).balance, token.balanceOf(address(pair)));
    }

    /// @dev Ghost flows come from observed transfers, never from reserves or return values.
    /// Donations and failed sends deliberately do not call this function.
    function _recordFlows(Balances memory before) private {
        Balances memory after_ = _balances();
        if (after_.eth >= before.eth) ethIn += after_.eth - before.eth;
        else ethOut += before.eth - after_.eth;
        if (after_.tokens >= before.tokens) tokenIn += after_.tokens - before.tokens;
        else tokenOut += before.tokens - after_.tokens;
    }

    function _k() private view returns (uint256) {
        (uint256 re, uint256 rt) = pair.getReserves();
        return re * rt;
    }

    function _quote(uint256 amount, uint256 reserveIn, uint256 reserveOut) private pure returns (uint256) {
        return Math.mulDiv(amount * 9_970, reserveOut, reserveIn * 10_000 + amount * 9_970);
    }

    /// @dev Solve output >= 1 independently of the implementation's quote. A broken quote must
    /// fail an assertion, not cause the handler to silently skip a valid trade.
    function _swapInput(uint256 seed, uint256 reserveIn, uint256 reserveOut, uint256 maximum)
        private
        pure
        returns (uint256)
    {
        if (reserveIn == 0 || reserveOut <= 1) return 0;
        uint256 minimum = Math.ceilDiv(reserveIn * 10_000, (reserveOut - 1) * 9_970);
        if (minimum > maximum) return 0;
        return bound(seed, minimum, maximum);
    }

    function _removable(DonationActor actor, uint256 seed) private view returns (uint256) {
        uint256 held = pair.sharesOf(address(actor));
        if (held == 0) return 0;
        (uint256 re, uint256 rt) = pair.getReserves();
        uint256 supply = pair.totalShares();
        uint256 minimum = Math.max(Math.ceilDiv(supply, re), Math.ceilDiv(supply, rt));
        if (minimum > held) return 0; // Dust cannot reach the ETH send at all.
        return bound(seed, minimum, held);
    }

    function _refundAmounts(DonationActor actor, uint256 tokenSeed, uint256 surplusSeed)
        private
        view
        returns (uint256 eth, uint256 tokens, uint256 used)
    {
        if (pair.totalShares() == 0 || address(actor).balance < 2) return (0, 0, 0);
        (uint256 re, uint256 rt) = pair.getReserves();
        uint256 minTokens = Math.mulDiv(Math.ceilDiv(re, pair.totalShares()), rt, re, Math.Rounding.Ceil);
        uint256 ethBudget = Math.min(100 ether, address(actor).balance);
        uint256 maximum = Math.min(5_000_000e18, token.balanceOf(address(actor)));
        maximum = Math.min(maximum, Math.mulDiv(ethBudget - 1, rt, re));
        if (minTokens > maximum) return (0, 0, 0);
        tokens = bound(tokenSeed, minTokens, maximum);
        used = Math.mulDiv(tokens, re, rt);
        eth = used + bound(surplusSeed, 1, ethBudget - used);
        assertGt(Math.mulDiv(eth, rt, re, Math.Rounding.Ceil), tokens, "must enter refund branch");
    }
}

contract MiniPairInvariantDonationsTest is Test {
    MiniSwapToken internal token;
    MiniPair internal pair;
    MiniPairDonationsHandler internal handler;

    function _deploy() internal {
        token = new MiniSwapToken();
        pair = new MiniPair(address(token), 30);
        handler = new MiniPairDonationsHandler(token, pair);
        for (uint256 i; i < 4; ++i) {
            token.transfer(address(handler.actors(i)), 100_000_000e18);
        }
    }

    function setUp() public {
        _deploy();
        // Start with donations before initialization and positions for EVERY actor, so exit and
        // failed-send probes are meaningful even in short fuzz sequences.
        handler.donateTokens(1, 1e18);
        handler.forceEth(1 ether);
        handler.addWithTokenSurplus(0, 10 ether, 1_000_000e18);
        for (uint256 i = 1; i < 4; ++i) {
            handler.addWithTokenSurplus(i, 1 ether, 1e18);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.addWithTokenSurplus.selector;
        selectors[1] = handler.addWithEthRefund.selector;
        selectors[2] = handler.remove.selector;
        selectors[3] = handler.buy.selector;
        selectors[4] = handler.sell.selector;
        selectors[5] = handler.donateTokens.selector;
        selectors[6] = handler.forceEth.selector;
        selectors[7] = handler.rejectRemove.selector;
        selectors[8] = handler.rejectSell.selector;
        selectors[9] = handler.rejectRefund.selector;
        selectors[10] = handler.plainEth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_reservesAreBackedAndEqualNetFlows() public view {
        (uint256 re, uint256 rt) = pair.getReserves();
        assertLe(re, address(pair).balance);
        assertLe(rt, token.balanceOf(address(pair)));
        assertEq(re, handler.ethIn() - handler.ethOut(), "ETH ghost flow mismatch");
        assertEq(rt, handler.tokenIn() - handler.tokenOut(), "token ghost flow mismatch");
        assertEq(address(pair).balance - re, handler.donatedEth(), "ETH donation escaped");
        assertEq(token.balanceOf(address(pair)) - rt, handler.donatedTokens(), "token donation escaped");
    }

    function invariant_quotesIgnoreDonations() public view {
        (uint256 re, uint256 rt) = pair.getReserves();
        if (re == 0 || rt == 0) {
            assertEq(pair.quoteEthToToken(1 ether), 0);
            assertEq(pair.quoteTokenToEth(1e18), 0);
        } else {
            uint256 inputWithFee = 1e18 * 9_970;
            assertEq(pair.quoteEthToToken(1 ether), Math.mulDiv(inputWithFee, rt, re * 10_000 + inputWithFee));
            assertEq(pair.quoteTokenToEth(1e18), Math.mulDiv(inputWithFee, re, rt * 10_000 + inputWithFee));
        }
    }

    function invariant_shareValueNeverFalls() public view {
        assertGe(handler.lastNormalizedK(), handler.lastKBefore());
    }

    function invariant_livePoolRetainsLockedLiquidity() public view {
        uint256 supply = pair.totalShares();
        uint256 sum = pair.sharesOf(address(0));
        for (uint256 i; i < 4; ++i) {
            sum += pair.sharesOf(address(handler.actors(i)));
        }
        assertEq(sum, supply);
        if (handler.everLive()) {
            assertGe(supply, 1_000);
            assertEq(pair.sharesOf(address(0)), 1_000);
            (uint256 re, uint256 rt) = pair.getReserves();
            assertGt(re, 0);
            assertGt(rt, 0);
        }
    }

    function invariant_failedEthSendsAreAtomic() public view {
        assertEq(handler.failedStateAfter(), handler.failedStateBefore());
    }

    /// @dev Execute each full exit against the SAME state, then restore it. Merely summing
    /// calculated pro-rata amounts would never detect a removeLiquidity overpayment bug.
    function invariant_allExitClaimsAreBoundedByReserves() public {
        uint256 supply = pair.totalShares();
        if (supply == 0) return;
        (uint256 re, uint256 rt) = pair.getReserves();
        uint256 ethClaims = Math.mulDiv(pair.sharesOf(address(0)), re, supply);
        uint256 tokenClaims = Math.mulDiv(pair.sharesOf(address(0)), rt, supply);
        for (uint256 i; i < 4; ++i) {
            DonationActor actor = handler.actors(i);
            uint256 shares = pair.sharesOf(address(actor));
            uint256 ethCap = Math.mulDiv(shares, re, supply);
            uint256 tokenCap = Math.mulDiv(shares, rt, supply);
            ethClaims += ethCap;
            tokenClaims += tokenCap;
            if (shares != 0) _probeExit(actor, shares, ethCap, tokenCap);
        }
        assertLe(ethClaims, re, "aggregate ETH claims exceed reserves");
        assertLe(tokenClaims, rt, "aggregate token claims exceed reserves");
    }

    function _probeExit(DonationActor actor, uint256 shares, uint256 ethCap, uint256 tokenCap) internal {
        uint256 snapshot = vm.snapshotState();
        bytes32 before = handler.stateHash();
        uint256 ethBefore = address(actor).balance;
        uint256 tokensBefore = token.balanceOf(address(actor));
        bool dust = ethCap == 0 || tokenCap == 0;
        try actor.remove(shares) returns (uint256 eth, uint256 tokens) {
            assertFalse(dust || actor.rejectsEth(), "exit unexpectedly succeeded");
            assertLe(eth, ethCap, "exit ETH overpayment");
            assertLe(tokens, tokenCap, "exit token overpayment");
            assertEq(address(actor).balance - ethBefore, eth);
            assertEq(token.balanceOf(address(actor)) - tokensBefore, tokens);
            assertEq(pair.sharesOf(address(actor)), 0, "full exit did not burn all shares");
        } catch (bytes memory reason) {
            assertTrue(dust || actor.rejectsEth(), "valid exit reverted");
            bytes4 expected = dust ? MiniPair.ZeroAmount.selector : MiniPair.EthTransferFailed.selector;
            assertEq(reason, abi.encodeWithSelector(expected));
            assertEq(handler.stateHash(), before, "failed full exit changed state");
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertEq(handler.stateHash(), before, "exit probe leaked state");
    }

    function _checkAll() internal {
        invariant_reservesAreBackedAndEqualNetFlows();
        invariant_quotesIgnoreDonations();
        invariant_shareValueNeverFalls();
        invariant_livePoolRetainsLockedLiquidity();
        invariant_failedEthSendsAreAtomic();
        invariant_allExitClaimsAreBoundedByReserves();
    }

    function test_mixedSequenceExercisesEveryAction() public {
        handler.donateTokens(2, 1_000_000e18);
        handler.forceEth(100 ether);
        handler.buy(3, 1 ether);
        handler.sell(1, 50_000e18);
        handler.addWithTokenSurplus(1, 1 ether, 1e18);
        handler.addWithEthRefund(2, 50_000e18, 1 ether);
        handler.rejectRemove(type(uint256).max);
        handler.rejectSell(50_000e18);
        handler.rejectRefund(50_000e18, 1 ether);
        handler.plainEth(0, 1 ether);
        handler.remove(0, pair.sharesOf(address(handler.actors(0))));
        _checkAll();
        assertEq(handler.initialDeposits(), 1);
        assertEq(handler.tokenSurplusDeposits(), 4);
        assertEq(handler.ethRefundDeposits(), 1);
        assertEq(handler.buys(), 1);
        assertEq(handler.sells(), 1);
        assertEq(handler.removals(), 1);
        assertEq(handler.failedRemovals(), 1);
        assertEq(handler.failedSells(), 1);
        assertEq(handler.failedRefunds(), 1);
        assertEq(handler.rejectedPlainEth(), 1);
        assertGt(handler.shareValueChecks(), 0);
    }

    function test_donationsBeforeDustSeedAndLastProviderExit() public {
        _deploy();
        handler.donateTokens(1, 1_000_000e18);
        handler.forceEth(100 ether);
        _checkAll();
        handler.addWithTokenSurplus(0, 1_001, 1_001);
        assertEq(pair.totalShares(), 1_001);
        assertEq(pair.sharesOf(address(handler.actors(0))), 1);
        handler.remove(0, 1);
        assertEq(pair.totalShares(), 1_000);
        (uint256 re, uint256 rt) = pair.getReserves();
        assertEq(re, 1_000);
        assertEq(rt, 1_000);
        _checkAll();
        // Reuse the pool when ONLY the permanent lock remains; neither deposit branch may
        // capture earlier donations or dilute the locked claim.
        handler.addWithEthRefund(1, 1_001, 1);
        handler.addWithTokenSurplus(2, 1_001, 1);
        handler.remove(1, pair.sharesOf(address(handler.actors(1))));
        handler.remove(2, pair.sharesOf(address(handler.actors(2))));
        assertEq(pair.totalShares(), 1_000);
        _checkAll();
    }

    function testFuzz_failedEthSendsRollbackWithDonations(uint256 shares, uint256 tokens, uint256 surplus) public {
        handler.donateTokens(0, tokens);
        handler.forceEth(surplus);
        handler.rejectRemove(shares);
        handler.rejectSell(tokens);
        handler.rejectRefund(tokens, surplus);
        assertEq(handler.failedRemovals(), 1, "remove did not reach ETH send");
        assertEq(handler.failedSells(), 1, "sell did not reach ETH send");
        assertEq(handler.failedRefunds(), 1, "deposit did not reach refund");
        _checkAll();
    }

    function test_oneShareDepositsRoundInBothBranches() public {
        _deploy();
        handler.addWithTokenSurplus(0, 1_001, 1_003);
        handler.donateTokens(0, 1e18);
        handler.forceEth(1 ether);

        // ceil(1 * 1003 / 1001) = 2 tokens, despite only one share being minted.
        handler.addWithTokenSurplus(1, 1, 1);
        (uint256 re, uint256 rt) = pair.getReserves();
        assertEq(re, 1_002);
        assertEq(rt, 1_005);
        assertEq(pair.sharesOf(address(handler.actors(1))), 1);
        _checkAll();

        // floor(2 * 1002 / 1005) = 1 wei used, with one wei refunded.
        handler.addWithEthRefund(2, 2, 1);
        (re, rt) = pair.getReserves();
        assertEq(re, 1_003);
        assertEq(rt, 1_007);
        assertEq(pair.sharesOf(address(handler.actors(2))), 1);
        assertEq(handler.tokenSurplusDeposits(), 1);
        assertEq(handler.ethRefundDeposits(), 1);
        _checkAll();
    }

    function test_fullExitProbeChecksZeroPayoutDustReverts() public {
        _deploy();
        handler.addWithTokenSurplus(0, 1_001, 4_004);
        assertEq(pair.totalShares(), 2_002);
        handler.remove(0, 1_001);
        assertEq(pair.sharesOf(address(handler.actors(0))), 1);
        (uint256 re, uint256 rt) = pair.getReserves();
        assertEq(re, 501);
        assertEq(rt, 2_002);
        // This remaining share's ETH claim rounds to zero. The full-exit probe must check
        // ZeroAmount and rollback, rather than accepting any revert or skipping the actor.
        handler.donateTokens(1, 1e18);
        handler.forceEth(1 ether);
        _checkAll();
    }
}
