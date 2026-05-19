# <img src="assets/SPRY-Logo.png" width="28" height="28"> Spry

**A dynamic-fee Uniswap V4 hook that protects liquidity providers from
arbitrage-driven impermanent loss.**

Spry is a small periphery (one hook + one router + four libraries) deployed
on top of the canonical Uniswap V4 `PoolManager`. Pools that use the Spry
hook charge takers a fee that scales with how much each individual swap
shifts the pool's price — small swaps pay the standard 0.30 %, arbitrage-
sized swaps pay up to 5.5 %. The excess goes back to LPs through V4's normal
fee path. The economic mechanism is described in detail in
[`assets/Spry-Whitepaper.md`](assets/Spry-Whitepaper.md).

## What's in this repo

```
contracts/
├── SpryHook.sol                  IHooks impl, returns dynamic fee from beforeSwap
├── SpryRouter.sol                Periphery router: single + multi-hop swap, add / remove liquidity
├── HookMiner.sol                 CREATE2 salt miner for the hook's permission bits
├── ModifiedERC6909.sol           Per-(poolId, holder) LP-share ledger inherited by SpryRouter
└── libs/
    ├── SmartFeeLib.sol           Three-zone dynamic-fee curve (safe / alert / danger)
    ├── VirtualReserves.sol       (sqrtPriceX96, liquidity) → uniform-liquidity (R0, R1)
    └── SafeTransfer.sol          ERC20 helpers tolerant of non-standard tokens

script/
└── DeploySpry.s.sol              CREATE2 deploy script that mines the hook salt

test/
├── SmartFeeLibTest                19 tests   fee curve, every zone, fuzz bounds
├── SpryHookTest                    8 tests   integration via PoolModifyLiquidityTest + PoolSwapTest
├── SpryHookCoverageTest           10 tests   no-op IHooks entry points + access control
├── SpryHookZonesTest              10 tests   each fee zone via SpryHook.beforeSwap
├── SpryRouterSingleTest            7 tests   single-hop happy paths + reverts
├── SpryRouterMultiTest             6 tests   multi-hop atomic paths
├── SpryRouterLiquidityTest         7 tests   add / remove + slippage + deadline
├── SpryRouterBranchTest            4 tests   native ETH refund / invalid callback tag
├── SpryRouterERC6909Test           9 tests   LP-share transfer / approve / burn-by-recipient
├── ERC6909Test                    14 tests   ModifiedERC6909 primitives via mock
├── HookMinerTest                   5 tests   salt mining, CREATE2 verification
├── SafeTransferTest               11 tests   USDT-style, false-return, reverting, ETH rejecter
├── ParityTest                      6 tests   native ETH pool, multi-pool isolation, V4 lock
├── ForkTest                        3 tests   live PoolManager (skips when FORK_RPC_URL unset)
└── Invariants                      4 tests   handler-driven fuzz, 128k random ops, 0 violations

Total: 123 tests / 15 suites
```

## Build & test

```bash
forge install              # pulls v4-core, v4-periphery, openzeppelin, prb-math, forge-std
forge build                # compiles against canonical V4
forge test                 # runs the whole suite
forge coverage             # line/branch/function coverage (no via_ir for accuracy)
```

The repository uses Foundry. The default profile pins `evm_version = "cancun"`
and turns `via_ir` off so `forge coverage` produces accurate line numbers.

## How a pool uses Spry

1. Deploy `SpryHook` at an address whose low 14 bits equal
   `Hooks.BEFORE_SWAP_FLAG = 0x80`. Use `script/DeploySpry.s.sol`, which mines
   the CREATE2 salt automatically against the canonical `PoolManager` address
   for the target chain.
2. Initialize a pool whose `PoolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG`
   (`0x800000`) and `PoolKey.hooks = SpryHook`. The dynamic-fee flag is what
   tells V4 to consult the hook for the fee on every swap.
3. Add liquidity through `SpryRouter.addLiquidity` (full-range positions only)
   or, equivalently, mint a full-range position through the canonical V4
   `PositionManager`.

That's it — no custom router on the user side is required; any V4-compatible
router can swap against a Spry pool and the hook will price every swap
correctly.

## Why a hook?

Delivering Spry as a Uniswap V4 hook rather than a standalone AMM means:

- Zero pool-storage / swap-math attack surface — those live in V4 core, which
  is already widely audited and deployed.
- First-class native ETH, multi-hop, ERC-6909 claim tokens, and flash
  accounting come for free.
- Pools are routable from every V4-aware router and aggregator on day one.

Spry pools operate in **full-range** mode (`tickLower = MIN_USABLE_TICK`,
`tickUpper = MAX_USABLE_TICK`), which makes liquidity uniform across the
entire price range. Under that constraint the swap math reduces to the
constant-product `x · y = k` at the current price, which is the regime the
SmartFee derivation operates on.

## Status

- **123 unit + integration + invariant tests passing**, ~100 % line and
  function coverage on every library; invariants verified across 128 000
  random handler operations with zero violations.
- **Not yet externally audited.** Do not deploy with material user funds
  until an independent audit is complete. See the whitepaper, section
  *"Pre-deployment checklist"*, for the recommended steps.
- **No mainnet deployment.** Authoritative addresses, when they exist, will
  be published in this README alongside the audit report and deployment tag.

## License

GPL-3.0-or-later (see `LICENSE`).
