# ABIs

Contract ABIs for off-chain consumers (subgraph, indexers, front-end,
scripts). Each file is a **bare ABI array**, the format `graph-cli`,
ethers, viem, and wagmi expect directly.

| File | Source | Role |
|------|--------|------|
| `SpryHook.json` | this repo | The Spry dynamic-fee hook. |
| `SpryRouter.json` | this repo | Swap-only periphery router. |
| `PoolManager.json` | canonical Uniswap V4 (`v4-core`) | Singleton that emits all pool events. |
| `PositionManager.json` | canonical Uniswap V4 (`v4-periphery`) | ERC-721 LP positions. |

The two V4 files are the **unmodified canonical contracts** Spry deploys
against; they are included here only because downstream indexers need them
in one place. They are not Spry code.

## Indexing note (read before building a subgraph)

`SpryRouter` emits no events. `SpryHook` emits **one** event, the
canonical off-chain signal for Spry-specific analytics that V4's `Swap`
event cannot carry:

```solidity
event SpryFee(
    PoolId indexed id,    // bytes32, topic1
    int256 cumBefore,     // signed block-windowed cumulative, pre-swap
    int256 cumAfter,      // post-swap (== persisted signedCum)
    uint24 fee,           // resolved LP fee in pips, OVERRIDE flag stripped
    uint8  zone,          // 0 safe / 1 alert / 2 danger / 3 cap (of cumAfter)
    uint8  dispatchCase,  // 0 Growth / 1 Unwind / 2 Flip
    uint64 windowId       // active window's start block (windowStart)
);
```

Field semantics you can rely on:

- **Pairing.** `SpryFee` is emitted in `beforeSwap`, immediately before
  V4's `Swap` event for the same pool. Pair each `Swap` with the
  immediately-preceding `SpryFee` of the same `id` in the same transaction.
  A multi-hop swap produces one `(SpryFee, Swap)` pair per hop, in hop
  order.
- **`fee`** is the clean per-swap dynamic LP fee in pips (1e6 = 100%) with
  the `OVERRIDE_FEE_FLAG` already removed. On Spry pools it equals
  `Swap.fee` (there is no protocol fee; see invariants below).
- **`cumAfter`** equals the pool's persisted `signedCum` after the swap and
  chains: `cumAfter` of swap _N_ == `cumBefore` of swap _N+1_ within a
  window. On the first swap of a new window, `cumBefore == 0` (lazy reset).
- **`zone`** is the curve zone of `cumAfter` (where the pool sits now). In
  integral mode the charged `fee` is the *average* of the curve over
  `[cumBefore, cumAfter]` and may span zones, so `zone` is a descriptive
  label of the endpoint; don't re-derive `fee` from it.
- **`windowId`** (= `windowStart` block) groups every observation in one
  block-window; you don't need to read `BLOCK_WINDOW` to bucket windows.

The rest of the indexing model uses **canonical V4 events** from
`PoolManager` and `PositionManager`:

| Event (source) | What it gives the Spry subgraph |
|---|---|
| `Initialize(id, currency0, currency1, fee, tickSpacing, hooks, sqrtPriceX96, tick)` (PoolManager) | Filter to Spry pools (see below); derive the **tier** from `tickSpacing`. |
| `Swap(id, sender, amount0, amount1, sqrtPriceX96, liquidity, tick, fee)` (PoolManager) | `fee` is the per-swap LP fee with `OVERRIDE_FEE_FLAG` stripped by V4 core; equals the `SpryFee.fee` of the paired hook emission. `sender` is the immediate caller (a router), not the EOA. |
| `ModifyLiquidity(id, sender, tickLower, tickUpper, liquidityDelta, salt)` (PoolManager) | LP add/remove. When the caller is the canonical V4 `PositionManager`, `salt == bytes32(tokenId)`, which links a position to its pool. |
| `Donate(id, sender, amount0, amount1)` (PoolManager) | Direct donations to a pool. |
| `Transfer`, `Subscription`, `Unsubscription`, `Approval`, `ApprovalForAll` (PositionManager) | LP-position ownership, exactly as in Uniswap's `v4-subgraph`. |

### Spry-pool filter

A pool is a Spry pool iff **all three** hold (a static-fee pool pointed at
the hook silently bypasses it, and a bad `tickSpacing` reverts on the first
swap):

```
hooks == SPRY_HOOK_ADDRESS
fee == 0x800000                       // LPFeeLibrary.DYNAMIC_FEE_FLAG
tickSpacing ∈ {1, 10, 60, 200, 1000}
```

`SPRY_HOOK_ADDRESS` on Unichain Sepolia (1301) is
`0x68ba5F1A761253c7c169F3Fde5b715c027814080` (SpryRouter:
`0xd887e2d555f98CB76AE3d0755Af7DdDC503EF017`). On Base Sepolia (84532) it is
`0x43C99D40E2E7FBa44435bFC6Da57a74d38fD0080` (SpryRouter:
`0xd4Af9FFDf2067d4CA422526D308E08CDBE690642`).

### Tier table (immutable, safe to hardcode)

`tickSpacing` selects the tier and its fee curve. The table is compile-time
constant in the hook (`tierParams(uint8)` is `pure`; no setter, owner, or
upgrade path), so it can be hardcoded without drift:

| tickSpacing | tier | base fee (safeFee) | cap fee (capFee) |
|---|---|---|---|
| 1 | STABLE | 100 (0.01%) | 5 000 (0.50%) |
| 10 | LIKE-ASSET | 500 (0.05%) | 10 000 (1.00%) |
| 60 | BLUE-CHIP | 3 000 (0.30%) | 55 000 (5.50%) |
| 200 | VOLATILE | 5 000 (0.50%) | 90 000 (9.00%) |
| 1000 | EXOTIC | 10 000 (1.00%) | 99 000 (9.90%) |

For the full zone bounds + curve coefficients, `eth_call`
`tierParams(uint8)` once per tier (it's `pure`).

### Confirmed invariants for indexers

Verified against the pinned V4 core (see Provenance):

- **No protocol fee** on Spry pools: the hook never sets one and V4
  defaults to 0, so `Swap.fee == lpFee == SpryFee.fee`. Only V4's
  `protocolFeeController` could change this; if it ever did, `SpryFee.fee`
  still carries the pure LP fee and the difference vs `Swap.fee` is the
  protocol cut.
- **No hook-collected value**: `beforeSwap` returns a zero delta,
  `afterSwap` returns 0, and the hook holds only `BEFORE_SWAP_FLAG` (no
  returns-delta permission), so `Swap.amount0/amount1` are the complete
  user-facing amounts.
- **Single, immutable, non-upgradeable hook** (no proxy): hardcode the
  address per chain; a future breaking change would be a new contract at a
  new address. `BLOCK_WINDOW` is a per-chain `immutable`.
- **Deployed on Unichain Sepolia (1301)**: `SPRY_HOOK_ADDRESS` =
  `0x68ba5F1A761253c7c169F3Fde5b715c027814080`, SpryRouter =
  `0xd887e2d555f98CB76AE3d0755Af7DdDC503EF017`, `BLOCK_WINDOW` = 60.
  Subgraph `startBlock`: `54497329` (the hook's deploy block).
- **Deployed on Base Sepolia (84532)**: `SPRY_HOOK_ADDRESS` =
  `0x43C99D40E2E7FBa44435bFC6Da57a74d38fD0080`, SpryRouter =
  `0xd4Af9FFDf2067d4CA422526D308E08CDBE690642`, `BLOCK_WINDOW` = 30.
  Subgraph `startBlock`: `42508548` (the hook's deploy block). No mainnet
  deployment yet.

For lookups, the hook also exposes `poolWindow(bytes32)` and
`tierParams(uint8)` as `view`/`pure`, usable from `eth_call` at
end-of-block (e.g. for a one-shot bootstrap of pool state).

## Provenance

- **solc:** `0.8.26+commit.8a97fa7a` (`evm_version = cancun`)
- **v4-core:** `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` (`v4.0.0-21-g46c68346`)
- **v4-periphery:** `9dafaaecc1e2e1e824eda9d941085f96517d827b`

## Regenerate

From the repo root, after `forge build`:

```bash
mkdir -p abis
jq '.abi' out/SpryHook.sol/SpryHook.json             > abis/SpryHook.json
jq '.abi' out/SpryRouter.sol/SpryRouter.json         > abis/SpryRouter.json
jq '.abi' out/PoolManager.sol/PoolManager.json       > abis/PoolManager.json
jq '.abi' out/PositionManager.sol/PositionManager.json > abis/PositionManager.json
```
