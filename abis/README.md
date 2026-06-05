# ABIs

Contract ABIs for off-chain consumers (subgraph, indexers, front-end,
scripts). Each file is a **bare ABI array** — the format `graph-cli`,
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

`SpryRouter` emits no events. `SpryHook` emits **one** event — the
canonical off-chain signal for Spry-specific analytics that V4's `Swap`
event cannot carry:

```solidity
event SpryFee(
    PoolId indexed id,
    int256 cumBefore,     // signed block-windowed cumulative, pre-swap
    int256 cumAfter,      // post-swap (== persisted signedCum)
    uint24 fee,           // resolved LP fee in pips, OVERRIDE flag stripped
    uint8  zone,          // 0 safe / 1 alert / 2 danger / 3 cap
    uint8  dispatchCase,  // 0 Growth / 1 Unwind / 2 Flip
    uint64 windowId       // active window's start block (windowStart)
);
```

`SpryFee` is emitted once per pool hop, immediately before V4's `Swap`
event for the same pool — so an indexer naturally pairs each `SpryFee`
with the next `Swap` on the same `id` in the same transaction.

The rest of the indexing model uses **canonical V4 events** from
`PoolManager` and `PositionManager`:

| Event (source) | What it gives the Spry subgraph |
|---|---|
| `Initialize(id, currency0, currency1, fee, tickSpacing, hooks, sqrtPriceX96, tick)` — PoolManager | Filter to Spry pools via `hooks == SpryHook`; derive the **tier** from `tickSpacing` (1/10/60/200/1000 → STABLE/LIKE-ASSET/BLUE-CHIP/VOLATILE/EXOTIC); `fee == 0x800000` (dynamic-fee sentinel). |
| `Swap(id, sender, amount0, amount1, sqrtPriceX96, liquidity, tick, fee)` — PoolManager | `fee` is the per-swap LP fee already with `OVERRIDE_FEE_FLAG` stripped (V4 core strips it). On Spry pools `swapFee == lpFee` because there's no protocol fee (none is set on Spry pools); equals the `SpryFee.fee` of the paired hook emission. |
| `ModifyLiquidity(id, sender, tickLower, tickUpper, liquidityDelta, salt)` — PoolManager | LP add/remove. When the caller is the canonical V4 `PositionManager`, `salt == bytes32(tokenId)`, which is how the subgraph links a position to the pool. |
| `Donate(id, sender, amount0, amount1)` — PoolManager | Direct donations to a pool. |
| `Transfer`, `Subscription`, `Unsubscription`, `Approval`, `ApprovalForAll` — PositionManager | LP-position ownership, exactly as in Uniswap's `v4-subgraph`. |

For lookups, the hook also exposes `poolWindow(bytes32)` and
`tierParams(uint8)` as `view` — usable from `eth_call` at end-of-block
(e.g. for a one-shot bootstrap of pool state).

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
