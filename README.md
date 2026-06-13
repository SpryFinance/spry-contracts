# <img src="assets/SPRY-Logo.png" width="28" height="28"> Spry

**A tiered dynamic-fee Uniswap V4 hook with path-independent MEV
protection within a block window.**

Spry is a small periphery (one hook + one swap-only router + three
libraries) deployed against the canonical Uniswap V4 `PoolManager`. Pools
that use the Spry hook charge takers a fee that scales with how much each
swap shifts the pool's price *and* with how much the same block has
already shifted it. Small swaps pay the tier's base rate (1 to 100 bps);
arbitrage-sized swaps pay up to 9.9 %. The excess accrues to LPs through
V4's standard fee channel.

The economic mechanism is described in detail in the whitepaper, available
as a print-ready **[PDF](assets/Spry-Whitepaper.pdf)** (with figures) or as
**[Markdown](assets/Spry-Whitepaper.md)** (renders inline on GitHub). Both
cover the same design; the Markdown is the longer, reference-grade version
and the PDF is a concise, figure-driven companion.

## Headline properties

- **Five tier-aware fee curves** dispatched by `PoolKey.tickSpacing`
  (STABLE / LIKE-ASSET / BLUE-CHIP / VOLATILE / EXOTIC, matching the
  V3 fee-tier convention).
- **Four-zone piecewise curve** per tier: a flat **safe** zone, a
  **linear alert** ramp, an **exponential danger** ramp, and a flat
  **cap** beyond `dangerHigh`.
- **Per-pool signed cumulative tracker** (one storage slot per pool)
  that resets every `BLOCK_WINDOW` blocks. The window length is a
  per-chain `immutable` set at deployment so the same wall-clock
  attack horizon (one multicall, one Flashbots-style bundle) is
  covered on every chain (see SpryHook's NatSpec for the recommended
  per-chain values). Each swap's fee is computed against the running
  cumulative, not the swap in isolation.
- **Integral-mode marginal fee**: the rate charged for a swap is the
  *average* of the underlying curve over the cumulative interval the
  swap traverses. Splitting a same-direction swap into N pieces inside
  one window costs **at least as much** as one big swap: the
  splitting-attack-resistance theorem is path-independence of the
  integral.
- **Three-case dispatch** (Growth / Unwind / Flip): the unwind half of
  a sign-flip is charged at the tier's `safeFee`, so users who push
  the pool back toward neutral are never penalised.
- **Swap-only router; LP through Uniswap's canonical
  `PositionManager`**. Per-owner V4 position salts give correct
  pro-rata fee accounting without Spry maintaining its own ledger.

## What's in this repo

```
contracts/
├── SpryHook.sol                  IHooks impl: beforeSwap dispatches to
│                                  SmartFeeLib, returns the dynamic fee
│                                  OR'd with V4's OVERRIDE_FEE_FLAG.
│                                  Holds the 5-tier param registry +
│                                  per-pool cumulative-delta window.
├── SpryRouter.sol                Swap-only periphery: single + multi-
│                                  hop, exactIn / exactOut, native ETH,
│                                  Permit + Permit2.
└── libs/
    ├── SmartFeeLib.sol           Fee math: getDynamicFee,
    │                              computeSignedDelta, feeForDelta, and
    │                              the integral-mode marginalFee with
    │                              per-zone antiderivative helpers.
    ├── SpryFeeTypes.sol          SpryFeeParams struct (zone bounds +
    │                              linear / exp coefficients + safeFee /
    │                              capFee).
    └── VirtualReserves.sol       (sqrtPriceX96, liquidity) → (R0, R1).

script/
├── DeploySpry.s.sol              CREATE2 deploy script that mines the
│                                  hook salt.
└── HookMiner.sol                 CREATE2 salt miner for the hook's
                                   permission bits.

test/
├── unit/             6 suites    SmartFeeLib + integral-mode math +
│                                  hook coverage (incl. poolWindow getter,
│                                  cum saturation) + miner.
├── integration/     14 suites    Router single + multi + branches,
│                                  Permit, Permit2, Quoter,
│                                  PositionManager interop (full-range +
│                                  concentrated), tier dispatch,
│                                  swap-shape matrix, gas regression,
│                                  V4 hook surface, SpryFee event
│                                  semantics.
├── scenarios/       18 suites    Attack simulations: sandwich, JIT,
│                                  gas-grief, reentrancy, donation,
│                                  recipient-is-self, first-mint
│                                  inflation, asymmetric decimals,
│                                  cumulative-fee behavior (Growth/
│                                  Unwind/Flip, left + right),
│                                  multi-window-length,
│                                  IntegralPathIndependence, …
├── fuzz/             2 suites    Handler-driven stateful invariants:
│                                  single-pool + two-pool (128k random
│                                  ops per invariant, 0 violations).
├── fork/             2 suites    Live PoolManager smoke tests
│                                  (skipped when FORK_RPC_URL unset).
└── utils/                         LPHelper: per-owner-salt LP shim
                                   used by tests, mirroring
                                   PositionManager's fairness model.

Total: 42 suites / 264 tests
```

Production SLOC: **1 037**.
Test SLOC: **6 540**.

## Build & test

```bash
forge install     # pulls v4-core, v4-periphery, openzeppelin, prb-math, forge-std, permit2
forge build       # compiles against canonical V4
forge test        # runs the whole suite
forge coverage    # line/branch/function coverage (no via_ir for accuracy)
```

The repository uses Foundry. The default profile pins
`evm_version = "cancun"` and turns `via_ir` off so `forge coverage`
produces accurate line numbers. Fork tests are auto-skipped unless
`FORK_RPC_URL` is set.

## How a pool uses Spry

1. **Deploy the hook**. The deployed address must have its low 14 bits
   match `Hooks.BEFORE_SWAP_FLAG`. Use `script/DeploySpry.s.sol`, which
   mines the CREATE2 salt against the canonical `PoolManager` address
   for the target chain. The operator must also set `SPRY_BLOCK_WINDOW`
   to the chain-appropriate value (the `immutable` window length that
   the cumulative tracker uses; see the comment on
   `SpryHook.BLOCK_WINDOW` for recommended per-chain numbers).
2. **Pick a tier**. Set `PoolKey.tickSpacing` to one of `{1, 10, 60,
   200, 1000}`; that picks the dispatched fee curve (STABLE / LIKE-
   ASSET / BLUE-CHIP / VOLATILE / EXOTIC). Spry rejects other
   tickSpacings with `InvalidTier` on the first swap.
3. **Set the dynamic-fee flag**. Initialize a pool whose
   `PoolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`) and
   `PoolKey.hooks = SpryHook`. The flag tells V4 to consult the hook
   for the fee on every swap.
4. **Add liquidity through PositionManager**. Spry's router is swap-
   only; LP positions go through Uniswap's canonical V4
   `PositionManager`. Full-range positions get the entire pool depth
   for the SmartFee curve to work against.

That's it: no custom router on the taker side is required; any V4-
aware router or aggregator can swap against a Spry pool and the hook
will price every swap correctly.

## Why a hook?

Delivering Spry as a Uniswap V4 hook rather than a standalone AMM
means:

- Zero pool-storage / swap-math attack surface: those live in V4
  core, which is widely audited and deployed.
- First-class native ETH, multi-hop, ERC-6909 claim tokens, and flash
  accounting come for free.
- Pools are routable from every V4-aware router and aggregator on day
  one.

Spry pools operate in **full-range** mode (`tickLower = MIN_USABLE_TICK`,
`tickUpper = MAX_USABLE_TICK`), making liquidity uniform across the
entire price range. Under that constraint the swap math reduces to the
constant-product `x · y = k` at the current price, the regime the
SmartFee derivation operates on.

## Scripts

All scripts read addresses and keys from `.env` (see `.env.example`). On
Unichain Sepolia, run with `--rpc-url unichain_sepolia --broadcast`.

- `script/DeploySpry.s.sol`: deploy SpryHook (salt-mined) and SpryRouter.
- `script/SeedPool.s.sol`: deploy and mint two mock ERC20s, create a Spry pool,
  and seed a full-range position. Optional env: `TICK_SPACING` (tier, default
  60), `MINT_AMOUNT`, `LIQUIDITY`, `SQRT_PRICE_X96`.
- `script/RemoveLiquidity.s.sol`: remove liquidity from a pool given
  `TOKEN0`/`TOKEN1` and either `LIQUIDITY` (capped at your balance) or
  `REMOVE_ALL=true`. Optional `TICK_SPACING` (default 60).
- `script/SmartSwap.s.sol`: swap given only `TOKEN_IN`/`TOKEN_OUT`. It
  auto-detects the pool tier and defaults the amount to your full `TOKEN_IN`
  balance, routing through SpryRouter. Optional `AMOUNT_IN`, `TICK_SPACING`.
- `script/MintTokens.s.sol`: mint a `MintableERC20` (deployed by SeedPool) to
  any address. Env: `TOKEN`, `TO`, optional `AMOUNT` (default 1e21).
- `script/RevokeApprovals.s.sol`: reset a token's ERC20 allowance to 0. Env:
  `TOKEN`; optional `SPENDER` (default: revokes SpryRouter and
  PoolModifyLiquidityTest).
- `script/AddLiquidityTokens.s.sol`: create (if needed) and seed a token/token
  pool from existing tokens. Env: `TOKEN0`, `TOKEN1`, `AMOUNT0`, `AMOUNT1`;
  optional `TICK_SPACING`, `SQRT_PRICE_X96`.
- `script/AddLiquidityETH.s.sol`: create (if needed) and seed an ETH/token pool
  (native ETH is currency0). Env: `TOKEN`, `ETH_AMOUNT`, `TOKEN_AMOUNT`;
  optional `TICK_SPACING`, `SQRT_PRICE_X96`.

`AddLiquidity*` take existing token addresses (unlike `SeedPool`, which deploys
its own mocks) and add a full-range position sized by the amounts you pass. For
a new pool the initial price defaults to the amount ratio (override with
`SQRT_PRICE_X96`). Positions use the same per-owner salt as `SeedPool`, so
`RemoveLiquidity` can unwind them (pass `TOKEN0=0x0000...0000` for the ETH leg).

The seed and remove scripts use the canonical V4 `PoolModifyLiquidityTest`
router for liquidity (simple full-range testnet seeding); production LP goes
through Uniswap's `PositionManager`. Example:

```bash
TOKEN0=0x.. TOKEN1=0x.. REMOVE_ALL=true \
  forge script script/RemoveLiquidity.s.sol:RemoveLiquidity \
    --rpc-url unichain_sepolia --broadcast
```

## Deployments

### Unichain Sepolia (chain id 1301)

Testnet only, verified on Uniscan. Not audited; do not use with material
funds.

| Contract | Address |
|----------|---------|
| SpryHook | [`0x68ba5F1A761253c7c169F3Fde5b715c027814080`](https://sepolia.uniscan.xyz/address/0x68ba5F1A761253c7c169F3Fde5b715c027814080) |
| SpryRouter | [`0xd887e2d555f98CB76AE3d0755Af7DdDC503EF017`](https://sepolia.uniscan.xyz/address/0xd887e2d555f98CB76AE3d0755Af7DdDC503EF017) |

Deployed with `BLOCK_WINDOW = 60` against the canonical Uniswap V4 contracts
on Unichain Sepolia: PoolManager `0x00b036b58a818b1bc34d502d3fe730db729e62ac`,
PositionManager `0xf969aee60879c54baaed9f3ed26147db216fd664`, Permit2
`0x000000000022D473030F116dDEE9F6B43aC78BA3`. The hook address's low 14 bits
equal `0x0080` (it ends in `4080`), encoding the required `BEFORE_SWAP`
permission flag. Deploy block (subgraph `startBlock`): `54497329`.

### Base Sepolia (chain id 84532)

Testnet only, verified on BaseScan. Not audited; do not use with material
funds.

| Contract | Address |
|----------|---------|
| SpryHook | [`0x43C99D40E2E7FBa44435bFC6Da57a74d38fD0080`](https://sepolia.basescan.org/address/0x43C99D40E2E7FBa44435bFC6Da57a74d38fD0080) |
| SpryRouter | [`0xd4Af9FFDf2067d4CA422526D308E08CDBE690642`](https://sepolia.basescan.org/address/0xd4Af9FFDf2067d4CA422526D308E08CDBE690642) |

Deployed with `BLOCK_WINDOW = 30` against the canonical Uniswap V4 contracts
on Base Sepolia: PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`,
PositionManager `0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80`, Permit2
`0x000000000022D473030F116dDEE9F6B43aC78BA3`. The hook address ends in
`0080`, encoding the required `BEFORE_SWAP` permission flag. Deploy block
(subgraph `startBlock`): `42508548`.

## Status

- **264 unit + integration + scenario + invariant + fork tests
  passing**, ~100 % line and function coverage on every library;
  the four single-pool and four two-pool invariants are each verified
  across 128 000 random handler operations (256 rounds × 500 calls)
  with zero violations.
- **Not yet externally audited.** Do not deploy with material user
  funds until an independent audit is complete.
- **No mainnet deployment.** Verified Unichain Sepolia and Base Sepolia
  testnet deployments are live (see Deployments above). Mainnet addresses,
  when they exist, will be published here alongside the audit report and
  deployment tag.

## License

GPL-3.0-or-later (see `LICENSE`).
