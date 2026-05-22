# <img src="assets/SPRY-Logo.png" width="28" height="28"> Spry

**A tiered dynamic-fee Uniswap V4 hook with path-independent MEV
protection within a block window.**

Spry is a small periphery (one hook + one swap-only router + three
libraries) deployed against the canonical Uniswap V4 `PoolManager`. Pools
that use the Spry hook charge takers a fee that scales with how much each
swap shifts the pool's price *and* with how much the same block has
already shifted it. Small swaps pay the tier's base rate (1 – 100 bps);
arbitrage-sized swaps pay up to 9.9 %. The excess accrues to LPs through
V4's standard fee channel.

The economic mechanism is described in detail in
[`assets/Spry-Whitepaper.md`](assets/Spry-Whitepaper.md).

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
  one window costs **at least as much** as one big swap — the
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
│                                  hook coverage + miner.
├── integration/     12 suites    Router single + multi + branches,
│                                  Permit, Permit2, Quoter,
│                                  PositionManager interop, tier
│                                  dispatch, swap-shape matrix, V4 hook
│                                  surface.
├── scenarios/       17 suites    Attack simulations: sandwich, JIT,
│                                  gas-grief, reentrancy, donation,
│                                  recipient-is-self, first-mint
│                                  inflation, asymmetric decimals,
│                                  cumulative-fee behavior,
│                                  IntegralPathIndependence, …
├── fuzz/             1 suite     Handler-driven stateful invariants
│                                  (128k random ops, 0 violations).
├── fork/             2 suites    Live PoolManager smoke tests
│                                  (skipped when FORK_RPC_URL unset).
└── utils/                         LPHelper — per-owner-salt LP shim
                                   used by tests, mirroring
                                   PositionManager's fairness model.

Total: 38 suites / 224 tests
```

Production SLOC: **988**.
Test SLOC: **5 403**.

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
   the cumulative tracker uses — see the comment on
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

That's it — no custom router on the taker side is required; any V4-
aware router or aggregator can swap against a Spry pool and the hook
will price every swap correctly.

## Why a hook?

Delivering Spry as a Uniswap V4 hook rather than a standalone AMM
means:

- Zero pool-storage / swap-math attack surface — those live in V4
  core, which is widely audited and deployed.
- First-class native ETH, multi-hop, ERC-6909 claim tokens, and flash
  accounting come for free.
- Pools are routable from every V4-aware router and aggregator on day
  one.

Spry pools operate in **full-range** mode (`tickLower = MIN_USABLE_TICK`,
`tickUpper = MAX_USABLE_TICK`), making liquidity uniform across the
entire price range. Under that constraint the swap math reduces to the
constant-product `x · y = k` at the current price — the regime the
SmartFee derivation operates on.

## Status

- **224 unit + integration + scenario + invariant + fork tests
  passing**, ~100 % line and function coverage on every library;
  invariants verified across 128 000 random handler operations with
  zero violations across 256 fuzz runs.
- **Not yet externally audited.** Do not deploy with material user
  funds until an independent audit is complete.
- **No mainnet deployment.** Authoritative addresses, when they exist,
  will be published in this README alongside the audit report and
  deployment tag.

## License

GPL-3.0-or-later (see `LICENSE`).
