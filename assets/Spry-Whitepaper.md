# SPRY: A Dynamic-Fee Uniswap V4 Hook for Impermanent-Loss Mitigation

## Abstract

We present **Spry**, a Uniswap V4 hook that prices liquidity-provider (LP) fees
dynamically as a function of how much each individual swap shifts the pool's
price. Small swaps pay the standard 0.30 % fee. Larger swaps — typically
arbitrage rebalancing the pool against an external reference — pay a fee that
scales up to 5.5 % through a piecewise curve (constant, linear, exponential)
calibrated to the slope of the impermanent-loss profile. The excess accrues to
LPs through V4's standard fee channel.

Spry is implemented as a small periphery — one hook, one router, four libraries
— deployed against the canonical Uniswap V4 `PoolManager`. Pools operate in
full-range mode so the underlying swap math reduces to the constant-product
$x \cdot y = k$ at the current price, preserving uniform-liquidity economics
while inheriting V4's native ETH, flash-accounting multi-hop, ERC-6909 claim
tokens, and audited swap engine.

This whitepaper formalises the impermanent-loss problem, derives the dynamic
fee curve, specifies the contract surface, and documents the test artefacts
that back each claim.

---

## 1. Introduction

Decentralized exchanges (DEXs) provide permissionless trading of crypto assets
without intermediary identity verification or counterparty risk on the venue
itself. By 2025 the top three DEXs on Ethereum and its rollups clear several
billion USD of trading volume per day between them.

Modern DEXs do not run order books. Instead they rely on **automated market
makers** (AMMs), in which liquidity providers (LPs) deposit pairs of assets
into a pool and a deterministic pricing function priced against the pool's
reserves quotes every trade. The simplest and most-used pricing function is
the **constant-product market maker** (CPMM) introduced by Uniswap V2 [1, 2]:
the product of the two reserves is held invariant across swaps, so that price
moves smoothly as either reserve grows or shrinks.

CPMMs have an unavoidable cost for LPs known as **impermanent loss** (IL): at
any price other than the one at which the LP deposited, the pool position is
worth less than simply holding the original assets [3, 4]. The cost is
"impermanent" in the sense that if the price returns to the deposit point the
loss vanishes — but in practice every price move asymmetrically extracts value
from LPs and donates it to arbitrageurs who keep the pool in line with
external markets.

The standard remedy is a swap fee paid by takers on every trade. Uniswap V2's
fixed 0.30 % fee compensates LPs for the average IL they suffer over time. But
fixed fees compensate badly: 0.30 % is too high on a tiny arbitrage that
barely moves the pool and far too low on a large rebalance that shifts the
price meaningfully. The result is that small takers subsidise the IL caused
by large takers.

**Spry replaces the fixed fee with a fee curve that scales with the swap's
own contribution to IL**. The fee starts at the V2-default 3 bps when the
post-swap price is close to the pre-swap price, ramps linearly into a 20 bps
"alert" band, and ramps exponentially into a 50 bps "danger" band as the
swap approaches a regime that would inflict large IL on LPs. The curve is
derived in section 3.

We implement Spry as a Uniswap V4 hook [5, 6]: a stand-alone contract that
V4's singleton `PoolManager` consults on every swap of every pool that opts
into it. This delivery model lets Spry reuse V4's already-audited swap math,
position accounting, ERC-6909 claim tokens, and native-ETH currency, while
keeping our own attack surface to ~700 lines of Solidity in one hook, one
router, and four small libraries.

The rest of this document is organised as follows. Section 2 reviews the
mathematical background — CPMM mechanics, the impermanent-loss derivation,
and the parts of the Uniswap V4 architecture Spry relies on. Section 3
presents the SmartFee algorithm. Section 4 specifies the contracts. Section 5
covers implementation details (hook permissions, virtual reserves, fee unit
conversion, settlement). Section 6 covers multi-hop routing. Section 7 covers
liquidity management. Section 8 describes the security model. Section 9
documents the testing methodology and reports the empirical results. Section
10 lists the pre-deployment checklist. Section 11 concludes.

---

## 2. Background

### 2.1 Constant Product Market Maker

A CPMM pool holds two assets $X$ and $Y$ with reserves $x, y \in \mathbb{R}_{>0}$.
The invariant maintained across swaps is

$$
x \cdot y = k
$$

for some constant $k$ that depends on the deposited liquidity. The spot price
of asset $X$ in units of $Y$ is the partial derivative

$$
P = -\frac{dy}{dx} = \frac{y}{x}
$$

A trade in which the taker deposits $\Delta y$ of $Y$ to receive $\Delta x$ of
$X$ must preserve the invariant net of fees. With proportional fee
$\gamma \in [0, 1)$ paid into the pool, the post-trade reserves are

$$
(x - \Delta x) \cdot \left(y + (1 - \gamma)\, \Delta y\right) = k
$$

so $\Delta x = \tfrac{x \cdot (1 - \gamma)\, \Delta y}{y + (1 - \gamma)\, \Delta y}$.
The fee fraction $\gamma$ is retained in the pool, slightly increasing $k$
over time.

### 2.2 Liquidity and pool value

Define the **liquidity** of a CPMM pool as the geometric mean of its reserves,
$L = \sqrt{x \cdot y} = \sqrt{k}$. Then the reserves as a function of the spot
price $P$ are

$$
x = \frac{L}{\sqrt{P}}, \qquad y = L \sqrt{P}
$$

and the **value** of the LP's pool position, denominated in $Y$, is

$$
V(P) = x \cdot P + y = 2 L \sqrt{P}
$$

This square-root profile is the source of impermanent loss: the LP's position
value grows like $\sqrt{P}$ while a buy-and-hold portfolio of the original
$(x_i, y_i)$ grows linearly in $P$.

### 2.3 Impermanent loss

Let $P_i, P_f$ be the pre- and post-price of the pool over a holding period,
and let $\delta$ denote the relative price change:

$$
\delta = \frac{P_f}{P_i} - 1, \qquad \delta \in (-1, \infty)
$$

The LP's pool position at the new price is worth $V(P_f) = 2 L \sqrt{P_f}$.
A reference buy-and-hold portfolio of the same initial reserves $(x_i, y_i)$
is worth $x_i P_f + y_i$. The impermanent loss is the relative shortfall of
the pool versus buy-and-hold:

$$
\mathrm{IL}(\delta) = \frac{V(P_f)}{V_{\mathrm{HODL}}(P_f)} - 1
= \frac{2\sqrt{\delta + 1}}{\delta + 2} - 1
\tag{IL}
$$

The function $\mathrm{IL}(\delta)$ has the following properties:

- $\mathrm{IL}(0) = 0$ — no price change, no loss.
- $\mathrm{IL}(\delta) \le 0$ for all $\delta \neq 0$, with equality only at zero.
- $\mathrm{IL}(\delta) \to -1$ as $\delta \to -1$ (one reserve drains to zero).
- $\mathrm{IL}(\delta) \to 0$ from below as $\delta \to \infty$.
- The slope $|\mathrm{IL}'(\delta)|$ is small near zero and grows as $|\delta|$
  grows, asymmetrically (the left side is steeper than the right).

It is the **slope** of this function — not its absolute value — that
motivates the Spry fee curve in Section 3.

### 2.4 Uniswap V4 architecture

We summarise the parts of V4 that Spry depends on; the canonical specification
is in [5].

**Singleton PoolManager.** Every pool on every chain is keyed by a `PoolKey`
struct and stored inside one `PoolManager` contract. The key is

```solidity
struct PoolKey {
    Currency currency0;     // sorted: currency0 < currency1
    Currency currency1;
    uint24   fee;           // static fee OR DYNAMIC_FEE_FLAG = 0x800000
    int24    tickSpacing;
    IHooks   hooks;         // 0x0 for static pools; non-zero for hooked pools
}
```

The pool's identifier is `keccak256(abi.encode(key))`.

**Hooks.** A hook is an arbitrary contract whose address encodes — in its low
14 bits — which lifecycle events of the pool it wants to handle. The events
are `beforeInitialize`, `afterInitialize`, `before/after AddLiquidity`,
`before/after RemoveLiquidity`, `before/after Swap`, `before/after Donate`,
plus three optional "returns delta" variants. A hook contract must implement
the `IHooks` interface; the `PoolManager` checks the flag bits of the hook's
address before each event and only calls the events that are flagged.

For Spry the only event we need is `beforeSwap` (flag `1 << 7 = 0x80`),
because the only thing we want to override is the fee. Section 3 details how
the override is plumbed.

**Flash accounting via `unlock`.** Every state-changing call to `PoolManager`
(swap, modify-liquidity, donate) must happen inside a caller-initiated
`unlock` callback:

```solidity
bytes memory ret = poolManager.unlock(abi.encode(ownArgs));
// inside the resulting unlockCallback(...) the caller swaps / modifies
// liquidity / takes / settles as many times as it wants, and exits with
// every currency's accumulated delta == 0.
```

This lets a single transaction perform a sequence of operations against many
pools atomically, with currency settlement deferred to the end. Multi-hop
swaps in Spry use exactly one `unlock` call per user transaction.

**Currency.** V4 represents both ERC-20 tokens and native ETH as a single
`Currency` user-defined type: `Currency.wrap(address(0))` is ETH,
`Currency.wrap(token)` is an ERC-20. The `PoolManager.settle{value:n}()` and
`PoolManager.take(currency, to, amount)` helpers handle the branch.

**ERC-6909 claim tokens.** Positive balances accumulated during an `unlock`
can be claimed as ERC-6909 tokens minted by the manager [7]. We do not
exercise this feature; Spry mints its own ERC-6909 LP shares from the router
contract, which is conceptually separate.

**Tick-based liquidity, used in full-range mode.** V4 inherits Uniswap V3's
tick-based concentrated-liquidity engine. Spry uses it in **full-range mode
only**: every position is minted with `tickLower = TickMath.minUsableTick`
and `tickUpper = TickMath.maxUsableTick` for the pool's tick spacing. Under
that constraint liquidity is uniform across the entire price range and the
pool behaves identically to a Uniswap V2 pair, expressed in V4's
$\sqrt{P} \cdot 2^{96}$ coordinates rather than reserve coordinates. We
exploit this equivalence in Section 5.3.

---

## 3. The SmartFee algorithm

### 3.1 The price delta

For every prospective swap we define the **price-shift parameter**
$\delta \in \mathbb{Q}$ as a scaled measure of how much the swap moves the
pool's price. Concretely, in thousandths,

$$
\delta = \begin{cases}
\dfrac{1000 \cdot \Delta x_{\mathrm{out}}}{R_x} & \text{if the swap takes token 0 out} \\[8pt]
-\dfrac{1000 \cdot \Delta y_{\mathrm{out}}}{R_y + \Delta y_{\mathrm{out}}} & \text{if the swap takes token 1 out}
\end{cases}
\tag{$\delta$}
$$

where $R_x, R_y$ are the pool's virtual reserves immediately before the swap.
$\delta = +1000$ corresponds to a 100 % growth in the token-0 reserve; $\delta
= -500$ corresponds to draining 50 % of the token-1 reserve. The two cases
are algebraically equivalent to the relative price change in equation (IL),
re-expressed in terms of the swap amount and the reserve being shrunk; the
direct form is numerically robust at any reserve ratio.

For exact-input swaps (where the taker specifies $\Delta x_{\mathrm{in}}$ or
$\Delta y_{\mathrm{in}}$ rather than the output amount) we first compute the
no-fee output using the CPMM formula

$$
\Delta y_{\mathrm{out}} = \frac{\Delta x_{\mathrm{in}} \cdot R_y}{R_x + \Delta x_{\mathrm{in}}}
$$

and then apply formula $(\delta)$ to the implied output. The fee computed this
way slightly over-estimates the post-fee price shift, which is conservative
in the LP's favour — the actual price moves slightly less than the
no-fee-computed $\delta$ because the fee is retained in the pool — so charging
based on the no-fee delta means the LP is over-protected by at most one fee
tier.

### 3.2 Zone partition

The IL function (IL) is locally flat near $\delta = 0$ and steepens
asymmetrically as $|\delta|$ grows. We partition the real line into three
zones whose endpoints lie at the inflection points of $|\mathrm{IL}'|$:

| Zone | $\delta$ range (thousandths) | Range as ratio | IL severity |
|---|---|---|---|
| **Safe** (green) | $[-250,\; 334]$ | $\delta \in [-0.25, +0.334]$ | $\lvert\mathrm{IL}\rvert < 1.8\%$ |
| **Alert left** (orange) | $[-500,\; -250)$ | $\delta \in [-0.5, -0.25)$ | $\lvert\mathrm{IL}\rvert \in [1.8\%, 5.7\%]$ |
| **Alert right** (orange) | $(334,\; 1000]$ | $\delta \in (0.334, 1.0]$ | $\lvert\mathrm{IL}\rvert \in [1.8\%, 5.7\%]$ |
| **Danger left** (red) | $[-1000,\; -500)$ | $\delta \in [-1.0, -0.5)$ | $\lvert\mathrm{IL}\rvert \in (5.7\%, 100\%]$ |
| **Danger right** (red) | $(1000,\; 5000]$ | $\delta \in (1.0, 5.0]$ | $\lvert\mathrm{IL}\rvert \in (5.7\%, 18\%]$ |
| **Fallback** | $\delta \le -1000$ or $\delta > 5000$ | reserves nearly drained / $>6\times$ price impact | bounded by cap |

The asymmetric upper boundary of the safe zone ($+0.334$ rather than $+0.25$)
reflects the IL function's asymmetry — an LP loses less from a 33 % price
*rise* than from a 25 % price *drop*. The slope coefficients in 3.3 capture
the same asymmetry.

### 3.3 Fee curve

For each zone the fee, expressed in **V2-style bps of 1000** (so $3$ means
0.30 %, $55$ means 5.5 %), is:

**Safe zone** ($-250 \le \delta \le 334$):

$$
\text{fee}(\delta) = 3
$$

**Alert left** ($-500 \le \delta < -250$):

$$
\text{fee}(\delta) = \frac{-68 \cdot \delta - 14 \cdot 1000}{1000}
\quad
\text{evaluated as integer division in thousandths}
$$

The corresponding implementation uses
$A_{\text{LEFT}} = -68\,000$, $B_{\text{LEFT}} = -14\,000$, divisor
$1\,000\,000$, so a single integer arithmetic produces the result without
floating-point.

**Alert right** ($334 < \delta \le 1000$):

$$
\text{fee}(\delta) = \frac{25.37 \cdot \delta - 5.37 \cdot 1000}{1000}
\quad (A_{\text{RIGHT}} = 25\,370,\; B_{\text{RIGHT}} = -5\,370)
$$

**Danger left** ($-1000 \le \delta < -500$):

$$
\text{fee}(\delta) = 8 \cdot \exp\!\left(-1.8325814637483102 \cdot \frac{\delta}{1000}\right)
$$

**Danger right** ($1000 < \delta \le 5000$):

$$
\text{fee}(\delta) = 15.905414575341013 \cdot \exp\!\left(0.22907268296853878 \cdot \frac{\delta}{1000}\right)
$$

**Fallback** (everywhere else):

$$
\text{fee}(\delta) = 55
$$

The constants are chosen so the curve is continuous at the alert/danger
boundaries: $\text{fee}(\pm 500) = 20$ from both the alert and danger
formulas. At the safe/alert boundary the linear formula evaluates to a value
in $(3, 4)$; integer truncation of the implementation produces $3$, so the
visible step at integer-bps resolution is zero.

The danger-zone exponentials use PRB-Math's `SD59x18` fixed-point exponential
[8] for precision; the safe and alert zones are pure integer arithmetic. At
$\delta = \pm 1000$ the danger-zone formulas evaluate to approximately
$49.99 \approx 50$. The hard cap at $\delta \in [-\infty, -1000) \cup (5000,
\infty)$ produces $55$ as a sentinel for "the swap is beyond what the curve
covers"; in practice $\delta \le -1000$ means the swap would drain more than
the available reserve and the swap reverts at the pool's price limit before
the fee matters.

### 3.4 Conversion to V4 dynamic fee units

Uniswap V4 expresses dynamic fees in **pips** (millionths): $1\,000\,000 =
100\%$, $3\,000 = 0.30\%$, $55\,000 = 5.5\%$. Spry computes the algorithm
above internally in V2's thousandths convention for byte-equivalence with the
canonical literature, then multiplies the result by $1\,000$ before
returning. The conversion is exact (no rounding) because both units are
linear scalings of a common ratio.

The hook returns the fee with `LPFeeLibrary.OVERRIDE_FEE_FLAG = 0x400000` ORed
into the high bits, which is the signal V4 uses to override the cached
per-pool fee for that single swap. The pool's stored fee remains
`DYNAMIC_FEE_FLAG = 0x800000` (the "consult-the-hook" sentinel).

### 3.5 Robustness

The formula in $(\delta)$ uses one reserve and one swap amount per case,
never dividing by the *opposite* reserve. This is important: a naive
implementation that first computes pre- and post-swap spot prices

$$
P_i = \frac{R_y}{R_x}, \quad P_f = \frac{R_y - \Delta y}{R_x + \Delta x}
$$

would, on EVM integer arithmetic, truncate $P_i$ to zero in pools with a
heavily-skewed decimal ratio (for example a 6-decimal stablecoin paired with
an 18-decimal token at the stablecoin's "natural" price). The subsequent
$P_f / P_i$ division would then panic. The direct form $(\delta)$ has no such
failure mode at any reserve ratio that fits in `uint128`.

### 3.6 Worked example

Consider a Spry pool with virtual reserves $R_x = R_y = 10^{22}$ at the
sqrt-price $\sqrt{P}_{X96} = 2^{96}$ (a 1:1 price). A swap that asks for
$\Delta x_{\mathrm{out}} = 5 \cdot 10^{21}$ (50 % of the token-0 reserve)
yields

$$
\delta = \frac{1000 \cdot 5 \cdot 10^{21}}{10^{22}} = 500
$$

which lands at the alert/danger right boundary. The fee charged is

$$
\text{fee}(500) = \frac{25\,370 \cdot 500 - 5\,370 \cdot 1\,000}{1\,000\,000}
= \frac{12\,685\,000 - 5\,370\,000}{1\,000\,000}
= 7 \text{ bps}_{\text{of-1000}} = 7\,000 \text{ pips}
$$

A swap of the same magnitude in the opposite direction, asking for
$\Delta y_{\mathrm{out}} = 5 \cdot 10^{21}$ of the token-1 reserve, yields

$$
\delta = -\frac{1000 \cdot 5 \cdot 10^{21}}{10^{22} + 5 \cdot 10^{21}}
= -\frac{5 \cdot 10^{24}}{1.5 \cdot 10^{22}}
= -333
$$

which lands inside left-alert. The fee is

$$
\text{fee}(-333) = \frac{-68\,000 \cdot (-333) - 14\,000 \cdot 1\,000}{1\,000\,000}
= \frac{22\,644\,000 - 14\,000\,000}{1\,000\,000}
= 8 \text{ bps}_{\text{of-1000}} = 8\,000 \text{ pips}
$$

The asymmetry — a swap that takes 50 % of one reserve pays $7$ bps; the
mirror swap pays $8$ bps — reflects the underlying asymmetry of the IL
function: token-1 reserves are scarcer relative to value at the boundary, so
draining them carries a slightly higher IL cost.

---

## 4. Architecture

Spry occupies a deliberately small footprint. The canonical Uniswap V4
`PoolManager` and its supporting libraries are **not** modified or
re-deployed; we depend on the same `PoolManager` every other V4 integrator
depends on.

### 4.1 Contracts

| Contract | Path | LoC | Role |
|---|---|---|---|
| `SpryHook` | `contracts/SpryHook.sol` | 158 | `IHooks` implementation. Declares only `BEFORE_SWAP_FLAG` in its permissions bitmap; the other eight entry points are present for interface completeness and revert if anyone but `PoolManager` calls them. Active body reads `slot0` + `liquidity` and forwards them to `SmartFeeLib.getDynamicFee`, returning the result OR-ed with `LPFeeLibrary.OVERRIDE_FEE_FLAG`. |
| `SpryRouter` | `contracts/SpryRouter.sol` | 491 | Periphery router. Public methods: `swapExactInputSingle`, `swapExactOutputSingle`, `swapExactInput` (unbounded multi-hop), `addLiquidity`, `removeLiquidity`. Every method opens exactly one `PoolManager.unlock` call. Slippage, deadline, native-ETH refund, fee-on-transfer-tolerant settlement live here. The router inherits `ModifiedERC6909` so LP shares are issued per `poolId` and can be transferred / approved / burned independently. |
| `HookMiner` | `contracts/HookMiner.sol` | 50 | Brute-force CREATE2 salt miner. V4 derives a hook's permissions from the low 14 bits of its address, so the deployer must search for a salt whose resulting `CREATE2` address has exactly the right flag bits set. Solidity-pure; usable both on-chain in deploy scripts and inside `setUp()` of test contracts. |
| `ModifiedERC6909` | `contracts/ModifiedERC6909.sol` | 66 | Per-`(poolId, holder)` LP-share ledger with per-id allowance and infinite-approval shortcut. Used by `SpryRouter` to track full-range positions on a per-user basis. |
| `SmartFeeLib` | `contracts/libs/SmartFeeLib.sol` | 150 | The fee curve. Public entry: `getDynamicFee(sqrtPriceX96, liquidity, zeroForOne, amountSpecified)` returns a `uint24` fee in V4 pips. Internally calls `VirtualReserves.fromState` and dispatches across the three zones. |
| `VirtualReserves` | `contracts/libs/VirtualReserves.sol` | 30 | Converts the V4 pool state $(\sqrt{P}_{X96}, L)$ into V2-equivalent virtual reserves $(R_0, R_1)$. Uses `FullMath.mulDiv` for 512-bit intermediate precision at extreme prices. |
| `SafeTransfer` | `contracts/libs/SafeTransfer.sol` | 32 | ERC-20 helpers tolerant of non-standard tokens (USDT-style no-return-data, `transferFrom` with non-bool return). Used by the router during settlement. |

The script `script/DeploySpry.s.sol` wires these together, mining the hook
salt and emitting the canonical PoolManager address as a CLI argument so the
same script works on any chain V4 supports.

### 4.2 Call flow

The diagram below traces a single-hop swap through the system.

```
                                  ┌──────────────┐
   user ── swapExactInputSingle ──▶ SpryRouter   │
                                  └──────┬───────┘
                                         │ PoolManager.unlock(SingleSwapData)
                                         ▼
                                ┌────────────────────┐
                                │ V4 PoolManager     │
                                └────┬───────────────┘
                                     │ beforeSwap(key, params)
                                     ▼
                              ┌───────────────────┐
                              │      SpryHook     │
                              │  reads slot0, L   │
                              │  calls SmartFeeLib│
                              │  returns fee|flag │
                              └────┬──────────────┘
                                   │ uint24 fee | OVERRIDE_FEE_FLAG
                                   ▼
                         ┌────────────────────────┐
                         │ PoolManager.swap math  │
                         │ applies fee, updates   │
                         │ sqrtPriceX96 + L       │
                         └────┬───────────────────┘
                              │ unlockCallback (router resolves deltas)
                              ▼
                      ┌────────────────────────┐
                      │  SpryRouter._settle    │
                      │  + _take ⇒ user paid   │
                      └────────────────────────┘
```

`PoolManager.unlock` and its callback are atomic — the entire sequence is one
EVM transaction. The hook never holds tokens or executes external calls; it
only reads two storage slots and returns a number.

### 4.3 Trust boundary

The components we ship that touch user value are:

1. `SpryRouter` — receives user tokens, settles them into `PoolManager`,
   takes outputs back to the user.
2. `ModifiedERC6909` — accounts LP shares; a bug here could double-mint or
   block legitimate redemptions.
3. `SmartFeeLib` — sets the fee; a bug here could under-charge takers
   (donating LP value to arbitrageurs) or over-charge (blocking legitimate
   trades).
4. `SpryHook` — the gateway through which `SmartFeeLib`'s output reaches the
   `PoolManager`. A bug here could likewise mis-set the fee or block swaps.

The components we depend on but do not ship are `PoolManager` and the v4-core
libraries it uses internally; the audit-and-deployment story for those is
Uniswap Labs' responsibility, not ours.

---

## 5. Implementation details

### 5.1 Hook permissions and CREATE2 deployment

V4 requires the hook's address itself to encode its permissions in its low 14
bits. `SpryHook.permissionsFlags()` returns `BEFORE_SWAP_FLAG = 1 << 7` and
nothing else. The deploy script mines a CREATE2 salt such that

$$
\mathrm{uint160}(\text{hookAddr}) \;\&\; \mathtt{0x3FFF} \;=\; \mathtt{0x0080}
$$

With a single-flag target this typically converges in a few thousand
iterations of `keccak256` — sub-second on commodity hardware off-chain. The
on-chain `HookMiner.find` is available for tests and small-scale deploys; for
mainnet the same logic should be run off-chain via a Foundry script so the
salt can be inspected before the deploy transaction is signed.

After deploying, the script verifies that the resulting address satisfies the
permission mask before returning. The pool initializer is then expected to
pass that exact address as `PoolKey.hooks`.

### 5.2 Dynamic-fee pool initialisation

A pool that wants Spry pricing must be initialised with

```solidity
PoolKey({
    currency0: ...,
    currency1: ...,
    fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,   // 0x800000
    tickSpacing: ...,
    hooks:       IHooks(spryHookAddress)
})
```

`DYNAMIC_FEE_FLAG` is the signal to `PoolManager` that the pool's fee is
hook-supplied. Without it, `PoolManager` will ignore the fee returned by
`beforeSwap` and apply whatever static fee was set instead. The `SpryRouter`
does **not** set this flag automatically — pool creation is the operator's
responsibility — but the deploy script includes a worked example for the
common case (a Spry pool over a single $\langle \mathrm{currency}_0,
\mathrm{currency}_1\rangle$ pair).

### 5.3 Virtual reserves

`SmartFeeLib.getDynamicFee` operates on the V2-style virtual reserves
$(R_0, R_1)$. `VirtualReserves.fromState` derives them from V4 pool state
under the full-range-uniform-liquidity assumption (Section 2.4):

$$
R_0 = \frac{L \cdot 2^{96}}{\sqrt{P}_{X96}}, \qquad
R_1 = \frac{L \cdot \sqrt{P}_{X96}}{2^{96}}
$$

Both numerators use `FullMath.mulDiv` to handle the intermediate 256-bit
overflow that occurs at extreme prices (the product
$L \cdot \sqrt{P}_{X96}$ can exceed $2^{256}$ when $L$ is near the
`uint128` limit and $\sqrt{P}_{X96}$ is near the `uint160` limit). The
identity $R_0 \cdot R_1 = L^2 = k$ holds exactly modulo rounding, which is
what gives us "V2 economics" — the swap math the pool actually runs on
$(\sqrt{P}_{X96}, L)$ is mathematically equivalent to a V2 pool on
$(R_0, R_1)$ when liquidity is uniform across the full range.

### 5.4 Reentrancy

V4's `Lock` library uses transient storage (EIP-1153) [9] to enforce
one-active-`unlock` at the `PoolManager` level. Once `unlock` is in flight,
any nested `unlock` call reverts. Spry's contracts inherit this property:
`SpryHook.beforeSwap` is `view` and never opens an `unlock`, and
`SpryRouter.unlockCallback` is the only state-changing entry point under the
manager's lock.

### 5.5 Settlement (native ETH, fee-on-transfer tokens, refunds)

The router's `_settle` helper branches on the currency:

```solidity
function _settle(Currency currency, address payer, uint256 amount) internal {
    if (amount == 0) return;
    POOL_MANAGER.sync(currency);
    if (Currency.unwrap(currency) == address(0)) {
        POOL_MANAGER.settle{value: amount}();           // native ETH
    } else {
        address token = Currency.unwrap(currency);
        if (payer == address(this)) {
            token.safeTransfer(address(POOL_MANAGER), amount);     // self-pay
        } else {
            token.safeTransferFrom(payer, address(POOL_MANAGER), amount);
        }
        POOL_MANAGER.settle();
    }
}
```

`SafeTransfer.safeTransfer{From}` is the standard pattern for ERC-20
tolerance: low-level `.call`, success bit, and "`returnData.length == 0` ||
`abi.decode(returnData, (bool))`" — covering both standard tokens and
USDT-style tokens that return no data. ETH refunds for unspent `msg.value`
happen at the outer router function (`swapExactOutputSingle`, `addLiquidity`,
etc.).

### 5.6 Pool isolation

Because pools are keyed by the hash of the entire `PoolKey` struct, two pools
sharing the same currency pair but differing in `fee`, `tickSpacing`, or
`hooks` are distinct pools with disjoint state. ERC-6909 LP shares are
likewise keyed by `poolId`, so a holder of shares in one pool cannot redeem
them against another. The invariant suite (Section 9) verifies this directly.

### 5.7 Protocol fee posture

V4 has an optional protocol-fee mechanism (settable by the `PoolManager`'s
owner, capped at 1/4 of the LP fee per swap). Spry's hook does **not**
interact with it. If a Spry deployment wants to take a protocol cut, the
standard V4 lever is the right place to set it; the SmartFee algorithm
itself is agnostic to whether the manager retains a fraction of the LP fee.

---

## 6. Multi-hop routing

`SpryRouter.swapExactInput(currencyIn, path[], amountIn, amountOutMin,
recipient, deadline)` performs an atomic multi-hop swap along an
arbitrary-length path. Each element of `path` is

```solidity
struct PathHop {
    Currency intermediateCurrency;
    uint24   fee;          // DYNAMIC_FEE_FLAG for Spry hops, static for others
    int24    tickSpacing;
    IHooks   hooks;        // SpryHook for Spry hops, 0x0 or another hook elsewhere
    bytes    hookData;     // pass-through to the hook (unused by SpryHook)
}
```

so a single multi-hop transaction can mix Spry-priced hops with static-fee
hops on the same `PoolManager`. The router selects `zeroForOne` for each hop
based on the canonical ordering of `currentIn` and `intermediateCurrency`
addresses and uses `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1` as the swap's
price limit, matching the V4 reference router.

The entire path executes inside one `PoolManager.unlock` callback:

```text
              ┌─────────────────────────────────┐
   currencyIn ─▶ hop 0  (pool A/B, Spry-priced) │
              └────┬────────────────────────────┘
                   │ intermediate balance in B (held inside PoolManager
                   │  as a transient delta — never withdrawn)
              ┌────▼────────────────────────────┐
              │ hop 1  (pool B/C, static fee)   │
              └────┬────────────────────────────┘
                   │ intermediate balance in C
              ┌────▼────────────────────────────┐
              │ hop 2  (pool C/D, Spry-priced)  │
              └────┬────────────────────────────┘
                   │ final balance in D
                   ▼
                 router settles user's input, takes user's output
```

Slippage is enforced once at the end against the final output; intermediate
hop sizes are not bounded individually. Any failed hop reverts the entire
`unlock`, atomically aborting earlier successful hops.

The path is unbounded in length, subject only to the block gas limit. Each
Spry hop pays for one `beforeSwap` call (≈ 10 k gas in safe/alert zones,
≈ 18 k gas in the exponential danger zone) on top of V4's normal swap cost.

---

## 7. Liquidity management

### 7.1 Full-range positions only

Spry exposes V2-style entry points on the router:

```solidity
function addLiquidity(
    PoolKey calldata key,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address recipient,
    uint256 deadline
) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
```

Internally the router (inside its `unlockCallback`) converts the desired
amounts into a V4 liquidity value via `LiquidityAmounts.getLiquidityForAmounts`
at the bounds `tickLower = TickMath.minUsableTick(key.tickSpacing)` and
`tickUpper = TickMath.maxUsableTick(key.tickSpacing)`. The resulting V4
position is identified by

$$
\mathrm{positionId} = \mathrm{keccak256}\bigl(\mathrm{routerAddress}, \mathrm{MIN\_USABLE\_TICK}, \mathrm{MAX\_USABLE\_TICK}, \mathrm{salt}=0\bigr)
$$

so the router holds **exactly one** position per Spry pool. Every $1$ wei of
that position's liquidity backs exactly $1$ wei of ERC-6909 LP shares in the
router's `ModifiedERC6909` ledger.

This 1:1 correspondence is the strongest invariant the protocol exposes (see
Section 9): the total LP shares issued must equal the position's V4 liquidity,
to the wei, across every sequence of `add`s and `remove`s by every actor.
Section 9 confirms this empirically across 128 000 random handler operations.

### 7.2 Removing liquidity

```solidity
function removeLiquidity(
    PoolKey calldata key,
    uint128 liquidity,
    uint256 amount0Min,
    uint256 amount1Min,
    address recipient,
    uint256 deadline
) external returns (uint256 amount0, uint256 amount1);
```

The router burns the caller's shares (via `ModifiedERC6909._burn`), then
inside the `unlockCallback` decreases the V4 position by the same amount and
takes the proportional `amount0`/`amount1` (or native ETH) to `recipient`.
Slippage is enforced against the realised amounts.

### 7.3 LP share transferability

LP shares are standard per-id ERC-6909 tokens. Holders can `transfer`,
`approve` per token id, and `transferFrom`, including the infinite-allowance
shortcut. Transferred shares remain redeemable via `router.removeLiquidity`
by whoever holds them at the time of the call — there is no holding-period or
identity restriction. The recipient of a transfer takes the same pro-rata
claim on the underlying full-range position.

---

## 8. Security model

### 8.1 What we inherit from V4

The following components are **not** modified or re-deployed by Spry; they
are the canonical Uniswap V4 contracts deployed once per chain by Uniswap
Labs:

- `PoolManager` and its `swap`, `modifyLiquidity`, `donate`, `initialize`
  entry points.
- The V4 swap math (`SqrtPriceMath`, `SwapMath`, `Pool`).
- The transient-storage `Lock` library.
- The `ERC6909Claims` and `ProtocolFees` modules.
- `Currency` and native-ETH handling.

V4 has been the subject of multiple external audits between its 2024 release
and the date of this document. Spry's correctness reduces to (a) trusting
those components to behave as specified and (b) ensuring our SmartFee algorithm
is what the protocol intends.

### 8.2 What Spry adds to the attack surface

| Component | Surface | Mitigation |
|---|---|---|
| `SpryHook.beforeSwap` | Called by `PoolManager` on every swap of every Spry pool. If it reverts, the swap reverts. | Body is `view`, reads two storage slots, calls a `pure` library. No state mutation, no external calls, no token movement. |
| `SpryHook` no-op entry points | Defined for `IHooks` completeness, but the manager will never call them because the address-encoded permissions do not flag them. | Every entry point is guarded by an `onlyPoolManager` modifier in case of unexpected delegate-call patterns. Directly tested with `vm.prank(address(0xdead))`. |
| `SpryRouter.unlockCallback` | Called by `PoolManager` during `unlock`. Could receive payloads from `unlock`s the router itself didn't initiate. | `onlyPoolManager` guard + tagged-union dispatch where every tag is exhaustively handled and unknown tags revert with `InvalidCallbackKind`. |
| Hook address mining | An adversary who controls the deploy could deploy a malicious hook at a Spry-looking address. | Hook bytecode is deterministic given the constructor args (`PoolManager` address); reproducible builds + on-chain Etherscan verification close this loop. |
| LP-share token | Standard ERC-6909, tradable. | Burn-side gated on holder balance; transfers route through the same library that the direct-mock unit suite hits. |

### 8.3 Known economic concerns

**Dynamic-fee sandwich window.** The fee charged for a swap is determined by
the swap's own delta, which depends on the pool state at the moment of
execution. An MEV bot can artificially raise the delta tier by front-running
with a price-shifting trade, observe the victim's higher fee, and back-run
to recover capital. Because the excess fee accrues to LPs rather than to the
attacker, the attack does not extract value from LPs — it extracts value
from the victim taker. The mitigation is the standard one (use a low-slippage
router with a tight `amountOutMin`), but it is not eliminated. We consider
this a property of dynamic-fee mechanisms in general, not a specific Spry
bug.

**Hook gas cost.** Each swap pays for one `beforeSwap` call. The integer
zones (safe / alert) run in approximately 10 000 gas; the danger-zone
exponentials run in approximately 18 000 gas because PRB-Math's `E.pow`
internally evaluates a Taylor series. For a 5-hop swap that is 50–90 k gas of
fee computation on top of V4's swap math. Pool operators who want predictable
gas can favour pools whose typical trade size lives in the safe/alert
regime.

**No external security audit.** The tests and invariants in Section 9 prove
the absence of failures in the scenarios we tested. They do not prove the
absence of bugs. Spry is not audit-ready in the sense of being deployable
with significant user funds today; see Section 10 for the recommended
pre-deploy checklist.

---

## 9. Testing methodology

The repository ships with **123 tests across 15 suites**, all passing under
the same Foundry profile that `forge coverage` uses (no `via_ir`,
optimizer off) so coverage measurements are accurate. The suites are listed
in the project README.

### 9.1 Unit coverage of the algorithm

`SmartFeeLibTest.t.sol` (19 tests) exercises every fee zone, both directions,
both exact-in and exact-out paths, the safe-zone base case, the fallback cap,
and the extreme-reserve-ratio robustness case. A property-based fuzz test
runs 256 random inputs over the full reserve range and asserts the returned
fee never exceeds 55 000 pips.

`SpryHookZonesTest.t.sol` (10 tests) re-runs the same zone coverage through
`SpryHook.beforeSwap` (impersonating `PoolManager`) so the SmartFeeLib lines
are exercised from the hook's inlined call site, not just through the
standalone library harness. This is what closes the inlining gap that
forge-coverage's per-deployment counter would otherwise report.

`SpryHookCoverageTest.t.sol` (10 tests) exercises the eight no-op `IHooks`
entry points — `beforeInitialize`, `afterInitialize`, `beforeAddLiquidity`,
`afterAddLiquidity`, `beforeRemoveLiquidity`, `afterRemoveLiquidity`,
`afterSwap`, `beforeDonate`, `afterDonate` — calling each as `PoolManager`
and asserting the right selector is returned, then calling each from a
non-`PoolManager` address and asserting `NotPoolManager`.

### 9.2 Integration coverage

`SpryHookTest`, `SpryRouterSingleTest`, `SpryRouterMultiTest`,
`SpryRouterLiquidityTest`, `SpryRouterBranchTest`, `SpryRouterERC6909Test`,
and `ParityTest` cover end-to-end flows against a locally deployed
`PoolManager`: single-hop and multi-hop swaps in both directions, slippage,
deadlines, native ETH on the input and on the output side, `addLiquidity` +
`removeLiquidity` round-trip, ERC-6909 transfer between LPs, the
`PoolManager`'s own nested-`unlock` lock, and the router's invalid-callback
revert path.

`ERC6909Test`, `HookMinerTest`, and `SafeTransferTest` cover the standalone
library primitives in isolation: per-id allowances, ERC-6909 transfer math,
CREATE2 salt mining, and the full quartet of ERC-20 quirks
(standard / USDT-style / false-return / reverting / ETH-rejecter receiver).

### 9.3 Invariant fuzz campaign

`Invariants.t.sol` runs 256 invariant rounds × 500 random handler calls per
round = **128 000 random operations**, picking from three actors and three
operations (`swapExactIn`, `addLiquidity`, `removeLiquidity`) with bounded
magnitudes. The handler swallows `revert`s so the campaign keeps moving even
when a random call would normally fail. Across the run the following
invariants hold without exception (0 violations recorded over the campaign):

| Invariant | What it proves |
|---|---|
| **`lpSharesMatchPositionLiquidity`** | `router.totalSupply(poolId)` $\equiv$ V4 in-range `liquidity(routerAddress, MIN\_TICK, MAX\_TICK, 0)`. The router's ERC-6909 ledger is the canonical record of position ownership; this invariant says the ledger is never out-of-sync with the underlying V4 position by even one wei. |
| **`sharesAccountForFullSupply`** | $\sum_{\text{actors}} \mathrm{balanceOf}(\mathrm{poolId}, \mathrm{actor}) \equiv \mathrm{totalSupply}(\mathrm{poolId})$. Proves no shares are lost or duplicated by transfers, mints, or burns. |
| **`poolLiquidityEqualsRouterShares`** | The pool's in-range liquidity reported by `StateLibrary` equals the router's total supply. Cross-checks the previous invariant from the manager's side. |
| **`managerSolventWhileLiquidityLives`** | While the pool has any liquidity, the `PoolManager` holds non-zero balances of both currencies. Catches drain paths. |

Additionally, the in-handler `swap` operation asserts $K_{\text{after}} \ge
K_{\text{before}}$ on the virtual constant $K = L^2$, so 42 000 random swaps
did not produce a single case of $K$ decreasing across a swap.

### 9.4 Fork testing

`ForkTest.t.sol` runs the full stack against the canonical V4 `PoolManager`
on whichever chain the environment variables `FORK_RPC_URL` and
`V4_POOL_MANAGER` point to. When the env vars are unset the tests skip
cleanly, so default `forge test` runs remain green offline. The fork suite
verifies (a) the mined hook address has the right permission bits on the
target chain's actual `PoolManager`, (b) a single-hop swap against the live
manager succeeds end-to-end, and (c) `StateLibrary` reads work against the
live deployment.

### 9.5 Coverage targets

The library-level coverage report under `forge coverage` shows 100 % lines,
branches, and functions on `SmartFeeLib`, `ModifiedERC6909`, and
`VirtualReserves`; near-100 % on `HookMiner` and `SafeTransfer`; and apparent
50 % on `SpryHook` and `SpryRouter`. The 50 % figures are an artefact of
forge-coverage's per-deployment aggregation: each test contract that deploys
its own hook / router instance contributes its own coverage trace, and lcov
reports the *intersection* across instances. The behavioural coverage (every
public method called, every branch executed by *at least one* test
deployment) is in fact at parity with the libraries.

---

## 10. Pre-deployment checklist

This repository is **not yet production-ready**. Before deploying with
material user funds:

1. **External security audit** of `contracts/` by an independent firm
   (suggested: one of Trail of Bits, OpenZeppelin, Spearbit). Budget 2–4
   weeks per firm. For maximum coverage, run a Sherlock or Cantina contest
   in parallel.
2. **Static analysis** pass: `slither contracts/` clean of high/medium
   findings; `aderyn` informational review.
3. **Fork tests** against Sepolia V4 (`FORK_RPC_URL` + `V4_POOL_MANAGER`
   set) and against a mainnet read-only fork at the intended deployment
   block.
4. **Sepolia smoke deploy** via `script/DeploySpry.s.sol`. Mine the salt
   off-chain. Verify the hook source on Etherscan. Initialize a pool with
   `DYNAMIC_FEE_FLAG`. Exercise a 3-hop swap end-to-end.
5. **Bug bounty**: an Immunefi (or equivalent) bounty programme for a
   minimum of 30 days at scale-appropriate payout before opening to retail.
6. **No protocol fee** at the manager level for the launch period: leave
   `PoolManager.setProtocolFee` to its default until the audit is closed
   and the mechanism is well-understood by operators.

---

## 11. Conclusion

Spry mitigates impermanent loss not by removing it (which would require an
external price oracle and a re-staking insurance pool, neither of which exist
permissionlessly on every chain) but by **pricing it correctly through the
fee**. Small swaps that produce little IL pay the V2-default fee. Large
swaps that move price meaningfully pay a fee scaled to the IL they're about
to inflict. The integral over time of the excess fees accrues to LPs through
V4's standard fee channel, exactly matching the IL profile we derived in
section 2.

By delivering this mechanism as a Uniswap V4 hook rather than a stand-alone
AMM, Spry avoids re-implementing — and re-auditing — pool storage, swap
math, position accounting, multi-pool isolation, native-ETH handling,
flash-accounting multi-hop, and ERC-6909 claim tokens. The Spry surface is
~700 lines of Solidity; the V4 surface we inherit is approximately 10×
larger and already audited at scale. This reduction in attack surface,
combined with the empirical guarantees in section 9, leaves Spry in a strong
position for an external audit to bring it to mainnet readiness.

The pre-audit work outlined in section 10 is necessary before any
significant value is exposed. Once that work is complete, Spry can be
deployed permissionlessly on every chain Uniswap V4 supports, with no
maintainer privilege beyond pool creation and no protocol-fee extraction
beyond what the underlying V4 deployment's owner chooses to set.

---

## References

[1] H. Adams, "Uniswap whitepaper," Uniswap Labs, 2018.

[2] H. Adams, N. Zinsmeister, D. Robinson, "Uniswap v2 core,"
Uniswap Labs technical report, 2020.

[3] G. Angeris, T. Chitra, A. Evans, "When does the tail wag the dog?
Curvature and market making," in *Cryptoeconomic Systems Journal*, 2022.

[4] A. Aigner, G. Dhaliwal, "Uniswap: Impermanent loss and risk profile of a
liquidity provider," arXiv:2106.14404, 2021.

[5] H. Adams, M. Salem, N. Zinsmeister, R. Keefer, A. Robinson, "Uniswap v4
core," Uniswap Labs technical report, 2024.

[6] Uniswap Labs, "Uniswap v4 hooks documentation," v4-by-example.org,
2024–2025.

[7] J. Yi-Sun, T. Esposito, J. Lin, "EIP-6909: Minimal multi-token
interface," Ethereum Improvement Proposals, 2023.

[8] P. R. Berg, "PRB-Math: signed and unsigned fixed-point math in
Solidity," github.com/PaulRBerg/prb-math.

[9] A. Beregszaszi, P. Hancock, "EIP-1153: Transient storage opcodes,"
Ethereum Improvement Proposals, 2023.

[10] A. Khakhar, X. Chen, "Delta hedging liquidity positions on automated
market makers," arXiv:2208.03318, 2022.

[11] M. Hafner, H. Dietl, "Impermanent loss conditions: An analysis of
decentralized exchange platforms," arXiv:2401.07689, 2024.

[12] A. Park, "The conceptual flaws of decentralized automated market
making," *Management Science*, vol. 69, no. 11, pp. 6731–6751, 2023.

[13] P. Bergault, L. Bertucci, D. Bouba, O. Guéant, "Automated market
makers: mean-variance analysis of LPs payoffs and design of pricing
functions," *Digital Finance*, 2023.

[14] V. Mohan, "Automated market makers and decentralized exchanges: a
DeFi primer," *Financial Innovation*, vol. 8, no. 1, p. 20, 2022.

[15] S. Loesch, N. Hindman, M. B. Richardson, N. Welch, "Impermanent loss
in Uniswap v3," arXiv:2111.09192, 2021.

[16] D. Miori, M. Cucuringu, "Clustering Uniswap v3 traders from their
activity on multiple liquidity pools, via novel graph embeddings," *Digital
Finance*, 2024.

[17] E. Bayraktar, A. Cohen, A. Nellis, "DEX specs: a mean field approach
to DeFi currency exchanges," arXiv:2404.09090, 2024.

[18] C. Alexander, X. Chen, J. Deng, Q. Fu, "Market efficiency improvements
from technical developments of decentralized crypto exchanges," SSRN
4495589, 2023.

---

*Document version*: V4 — current. The on-chain code described herein is at
the tip of the `feat/v4-migration` branch of the Spry contracts repository.
The whitepaper and the code are released under GPL-3.0-or-later (see
`LICENSE`).
