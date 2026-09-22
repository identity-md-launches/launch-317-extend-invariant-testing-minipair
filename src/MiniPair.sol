// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MiniPair: a tiny constant-product ETH / ERC-20 pool
/// @notice One pool pairing native ETH against a single ERC-20 token (the launch token MSWAP).
/// Liquidity providers hold internal shares; there is no separate LP token. Swaps follow x*y=k
/// with a fee of `feeBps` basis points on the input amount that stays in the pool for providers.
/// @dev Design notes:
/// - Adminless: no owner, no protocol fee, no pause, no upgrade, no rescue function.
/// - The constructor takes only static words (`token`, `feeBps`), is not payable and needs no
///   post-deploy initialization. The pool starts empty; the first user deposit sets the price.
/// - Reserves are tracked internally and never read from raw balances, so ETH or token sent to
///   the contract outside `addLiquidity` / swaps does not move quotes. Such donations are simply
///   stranded: there is no `receive` function, so plain ETH transfers revert.
/// - Every ETH-sending path (`addLiquidity` refund, `removeLiquidity`, `swapExactTokensForETH`)
///   is protected by a reentrancy guard and updates state before making external calls.
/// - The first deposit permanently locks `MINIMUM_SHARES` to address(0). Combined with internal
///   reserves this makes the classic share-inflation ("first depositor") attack unprofitable.
/// - Token pulls verify the received amount, so fee-on-transfer or rebasing tokens are rejected
///   rather than silently mis-accounted.
contract MiniPair is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------------------------

    /// @notice Basis-point denominator used for `feeBps`.
    uint256 public constant BPS = 10_000;

    /// @notice Upper bound for `feeBps` (10%). The launch uses 30 (0.30%).
    uint256 public constant MAX_FEE_BPS = 1_000;

    /// @notice Shares locked forever to address(0) on the first deposit.
    uint256 public constant MINIMUM_SHARES = 1_000;

    /// @notice The ERC-20 side of the pool.
    IERC20 public immutable token;

    /// @notice Swap fee in basis points of the input amount, retained by the pool.
    uint256 public immutable feeBps;

    // ---------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------

    uint256 private _reserveEth;
    uint256 private _reserveToken;

    /// @notice Total liquidity shares outstanding, including the locked minimum.
    uint256 public totalShares;

    /// @notice Liquidity shares held by each provider.
    mapping(address account => uint256 shares) public sharesOf;

    // ---------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------

    /// @notice Emitted when liquidity is added. `ethAmount` and `tokenAmount` are the amounts
    /// actually deposited (after refunding excess ETH / pulling only the needed tokens).
    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 tokenAmount, uint256 shares);

    /// @notice Emitted when liquidity is removed.
    event LiquidityRemoved(address indexed provider, uint256 ethAmount, uint256 tokenAmount, uint256 shares);

    /// @notice Emitted on every swap. Exactly one of (`ethIn`, `tokenIn`) and one of
    /// (`ethOut`, `tokenOut`) is non-zero.
    event Swap(address indexed trader, uint256 ethIn, uint256 tokenIn, uint256 ethOut, uint256 tokenOut);

    /// @notice Emitted after every state change with the new internal reserves.
    event Sync(uint256 reserveEth, uint256 reserveToken);

    // ---------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------

    error ZeroAddress();
    error FeeTooHigh(uint256 feeBps, uint256 maxFeeBps);
    error ZeroAmount();
    error InsufficientInitialLiquidity();
    error InsufficientShares(uint256 shares, uint256 minShares);
    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error InsufficientEthOut(uint256 ethOut, uint256 minEth);
    error InsufficientTokenOut(uint256 tokenOut, uint256 minToken);
    error PoolEmpty();
    error EthTransferFailed();
    error UnexpectedTokenAmount(uint256 expected, uint256 received);

    // ---------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------

    /// @param token_ The ERC-20 paired against ETH (the launch token; manifest passes `$token`).
    /// @param feeBps_ Swap fee in basis points, at most `MAX_FEE_BPS` (manifest passes 30).
    constructor(address token_, uint256 feeBps_) {
        if (token_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_, MAX_FEE_BPS);
        token = IERC20(token_);
        feeBps = feeBps_;
    }

    // ---------------------------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------------------------

    /// @notice Deposit ETH (as `msg.value`) and up to `tokenAmount` tokens for pool shares.
    /// @dev First deposit: uses all of `msg.value` and all of `tokenAmount`, mints
    /// sqrt(eth * token) shares, of which `MINIMUM_SHARES` are locked to address(0) forever.
    /// Later deposits: the pool keeps the current ratio. If the caller's tokens cover the ETH
    /// sent, all ETH is used and only the needed tokens are pulled (`tokenAmount` is a cap).
    /// Otherwise all tokens are pulled and the unneeded ETH is refunded to the caller.
    /// Token pulls use `transferFrom`, so the caller must approve this contract first.
    /// @param tokenAmount Maximum number of tokens to deposit.
    /// @param minShares Minimum shares to receive, otherwise the call reverts.
    /// @return shares Shares minted to the caller.
    function addLiquidity(uint256 tokenAmount, uint256 minShares)
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        if (msg.value == 0 || tokenAmount == 0) revert ZeroAmount();

        uint256 ethUsed;
        uint256 tokenUsed;
        uint256 supply = totalShares;

        if (supply == 0) {
            ethUsed = msg.value;
            tokenUsed = tokenAmount;
            uint256 initial = Math.sqrt(ethUsed * tokenUsed);
            if (initial <= MINIMUM_SHARES) revert InsufficientInitialLiquidity();
            shares = initial - MINIMUM_SHARES;
            // Permanently lock the minimum so the share price can never be inflated to absurd levels.
            sharesOf[address(0)] = MINIMUM_SHARES;
            supply = MINIMUM_SHARES;
        } else {
            uint256 reserveEth = _reserveEth;
            uint256 reserveToken = _reserveToken;
            // Tokens needed for all of msg.value at the current ratio, rounded up in the pool's favour.
            uint256 tokenOptimal = Math.mulDiv(msg.value, reserveToken, reserveEth, Math.Rounding.Ceil);
            if (tokenOptimal <= tokenAmount) {
                ethUsed = msg.value;
                tokenUsed = tokenOptimal;
            } else {
                // Not enough tokens for all the ETH: use every token, only the matching ETH.
                ethUsed = Math.mulDiv(tokenAmount, reserveEth, reserveToken);
                tokenUsed = tokenAmount;
            }
            if (ethUsed == 0 || tokenUsed == 0) revert ZeroAmount();
            shares = Math.min(Math.mulDiv(ethUsed, supply, reserveEth), Math.mulDiv(tokenUsed, supply, reserveToken));
        }

        if (shares == 0 || shares < minShares) revert InsufficientShares(shares, minShares);

        // Effects.
        sharesOf[msg.sender] += shares;
        totalShares = supply + shares;
        _reserveEth += ethUsed;
        _reserveToken += tokenUsed;

        emit LiquidityAdded(msg.sender, ethUsed, tokenUsed, shares);
        emit Sync(_reserveEth, _reserveToken);

        // Interactions.
        _pullTokens(msg.sender, tokenUsed);
        uint256 refund = msg.value - ethUsed;
        if (refund != 0) _sendEth(msg.sender, refund);
    }

    /// @notice Burn `shares` and receive the proportional ETH and tokens.
    /// @param shares Shares to burn.
    /// @param minEth Minimum ETH to receive, otherwise revert.
    /// @param minToken Minimum tokens to receive, otherwise revert.
    /// @return ethOut ETH sent to the caller.
    /// @return tokenOut Tokens sent to the caller.
    function removeLiquidity(uint256 shares, uint256 minEth, uint256 minToken)
        external
        nonReentrant
        returns (uint256 ethOut, uint256 tokenOut)
    {
        if (shares == 0) revert ZeroAmount();
        uint256 held = sharesOf[msg.sender];
        if (shares > held) revert InsufficientBalance(shares, held);

        uint256 supply = totalShares;
        ethOut = Math.mulDiv(shares, _reserveEth, supply);
        tokenOut = Math.mulDiv(shares, _reserveToken, supply);
        if (ethOut == 0 || tokenOut == 0) revert ZeroAmount();
        if (ethOut < minEth) revert InsufficientEthOut(ethOut, minEth);
        if (tokenOut < minToken) revert InsufficientTokenOut(tokenOut, minToken);

        // Effects.
        sharesOf[msg.sender] = held - shares;
        totalShares = supply - shares;
        _reserveEth -= ethOut;
        _reserveToken -= tokenOut;

        emit LiquidityRemoved(msg.sender, ethOut, tokenOut, shares);
        emit Sync(_reserveEth, _reserveToken);

        // Interactions.
        token.safeTransfer(msg.sender, tokenOut);
        _sendEth(msg.sender, ethOut);
    }

    // ---------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------

    /// @notice Swap all of `msg.value` ETH for tokens.
    /// @param minOut Minimum tokens to receive, otherwise revert.
    /// @return amountOut Tokens sent to the caller.
    function swapExactETHForTokens(uint256 minOut) external payable nonReentrant returns (uint256 amountOut) {
        if (msg.value == 0) revert ZeroAmount();
        uint256 reserveEth = _reserveEth;
        uint256 reserveToken = _reserveToken;
        if (reserveEth == 0 || reserveToken == 0) revert PoolEmpty();

        amountOut = _getAmountOut(msg.value, reserveEth, reserveToken);
        if (amountOut == 0 || amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        // Effects.
        _reserveEth = reserveEth + msg.value;
        _reserveToken = reserveToken - amountOut;

        emit Swap(msg.sender, msg.value, 0, 0, amountOut);
        emit Sync(_reserveEth, _reserveToken);

        // Interactions.
        token.safeTransfer(msg.sender, amountOut);
    }

    /// @notice Swap exactly `amountIn` tokens for ETH. Requires a prior approval.
    /// @param amountIn Tokens to sell.
    /// @param minOut Minimum ETH to receive, otherwise revert.
    /// @return amountOut ETH sent to the caller.
    function swapExactTokensForETH(uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        uint256 reserveEth = _reserveEth;
        uint256 reserveToken = _reserveToken;
        if (reserveEth == 0 || reserveToken == 0) revert PoolEmpty();

        amountOut = _getAmountOut(amountIn, reserveToken, reserveEth);
        if (amountOut == 0 || amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        // Effects.
        _reserveToken = reserveToken + amountIn;
        _reserveEth = reserveEth - amountOut;

        emit Swap(msg.sender, 0, amountIn, amountOut, 0);
        emit Sync(_reserveEth, _reserveToken);

        // Interactions.
        _pullTokens(msg.sender, amountIn);
        _sendEth(msg.sender, amountOut);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice Internal reserves. These, not raw balances, drive prices.
    function getReserves() external view returns (uint256 reserveEth, uint256 reserveToken) {
        return (_reserveEth, _reserveToken);
    }

    /// @notice Tokens received for `ethIn` ETH at current reserves; 0 if the pool is empty.
    function quoteEthToToken(uint256 ethIn) external view returns (uint256 tokenOut) {
        if (ethIn == 0 || _reserveEth == 0 || _reserveToken == 0) return 0;
        return _getAmountOut(ethIn, _reserveEth, _reserveToken);
    }

    /// @notice ETH received for `tokenIn` tokens at current reserves; 0 if the pool is empty.
    function quoteTokenToEth(uint256 tokenIn) external view returns (uint256 ethOut) {
        if (tokenIn == 0 || _reserveEth == 0 || _reserveToken == 0) return 0;
        return _getAmountOut(tokenIn, _reserveToken, _reserveEth);
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    /// @dev Constant-product output with the fee taken from the input and kept in the pool.
    /// Floor division guarantees (reserveIn + amountIn) * (reserveOut - out) >= reserveIn * reserveOut.
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) private view returns (uint256) {
        uint256 amountInWithFee = amountIn * (BPS - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BPS + amountInWithFee;
        return numerator / denominator;
    }

    /// @dev Pull `amount` tokens from `from` and verify the pool actually received that amount.
    function _pullTokens(address from, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert UnexpectedTokenAmount(amount, received);
    }

    /// @dev Send ETH with a plain call and revert on failure. Callers are `nonReentrant`.
    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
