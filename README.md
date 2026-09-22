# Mini Swap ($MSWAP) — launch token and MiniPair

Two contracts for the Mini Swap test launch on Sepolia (chainId 11155111), built with Foundry and
the vendored OpenZeppelin Contracts v5.0.2:

| Contract | File | Role |
| --- | --- | --- |
| `MiniSwapToken` | `src/MiniSwapToken.sol` | Fixed-supply ERC-20 launch token, name **Mini Swap**, symbol **MSWAP**, 18 decimals |
| `MiniPair` | `src/MiniPair.sol` | Adminless constant-product ETH/MSWAP pool with internal LP share accounting |

This assignment delivers the contracts, their tests and the compiler-derived ABIs. It does not
write `launch.json` (a separate manifest assignment does), does not deploy, and does not hold or
use any wallet key.

## Build and test (offline)

Requirements: Foundry (`forge`, `cast`) with Solidity 0.8.26 already in its compiler cache.
Python 3 is used only by the ABI export helper. No network, RPC, fork, `.env` file or package
manager is needed; every dependency is an ordinary file under `lib/`.

```sh
forge build
forge test
forge fmt --check
scripts/export_abis.sh --check   # optional: confirm docs/abi/*.json match the compiler output
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer at 200 runs,
`via_ir = false`, `bytecode_hash = "none"`, `cbor_metadata = false`, `offline = true`, `ffi = false`
and an empty `fs_permissions`. Fuzz runs use a fixed seed so results reproduce.

Validated locally with Foundry 1.8.3: 53 tests (9 token, 43 pair unit/fuzz, 1 invariant suite with
4 invariants over 64 runs × 48 calls) pass, `forge fmt --check` is clean, and the protected
`Token.protected.t.sol` / `Project.protected.t.sol` floors pass when run against the actual
creation codes with a CREATE2 stand-in factory.

`forge build` prints three classes of lint warnings for `MiniPair`
(`reentrancy-eth`, `reentrancy-events`, `arbitrary-send-eth`). They are heuristic: every state
change and event in `MiniPair` happens before the external calls, every ETH-sending function is
`nonReentrant`, and ETH is only ever sent to `msg.sender` of that same call. The reentrancy tests
in `test/MiniPair.t.sol` demonstrate the guard. The lints are left enabled so a reviewer sees them.

## MiniSwapToken

- `constructor()` takes no arguments and no ETH; it mints `TOTAL_SUPPLY = 10^27` minor units
  (1,000,000,000 MSWAP) to `msg.sender`. At launch that caller is the ProjectFactory.
- Plain OpenZeppelin `ERC20`, nothing overridden. No owner, mint, burn, pause, blacklist, tax,
  initializer, proxy or upgrade path. Supply is constant after construction.
- Runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

## MiniPair

`constructor(address token, uint256 feeBps)`, nonpayable, static words only. The manifest passes
`$token` and `30` (0.30%). The constructor reverts on a zero token address or `feeBps > 1000`
(10%), and does nothing else: no ETH, no initialization call, no owner.

### Behaviour

- **Reserves are internal.** `_reserveEth` / `_reserveToken` change only through the four
  actions below. ETH or tokens sent to the contract by other means do not move prices or payouts;
  they are stranded (there is no `receive`, so plain ETH transfers revert; ETH can still be forced
  in via `SELFDESTRUCT`, and tokens via `transfer`). There is no skim/sync/rescue function.
- **`addLiquidity(uint256 tokenAmount, uint256 minShares) payable → shares`**
  - First deposit: uses all ETH and all `tokenAmount`, mints `sqrt(eth * token)` shares and
    permanently locks `MINIMUM_SHARES = 1000` of them to `address(0)`. Deposits whose square root
    is not above 1000 revert.
  - Later deposits keep the current ratio. `tokenAmount` is a **cap**: if it covers the ETH sent,
    all ETH is used and **only the needed tokens are pulled** (rounded up in the pool's favour).
    If it does not, all offered tokens are pulled and the **unneeded ETH is refunded** in the same
    call. Shares are `min(ethUsed * total / reserveEth, tokenUsed * total / reserveToken)`. The
    call reverts if either side rounds to zero or `shares < minShares`.
  - Tokens are pulled with `transferFrom`, so the caller must approve the pair first. The pull
    verifies the received amount and reverts on fee-on-transfer or rebasing tokens.
- **`removeLiquidity(uint256 shares, uint256 minEth, uint256 minToken) → (ethOut, tokenOut)`**
  burns shares and pays `shares / totalShares` of each reserve, floored. Reverts if either payout
  is zero or below its minimum, or if the caller holds fewer shares. Removing every share a provider
  owns returns their funds minus the slice owned by the locked minimum (plus at most 1 wei rounding
  per asset), so the pool never returns to the empty-pool code path.
- **`swapExactETHForTokens(uint256 minOut) payable`** and
  **`swapExactTokensForETH(uint256 amountIn, uint256 minOut)`** apply
  `out = in·(10000−feeBps)·reserveOut / (reserveIn·10000 + in·(10000−feeBps))`. The fee stays in
  the pool; `k = reserveEth · reserveToken` never decreases. Reverts on an empty pool, zero input,
  zero output, or `out < minOut`.
- **Views:** `getReserves()`, `quoteEthToToken(ethIn)`, `quoteTokenToEth(tokenIn)` (both return
  0 for zero input or an empty pool), `sharesOf(address)`, `totalShares()`, plus `token()`,
  `feeBps()`, `BPS`, `MAX_FEE_BPS`, `MINIMUM_SHARES`.
- **Events:** `LiquidityAdded`, `LiquidityRemoved`, `Swap`, `Sync` (new reserves after every
  state change).
- **Reentrancy:** all four state-changing functions are `nonReentrant` (OpenZeppelin
  `ReentrancyGuard`). Effects precede interactions; ETH is sent with a plain `call` and any failure
  reverts the whole action (`EthTransferFailed`). A receiver that re-enters or rejects ETH cannot
  complete the transaction.
- **Share inflation:** because reserves are internal, donating assets does not raise the share
  price, and the locked minimum keeps the first depositor from owning a share worth more than the
  dust they paid. `test_firstDepositorInflationAttackIsNotProfitable` shows the attacker loses
  the donation and the victim recovers their deposit.

### What the tests cover

`test/MiniSwapToken.t.sol`: metadata, supply minted to the deployer, argument-free creation code,
no admin/mint selectors, exact transfers and allowances, revert paths, opcode scan, supply
conservation fuzz.

`test/MiniPair.t.sol`: constructor validation (zero token, fee bound, nonpayable), plain ETH
transfer rejection, first deposit math and the locked minimum, later deposits in both directions
(pull-only-needed tokens, refund excess ETH), `minShares`, missing approval, refund to a rejecting
receiver, fee-on-transfer rejection, proportional and full removal, `minEth`/`minToken`, removal
above balance, failed ETH send on removal, swap output equals quote, k strictly increases by the
fee, slippage reverts (including after a front-run), empty pool and zero-input reverts, fee accrual
to providers, ETH and token donations leaving quotes and reserves untouched, first-depositor
inflation attack, reentrancy through `removeLiquidity`, `swapExactTokensForETH` and the
`addLiquidity` refund (both bubbling and caught variants), and fuzz tests: k never decreases over
random swap sequences, ETH and token round trips never profit, add-then-remove never profits and
never lowers the share price for existing providers, quotes always match executed swaps, first
deposit shares follow the square root.

`test/MiniPair.invariant.t.sol`: a handler drives four actors through valid adds, removes and
swaps; invariants check reserves equal real balances and net flows, shares are conserved with the
minimum still locked, and quotes follow the constant-product formula on internal reserves.

## Deployment parameters (for the manifest assignment and reviewers)

| Item | Value |
| --- | --- |
| Chain | Sepolia, chainId 11155111 |
| Token contract | `MiniSwapToken`, name `Mini Swap`, symbol `MSWAP`, decimals 18, no constructor args |
| Expected supply | `1000000000000000000000000000` (10^27) minted to the factory |
| Application contract | `MiniPair`, constructor `(address token, uint256 feeBps)` = `[$token, 30]` |
| Dependency order | token first, then `MiniPair` (it only references `$token`) |
| Privileged roles | none in either contract; no `$owner` argument exists |
| Constructor ETH | none; the pool starts empty |
| Runtime size | `MiniPair` ≈ 5.0 KB, `MiniSwapToken` ≈ 1.7 KB (both far below EIP-170) |
| Compiler | solc 0.8.26, cancun, optimizer 200 runs, `bytecode_hash = "none"`, no CBOR metadata |
| ABIs | `docs/abi/MiniSwapToken.json`, `docs/abi/MiniPair.json`; canonical keccak256 in `docs/abi-hashes.json` |
| Vendored sources | `docs/dependencies.json` lists every file under `lib/` with its upstream tag and SHA-256 |

Pool policy items (native ETH pool, fee 3000, tickSpacing 60, opening FDV, reward splits) are
supplied by the pinned policy and the manifest; nothing in these contracts encodes them.

## Assumptions and operational responsibilities

- **Empty at launch.** The factory does not seed `MiniPair`; the first `addLiquidity` by any user
  sets the initial price. The frontend must present the empty-pool state clearly. Whoever seeds
  the pool should do so at a price consistent with the protocol pool, or arbitrage will move it.
- **No operator controls.** Nothing can pause, upgrade, change the fee, recover stranded assets or
  withdraw on behalf of users. Bugs found after deployment cannot be patched in place; the only
  remedy is to deploy a new pair and have providers migrate.
- **Slippage is the user's job.** All actions take minimum-output / minimum-share arguments. The
  frontend must derive them from a live quote; passing zero exposes the user to sandwiching.
- **Approve before spending tokens.** `addLiquidity` and `swapExactTokensForETH` pull tokens with
  `transferFrom`; the caller needs an allowance at least equal to the amount pulled (for
  `addLiquidity`, the needed amount, at most `tokenAmount`).
- **Smart-contract callers must accept ETH.** Refunds and payouts go to `msg.sender`; a contract
  without a payable `receive`/`fallback` cannot remove liquidity or sell tokens.
- **Dust positions.** Shares whose proportional payout on either side floors to zero cannot be
  removed until reserves grow; the locked 1000 shares are unrecoverable by design.
- **Token must be a plain ERC-20.** The pair rejects tokens that deliver less than requested.
  MSWAP satisfies this; the constructor does not otherwise validate the token.
- **Not an audit.** Tests passing is not a security review. The workflow's independent review
  step must inspect these sources, the tests and the generated `launch.json` before the launch
  proceeds. Deployment, attestation, source publication and the frontend are handled by later
  services with their own authorization; this assignment neither broadcasts transactions nor
  touches keys.

## Layout

```
foundry.toml              pinned offline Foundry configuration
src/MiniSwapToken.sol     launch token
src/MiniPair.sol          ETH/MSWAP pool
test/                     Foundry tests (unit, fuzz, invariant) and test/mocks/ attackers
docs/abi/                 compiler-derived ABIs; docs/abi-hashes.json canonical hashes
docs/dependencies.json    provenance of every vendored file
scripts/export_abis.sh    regenerate or --check the ABI exports offline
lib/openzeppelin-contracts, lib/forge-std   vendored, unmodified upstream files
```
