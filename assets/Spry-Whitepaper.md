# SPRY: A Dynamic-Fee Uniswap V4 Hook for Impermanent-Loss Mitigation

## Abstract

We present **Spry**, a Uniswap V4 hook that prices liquidity-provider (LP) fees
dynamically as a function of both (a) the immediate price shift of each swap
and (b) the running net price shift inside the current block. Small swaps pay
the tier's base rate (1 – 100 bps); large arbitrage swaps pay a fee that ramps
through a four-zone piecewise curve up to 9.9 %. The excess accrues to LPs
through V4's standard fee channel.

Spry ships **five hardcoded fee curves**, dispatched by `PoolKey.tickSpacing`
to match the asset class of the pair: STABLE / LIKE-ASSET / BLUE-CHIP /
VOLATILE / EXOTIC. Each curve has its own boundary table (safe / alert /
danger / cap), tuned to the asymmetry of the underlying reserve-shift math.

A per-pool **signed cumulative tracker** records the running net price
shift inside each block window; each swap's fee is then computed against
that running cumulative, not against the swap in isolation. The rate
charged is the **integral-mode marginal fee** — the average of the
underlying curve over the cumulative interval the swap traverses. Because
the integral telescopes, splitting one big swap into N smaller pieces
within the same block pays at least as much total fee as the single
big swap: integral-mode is the protocol's path-independence theorem and
the formal defence against multicall- and Flashbots-bundle splitting.

Spry is implemented as a small periphery — one hook, one swap-only router,
three libraries — deployed against the canonical Uniswap V4 `PoolManager`.
Liquidity provision goes through Uniswap's canonical V4 `PositionManager`
(per-owner V4 position salts give correct pro-rata fee accounting without
Spry maintaining its own ledger). Pools operate in full-range mode so the
underlying swap math reduces to the constant-product $x \cdot y = k$ at the
current price, preserving uniform-liquidity economics while inheriting V4's
native ETH, flash-accounting multi-hop, and audited swap engine.

This whitepaper formalises the impermanent-loss problem, derives the dynamic
fee curve, specifies the tier registry and cumulative tracker, proves the
integral-mode path-independence property, walks the contract surface, and
documents the 224 forge tests that back each claim.

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

**Spry replaces the fixed fee with a tier-aware curve that scales with the
swap's own contribution to IL *and* with the running net IL the same block
has already inflicted.** Each tier (STABLE, LIKE-ASSET, BLUE-CHIP, VOLATILE,
EXOTIC — dispatched by `tickSpacing`) defines its own four-zone curve: a
flat **safe** band, a linear **alert** ramp, an exponential **danger**
ramp, and a flat **cap** beyond the danger boundary. A per-pool signed
cumulative tracker accumulates each block's net delta, and the fee is
charged as the *integral average* of the curve over that cumulative
interval — a path-independence property that closes the splitting-attack
loophole. Curves and integrals are derived in section 3.

We implement Spry as a Uniswap V4 hook [5, 6]: a stand-alone contract
that V4's singleton `PoolManager` consults on every swap of every pool
that opts into it. This delivery model lets Spry reuse V4's already-
audited swap math, position accounting (ERC-721 positions through the
canonical `PositionManager`), ERC-6909 claim-token primitives, and
native-ETH currency, while keeping our own attack surface to under 1 000
lines of Solidity across one hook, one swap-only router, and three small
libraries.

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
can be claimed as ERC-6909 tokens minted by the manager [7]. Spry does not
exercise this feature directly — its router fully settles every swap before
returning — and it does not mint any tokens of its own; LP positions are
ERC-721s minted by Uniswap's canonical V4 `PositionManager`.

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

The IL function is locally flat near $\delta = 0$ and steepens
asymmetrically as $|\delta|$ grows. Every tier's curve partitions the real
line into **four zones** whose endpoints lie at the inflection points of
$|\mathrm{IL}'|$ for that asset class. Using the BLUE-CHIP tier
(`tickSpacing = 60`) as the canonical example:

| Zone | BLUE-CHIP $\delta$ range (per-mille) | Shape | Fee at endpoints |
|---|---|---|---|
| **Safe** | $[-250,\; 334]$ | constant | $\text{fee} = 3\,000$ pips (0.30 %) |
| **Alert left** | $[-500,\; -250)$ | linear ramp | $3\,000 \to 20\,000$ pips |
| **Alert right** | $(334,\; 1000]$ | linear ramp | $3\,000 \to 20\,000$ pips |
| **Danger left** | $[-1000,\; -500)$ | SD59x18 exponential | $20\,000 \to 50\,000$ pips |
| **Danger right** | $(1000,\; 5000]$ | SD59x18 exponential | $20\,000 \to 50\,000$ pips |
| **Cap** | $\delta < -1000$ or $\delta > 5000$ | constant | $55\,000$ pips (5.5 %) |

The asymmetric upper boundary of the safe zone (`+334` rather than `+250`)
reflects the IL function's asymmetry — an LP loses less from a 33 % price
*rise* than from a 25 % price *drop* — and matches the asymmetric algebra
of $(\delta)$ itself. Each tier's coefficients are tuned to match its own
asymmetry; the structural shape (safe → alert → danger → cap, with linear
+ exponential ramps) is the same for all tiers.

### 3.3 Fee curve

Inside each zone the fee is expressed directly in **V4 pips**
($1\,000\,000 = 100\%$); no intermediate unit conversion is required.
Using the BLUE-CHIP coefficients hard-coded in `SpryHook._tierBlueChip()`:

**Safe zone** ($-250 \le \delta \le 334$):

$$
\text{fee}(\delta) = \text{safeFee} = 3\,000 \text{ pips}
$$

**Alert left** ($-500 \le \delta < -250$):

$$
\text{fee}(\delta) = \frac{a_L \cdot \delta + 1000 \cdot b_L}{10^{6}}
\qquad (a_L = -68\,000\,000,\; b_L = -14\,000\,000)
$$

**Alert right** ($334 < \delta \le 1000$):

$$
\text{fee}(\delta) = \frac{a_R \cdot \delta + 1000 \cdot b_R}{10^{6}}
\qquad (a_R = 25\,525\,525,\; b_R = -5\,525\,525)
$$

**Danger left** ($-1000 \le \delta < -500$):

$$
\text{fee}(\delta) = \frac{a_L^{\text{exp}} \cdot \exp\!\bigl(b_L^{\text{exp}} \cdot \delta / 1000\bigr)}{10^{36}}
$$

with $a_L^{\text{exp}} \approx 8 \cdot 10^{21}$ and $b_L^{\text{exp}} \approx
-1.83 \cdot 10^{18}$ (raw SD59x18).

**Danger right** ($1000 < \delta \le 5000$):

$$
\text{fee}(\delta) = \frac{a_R^{\text{exp}} \cdot \exp\!\bigl(b_R^{\text{exp}} \cdot \delta / 1000\bigr)}{10^{36}}
$$

with $a_R^{\text{exp}} \approx 1.59 \cdot 10^{22}$ and $b_R^{\text{exp}}
\approx 2.29 \cdot 10^{17}$.

**Cap** (everywhere else):

$$
\text{fee}(\delta) = \text{capFee} = 55\,000 \text{ pips}
$$

The coefficients are chosen so the curve is continuous at every
safe ↔ alert and alert ↔ danger boundary. At $\delta = \pm 500$ both the
alert linear formula and the danger exponential formula evaluate to
$20\,000$ pips; at $\delta = -250$ and $\delta = +334$ the alert formulas
evaluate to $3\,000$ pips matching the safe zone. The danger-zone
exponentials use PRB-Math's `SD59x18` fixed-point exponential [8] for
precision; the safe, alert, and cap zones are pure integer arithmetic.

The full coefficient set for all five tiers — STABLE, LIKE-ASSET,
BLUE-CHIP, VOLATILE, EXOTIC — is enumerated in §3.7 below.

### 3.4 V4 dynamic-fee return channel

Uniswap V4 expresses dynamic fees in **pips** (millionths): $1\,000\,000 =
100\%$, $3\,000 = 0.30\%$, $55\,000 = 5.5\%$. Spry computes everything
end-to-end in pips, so no scaling is needed before returning the value.

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

### 3.6 Worked example (single swap, BLUE-CHIP)

Consider a Spry pool with virtual reserves $R_x = R_y = 10^{22}$ at the
sqrt-price $\sqrt{P}_{X96} = 2^{96}$ (a 1:1 price). A swap that asks for
$\Delta x_{\mathrm{out}} = 5 \cdot 10^{21}$ (50 % of the token-0 reserve)
yields

$$
\delta = \frac{1000 \cdot 5 \cdot 10^{21}}{10^{22}} = +500
$$

In a fresh block (cumBefore $= 0$), `marginalFee(0, 500, p)` integrates
the BLUE-CHIP curve over $[0, 500]$: the safe zone contributes
$\text{safeFee} \cdot 334 = 1\,002\,000$ pips·delta, the alert ramp from
$334$ to $500$ contributes $\approx 849\,690$ pips·delta, so the marginal
average is roughly $1\,852\,000 / 500 \approx 3\,703$ pips — well below
the point-evaluated rate at $\delta = 500$ (which is $\approx 7\,237$
pips) because most of the path was still in the safe zone.

A swap of the same magnitude in the opposite direction, asking for
$\Delta y_{\mathrm{out}} = 5 \cdot 10^{21}$ of the token-1 reserve,
yields

$$
\delta = -\frac{1000 \cdot 5 \cdot 10^{21}}{10^{22} + 5 \cdot 10^{21}}
\approx -333
$$

which lands just inside left-alert; the integral-mode marginal is a
similar blend of safe + alert contributions.

### 3.7 Tier registry

Spry ships five hardcoded fee curves, dispatched by `PoolKey.tickSpacing`
to match the asset class of the pair:

| Tier | `tickSpacing` | Example pairs | safeFee | alertEdge | dangerEdge | capFee |
|---|---|---|---|---|---|---|
| **STABLE** | 1 | USDC/USDT, stETH/ETH | 100 (0.01 %) | 500 (0.05 %) | 2 500 (0.25 %) | 5 000 (0.50 %) |
| **LIKE-ASSET** | 10 | wstETH/ETH, USDC/USDC.e | 500 (0.05 %) | 2 000 (0.20 %) | 5 000 (0.50 %) | 10 000 (1.00 %) |
| **BLUE-CHIP** | 60 | ETH/USDC, WBTC/ETH | 3 000 (0.30 %) | 20 000 (2.00 %) | 50 000 (5.00 %) | 55 000 (5.50 %) |
| **VOLATILE** | 200 | ETH/SHIB, ETH/PEPE | 5 000 (0.50 %) | 30 000 (3.00 %) | 75 000 (7.50 %) | 90 000 (9.00 %) |
| **EXOTIC** | 1000 | low-cap / low-cap | 10 000 (1.00 %) | 50 000 (5.00 %) | 95 000 (9.50 %) | 99 000 (9.90 %) |

Each tier additionally pins its own per-side zone bounds (`safeLow`,
`safeHigh`, `alertLow`, `alertHigh`, `dangerLow`, `dangerHigh`), tuned to
the volatility expected of that asset class. The linear coefficients
$(a_L, b_L, a_R, b_R)$ and exponential coefficients
$(a_L^{\text{exp}}, b_L^{\text{exp}}, a_R^{\text{exp}}, b_R^{\text{exp}})$
are derived by solving the boundary-continuity equations — two-equation,
two-unknown for the alert (linear) zone; log + exponential isolation for
the danger (PRB-Math SD59x18 exponential) zone — and are baked into the
hook's bytecode as `pure` immutables (no SLOAD at runtime). See
`SpryHook._tierStable()`, `_tierLikeAsset()`, `_tierBlueChip()`,
`_tierVolatile()`, `_tierExotic()` for the exact constants.

Why `tickSpacing` and not `key.fee`: V4's `LPFeeLibrary.isDynamicFee` uses
EXACT equality on the `DYNAMIC_FEE_FLAG`, so the lower bits of `key.fee`
cannot be repurposed for a tier index without losing the dynamic-fee
dispatch. `tickSpacing` is the natural alternative because (a) it is
already part of the `PoolKey` identity, (b) it conventionally encodes
fee tier in V3, and (c) different pools with the same tokens and hook
but different tickSpacings are distinct V4 pools — so a pair can
genuinely co-exist at multiple tiers if the market wants it to.

### 3.8 Per-pool cumulative tracker

Per-swap dispatch (evaluating the curve at the swap's own $\delta$) is
robust to one big trade but vulnerable to **splitting**: an attacker
who breaks one large $\delta$ into $N$ smaller swaps within the same
block pays $N$ small-swap fees, each evaluated near $\delta = 0$. To
close that loophole, every Spry pool maintains a one-storage-slot
cumulative window:

```solidity
struct PoolWindow {
    uint64  windowStart;   // block.number of the active window
    int128  signedCum;     // running sum of signed deltas within it
}
mapping(PoolId => PoolWindow) internal _poolWindow;
```

At each `beforeSwap` the hook lazily resets the window on a new block
(`block.number >= windowStart + BLOCK_WINDOW`), reads the current
`signedCum`, computes the swap's contribution `Δ`, and computes
$\text{cumBefore}, \text{cumAfter} = \text{cumBefore} + \Delta$. The fee
is then evaluated against the (cumBefore, cumAfter) pair, not the
isolated $\Delta$. After the fee is returned, `signedCum` is saturated
to `int128` bounds and persisted.

`BLOCK_WINDOW` is an `immutable` set at deployment time, not a baked-in
constant. The same wall-clock attack horizon (one multicall, one
Flashbots-style bundle) spans a different number of blocks on different
chains because block-times differ by more than an order of magnitude;
the deployer picks a per-chain value that covers that horizon:

| Chain | Block time | Recommended `BLOCK_WINDOW` |
|---|---|---|
| Ethereum mainnet | ~12 s | 1 |
| Base | ~2 s | 6 |
| Arbitrum One | ~250 ms | 48 |
| Optimism | ~2 s | 6 |
| Polygon PoS | ~2 s | 6 |

The constructor rejects `_blockWindow == 0` with `ZeroBlockWindow` —
a zero window would degenerate the cumulative tracker into a no-op
(every swap would observe a fresh window).

### 3.9 Integral-mode marginal fee

Given (cumBefore, cumAfter) the hook dispatches to
`SmartFeeLib.marginalFee(cumBefore, cumAfter, p)`. The case analysis is:

- **GROWTH** — same sign and $|\text{after}| > |\text{before}|$. The
  swap pushes the pool further from neutral; the fee is the
  *integral average* of the curve over the cumulative interval:

  $$
  \text{marginal} = \frac{1}{|\text{after}| - |\text{before}|}
  \int_{|\text{before}|}^{|\text{after}|}\!\text{fee}(x)\,dx
  $$

- **UNWIND** — same sign and $|\text{after}| \le |\text{before}|$. The
  swap brings the pool toward neutral; the fee is the tier's
  `safeFee`. LP still gets paid; the unwinder is not penalised for
  fixing the pool.

- **FLIP** — opposite strict signs. The swap crosses zero; the fee
  is the weighted average over the unwind half (charged at
  `safeFee`) and the growth half (charged at the integral over
  $[0, |\text{after}|]$):

  $$
  \text{marginal}
  = \frac{\text{safeFee}\cdot|\text{before}| + \int_0^{|\text{after}|}\!\text{fee}(x)\,dx}{|\text{before}|+|\text{after}|}
  $$

The integral is evaluated piecewise across the four zones using the
antiderivatives:

$$
F_{\text{safe}}(\delta) = \text{safeFee}\cdot\delta
$$

$$
F_{\text{alert}}(\delta) = \frac{a\cdot\delta^2/2 + 1000\cdot b\cdot\delta}{10^{6}}
$$

$$
F_{\text{danger}}(\delta) = \frac{a^{\text{exp}}\cdot 10^{3}}{b^{\text{exp}}}\cdot \exp\!\bigl(b^{\text{exp}}\cdot\delta / 1000\bigr)
$$

$$
F_{\text{cap}}(\delta) = \text{capFee}\cdot\delta
$$

with the obvious side-substitutions ($a := a_R$ or $-a_L$;
$b := b_R$ or $b_L$) for the right vs left half of the curve.

**Path-independence (statement).** Let $c_0 = c^{(0)} < c^{(1)} <
\dots < c^{(N)} = c_n$ be any monotone partition of a trajectory inside
one side. Then in real arithmetic

$$
\sum_{i=1}^{N} \text{marginal}_i \cdot \bigl(c^{(i)} - c^{(i-1)}\bigr)
\;=\;
\text{marginal}_{\text{full}} \cdot (c_n - c_0)
$$

because the integral telescopes ($F(c_n) - F(c_0)$ regardless of any
intermediate splits). In integer arithmetic the equality holds within
$|whole - \Sigma split| \le 2 \cdot |I| + 3 \cdot N$ (one ulp per
zone-crossing inside `_integral` plus up to $(I - 1)$ per
`area / interval` truncation per piece). The bound is asserted by
`testFuzzPathIndependenceMonotone` over 256 random
$(c_0, c_n, N)$ triples.

**Splitting-attack consequence.** Two swaps of the same total token
amount, one taken whole and the other split into $N$ pieces inside the
same block, produce DIFFERENT cumulative trajectories: each smaller
piece's $\delta$ is computed against post-previous-swap reserves which
are more imbalanced, so the cumulative travels DEEPER per unit of
token. Combined with path-independence over a fixed trajectory, this
means the splitter's total fee is **at least as high** as the big-swap
fee — and strictly higher once any piece's trajectory crosses
`safeHigh`. The property is asserted end-to-end by
`testAlertCrossingSplitterPaysStrictlyMore` and
`testFinerSplitPaysMoreThanCoarserSplit` in
`test/scenarios/IntegralPathIndependence.t.sol`.

---

## 4. Architecture

Spry occupies a deliberately small footprint. The canonical Uniswap V4
`PoolManager` and its supporting libraries are **not** modified or
re-deployed; we depend on the same `PoolManager` every other V4 integrator
depends on.

### 4.1 Contracts

| Contract | Path | SLOC | Role |
|---|---|---|---|
| `SpryHook` | `contracts/SpryHook.sol` | 241 | `IHooks` implementation. Declares only `BEFORE_SWAP_FLAG` in its permissions bitmap; the other entry points are present for interface completeness and revert if anyone but `PoolManager` calls them. The active body reads `slot0` + `liquidity`, computes the swap's signed delta via `SmartFeeLib.computeSignedDelta`, lazily resets the per-pool cumulative window on a new block, accumulates the delta into `signedCum`, dispatches to `SmartFeeLib.marginalFee` for the integral-mode fee, and returns the result OR-ed with `LPFeeLibrary.OVERRIDE_FEE_FLAG`. The contract also holds the 5-tier parameter registry returned by `_tierParams(uint8)` and dispatched from `PoolKey.tickSpacing`. |
| `SpryRouter` | `contracts/SpryRouter.sol` | 509 | Swap-only periphery router. Public methods: `swapExactInputSingle`, `swapExactOutputSingle`, `swapExactInput` (unbounded multi-hop), `swapExactOutput`, and their Permit / Permit2 / multicall variants. Every method opens exactly one `PoolManager.unlock` call. Slippage, deadline, native-ETH refund, and fee-on-transfer-tolerant settlement live here. The router holds no funds at rest and never mints LP shares — liquidity provision goes through Uniswap's canonical V4 `PositionManager`. |
| `SmartFeeLib` | `contracts/libs/SmartFeeLib.sol` | 203 | Fee math. Public entries: `getDynamicFee` (curve evaluated at this swap's delta), `feeForDelta` (curve at an arbitrary cum point), `computeSignedDelta` (the signed per-mille reserve-shift indicator), and `marginalFee(cumBefore, cumAfter, p)` (the integral-mode dispatch used by SpryHook). Internally dispatches across the four zones — safe (constant), alert (linear), danger (PRB-Math SD59x18 exponential), cap (constant) — with per-zone antiderivative helpers (`_alertArea`, `_dangerArea`) that stitch a piecewise integral across zone boundaries. |
| `SpryFeeTypes` | `contracts/libs/SpryFeeTypes.sol` | 19 | The `SpryFeeParams` struct: six `int32` zone bounds, four `int64` linear coefficients, four `int128` SD59x18 exponential coefficients, plus `uint32 safeFee` and `uint32 capFee`. One struct per tier, returned by `SpryHook._tierParams` as a bytecode immutable. |
| `VirtualReserves` | `contracts/libs/VirtualReserves.sol` | 16 | Converts the V4 pool state $(\sqrt{P}_{X96}, L)$ into V2-equivalent virtual reserves $(R_0, R_1)$. Uses `FullMath.mulDiv` for 512-bit intermediate precision at extreme prices. |
| `HookMiner` | `script/HookMiner.sol` | — | Brute-force CREATE2 salt miner. V4 derives a hook's permissions from the low 14 bits of its address, so the deployer must search for a salt whose resulting `CREATE2` address has exactly the right flag bits set. Solidity-pure; usable both on-chain in deploy scripts and inside `setUp()` of test contracts. |

The script `script/DeploySpry.s.sol` wires these together, mining the hook
salt and reading the canonical PoolManager address from the environment so
the same script works on any chain V4 supports.

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
   takes outputs back to the user. The router holds no funds at rest, has
   no admin / sweep / rescue function, and never mints any tokens.
2. `SmartFeeLib` — sets the fee; a bug here could under-charge takers
   (donating LP value to arbitrageurs) or over-charge (blocking legitimate
   trades).
3. `SpryHook` — the gateway through which `SmartFeeLib`'s output reaches
   the `PoolManager`. It also owns the per-pool cumulative-window state
   and the 5-tier parameter registry. A bug here could mis-set the fee,
   corrupt the cumulative, or block swaps.

The components we depend on but do not ship are `PoolManager`, the
v4-core libraries, and `PositionManager` from `v4-periphery`; the
audit-and-deployment story for those is Uniswap Labs' responsibility,
not ours.

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
    fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,   // 0x800000 (sentinel, NOT used for tier)
    tickSpacing: <one of 1 / 10 / 60 / 200 / 1000>,
    hooks:       IHooks(spryHookAddress)
})
```

`DYNAMIC_FEE_FLAG` is the signal to `PoolManager` that the pool's fee is
hook-supplied; V4's `LPFeeLibrary.isDynamicFee` uses *exact* equality on
the flag, so the lower bits of `key.fee` cannot also be repurposed to
encode the tier index. Instead the tier is encoded in `tickSpacing`: the
first call to `beforeSwap` reads `key.tickSpacing` and looks it up in
`_tierFromTickSpacing`, reverting with `InvalidTier` if it is not one of
the five sanctioned values $\{1, 10, 60, 200, 1000\}$. Pool creation is
the operator's responsibility — `SpryRouter` does not initialise pools
— but the deploy script includes a worked example for each tier.

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
`SpryHook.beforeSwap` writes only the per-pool cumulative window and never
opens an `unlock`, and `SpryRouter.unlockCallback` is the only state-
changing entry point under the manager's lock.

### 5.5 Settlement (native ETH, fee-on-transfer tokens, refunds, Permit2)

The router's `_settle` helper branches on the currency and on the optional
Permit2 transfer mode:

```solidity
function _settle(
    Currency currency,
    address payer,
    uint256 amount,
    bool usePermit2
) internal {
    if (amount == 0) return;
    POOL_MANAGER.sync(currency);
    if (Currency.unwrap(currency) == address(0)) {
        if (usePermit2) revert Permit2NativeUnsupported();
        POOL_MANAGER.settle{value: amount}();           // native ETH
    } else {
        address token = Currency.unwrap(currency);
        if (usePermit2) {
            PERMIT2.transferFrom(payer, address(POOL_MANAGER), uint160(amount), token);
        } else {
            ERC20(token).safeTransferFrom(payer, address(POOL_MANAGER), amount);
        }
        POOL_MANAGER.settle();
    }
}
```

The router uses solmate's `SafeTransferLib` for ERC-20 tolerance: low-level
`.call`, success bit, and a `returnData.length == 0` || `abi.decode(...,
(bool))` fallback that covers both standard tokens and USDT-style tokens
that return no data. ETH refunds for unspent `msg.value` happen at the
outer router entry point (`swapExactInputSingle`, `swapExactOutputSingle`,
etc.) against a balance snapshot taken on entry; the multicall caveat in
`SpryRouter`'s NatSpec applies: a multicall whose inner calls do not
themselves consume ETH must not be passed `msg.value`.

### 5.6 Pool isolation

Because pools are keyed by the hash of the entire `PoolKey` struct, two
pools sharing the same currency pair but differing in `fee`, `tickSpacing`,
or `hooks` are distinct pools with disjoint state. The hook's per-pool
cumulative window state is keyed by `PoolId`, so swaps on one pool cannot
shift the cumulative on another (verified end-to-end by
`testCumulativeIsPerPool` and the `CrossPoolIsolation` scenarios). The
invariant suite (Section 9) cross-checks the V4-level state.

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

### 7.1 Liquidity provision via the canonical PositionManager

Spry's router is **swap-only**: it does not mint, burn, or transfer LP
positions, and it holds no LP shares at rest. Liquidity provision goes
entirely through Uniswap's canonical V4 `PositionManager`
(`v4-periphery`), against the same `PoolManager` Spry's hook is wired to.

Each LP is identified by an **ERC-721 token id**, minted by the
PositionManager when the position opens. V4 keys per-position fee
accounting by

$$
\mathrm{positionKey} = \mathrm{keccak256}\bigl(\mathrm{positionManagerAddress},\, \mathrm{tickLower},\, \mathrm{tickUpper},\, \mathrm{salt}\bigr)
$$

with `salt = bytes32(tokenId)` set by PositionManager. The result: every
LP has a strictly separate fee accumulator, so a drive-by `add → remove`
attacker cannot drain the fees that accrued on someone else's position.

The interop is tested end-to-end by
`test/integration/PositionManagerInteropTest.t.sol`: Alice mints a
position through `PositionManager`, Carol swaps through `SpryRouter`
(accruing fees against Alice's position via V4's per-`positionKey`
`feeGrowthInside`), and Alice's subsequent `DECREASE_LIQUIDITY` returns
strictly more than she put in.

### 7.2 Full-range positions

Spry's economic model assumes uniform liquidity across the entire price
range — the constant-product reduction the SmartFee derivation operates
on. The recommended position bounds are therefore
`tickLower = TickMath.minUsableTick(tickSpacing)` and
`tickUpper = TickMath.maxUsableTick(tickSpacing)`. PositionManager will
mint concentrated positions too, but the dynamic-fee curve makes no
guarantees about IL compensation for concentrated ranges.

### 7.3 LP share transferability

Because the LP token is a standard ERC-721 minted by PositionManager,
LP positions transfer the same way every other Uniswap V4 position
transfers — `safeTransferFrom`, `approve`, set-approval-for-all,
on-chain marketplaces, etc. No Spry-specific token contract is involved.

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
| `SpryHook.beforeSwap` | Called by `PoolManager` on every swap of every Spry pool. If it reverts, the swap reverts. | Body reads two storage slots, writes one (the per-pool cumulative window), calls library `pure` functions. No external calls, no token movement. |
| Per-pool cumulative state | One storage slot per Spry pool (`PoolWindow { uint64 windowStart; int128 signedCum; }`), written on every swap. | `signedCum` is saturated to `int128` bounds defensively; realistic in-window magnitudes are ≤ ~50 000 (six orders of magnitude below the saturation threshold). Window resets lazily on the first swap of a new block. |
| `SpryHook` no-op entry points | Defined for `IHooks` completeness, but the manager will never call them because the address-encoded permissions do not flag them. | Every entry point is guarded by an `onlyPoolManager` modifier in case of unexpected delegate-call patterns. Directly tested with `vm.prank(address(0xdead))`. |
| `SpryRouter.unlockCallback` | Called by `PoolManager` during `unlock`. Could receive payloads from `unlock`s the router itself didn't initiate. | `onlyPoolManager` guard + tagged-union dispatch where every tag is exhaustively handled and unknown tags revert with `InvalidCallbackKind`. |
| Hook address mining | An adversary who controls the deploy could deploy a malicious hook at a Spry-looking address. | Hook bytecode is deterministic given the constructor args (`PoolManager` address); reproducible builds + on-chain Etherscan verification close this loop. |

### 8.3 Known economic concerns

**Dynamic-fee front-running window.** The fee charged for a swap is
determined by the running cumulative *and* the swap's own delta — both of
which depend on the pool state at the moment of execution. An MEV bot can
front-run the victim with a price-shifting trade to push the cumulative
deeper, observe the victim's higher fee, and back-run to recover capital.
Because the excess fee accrues to LPs rather than to the attacker, the
attack does not extract value from LPs — it extracts value from the
victim taker. Integral mode makes the attack *self-costly* for the
attacker: the front-run + back-run pair must itself pay the integral
over its own cumulative trajectory, so the attacker pockets less than
the difference between the victim's two fee rates. The attack is not
eliminated; the mitigation is the standard one (use a low-slippage
router with a tight `amountOutMin`).

**Patient MEV beyond the window.** The cumulative resets after
`BLOCK_WINDOW` blocks (a chain-specific immutable — see §3.8); an
attacker who can afford to wait that many blocks between legs pays
normal fees. The protection scope is deliberately limited to the
atomic-within-window attack surface (multicall, Flashbots bundle, and
on faster chains a few consecutive blocks). Longer-horizon strategies
fall outside what dynamic-fee-via-cumulative can address without
external price feeds.

**Hook gas cost.** Each swap pays for one `beforeSwap` call. The integer
zones (safe / alert) run in approximately 10 000 gas; the danger-zone
exponentials run in approximately 18 000 gas because PRB-Math's `E.pow`
internally evaluates a Taylor series. For a 5-hop swap that is 50–90 k gas of
fee computation on top of V4's swap math. Pool operators who want predictable
gas can favour pools whose typical trade size lives in the safe/alert
regime.

**No external security audit.** The tests and invariants in Section 9 prove
the absence of failures in the scenarios we tested. They do not prove the
absence of bugs. The codebase is not audit-ready in the sense of being
deployable with significant user funds; see Section 10 for the recommended
pre-deploy checklist.

---

## 9. Testing methodology

The repository ships with **224 tests across 38 suites**, all passing
under the same Foundry profile that `forge coverage` uses (no `via_ir`,
optimizer off) so coverage measurements are accurate. The suites are
grouped under `test/unit/`, `test/integration/`, `test/scenarios/`,
`test/fuzz/`, and `test/fork/`.

### 9.1 Unit coverage of the algorithm

`SmartFeeLibTest.t.sol` (25 tests) exercises every fee zone, both
directions, both exact-in and exact-out paths, the safe-zone base case,
the fallback cap, the extreme-reserve-ratio robustness case, and
boundary continuity at every safe ↔ alert ↔ danger seam. A property-
based fuzz test runs 256 random inputs over the full reserve range and
asserts the returned fee never exceeds 55 000 pips.

`MarginalFeeTest.t.sol` (28 tests) pins the integral-mode math: each
behavioral case (Growth / Unwind / Flip), each per-zone integral
(safe / alert / danger / cap), boundary stitching across zones, and
three property-based fuzz tests covering path-independence within the
theoretical $2 \cdot |I| + 3 \cdot N$ truncation bound.

`AllTiersMarginalFeeTest.t.sol` (6 tests) re-runs the integral-mode
sanity checks against the OTHER four tier parameter sets, so any drift
between the hook's tier registry and what SmartFeeLib consumes surfaces
immediately.

`SpryHookZonesTest.t.sol` (10 tests) re-runs the zone coverage through
`SpryHook.beforeSwap` (impersonating `PoolManager`) so the SmartFeeLib
lines are exercised from the hook's inlined call site, not just through
the standalone library harness. `SpryHookCoverageTest.t.sol` (11 tests)
covers the no-op `IHooks` entry points: each is called once as
`PoolManager` (right selector returned) and once from a non-`PoolManager`
address (`NotPoolManager` revert).

`HookMinerTest.t.sol` (5 tests) covers CREATE2 salt mining and the bit-
flag verification used by every test's `setUp`.

### 9.2 Integration coverage

Twelve suites cover end-to-end flows against a locally deployed
`PoolManager`: single-hop and multi-hop swap shapes
(`SpryRouterSingleTest`, `SpryRouterMultiTest`, `SpryRouterBranchTest`,
`SwapShapeMatrixTest`), V4 hook surface (`SpryHookTest`,
`HookDataForwardingTest`), Permit / Permit2 / multicall (`PermitSupportTest`,
`Permit2SupportTest`), Quoter integration (`QuoterTest`), tier-from-
tickSpacing dispatch (`TierDispatchTest`), native ETH + multi-pool
isolation (`ParityTest`), and the PositionManager interop smoke test
(`PositionManagerInteropTest`).

### 9.3 Scenario coverage

Seventeen scenario suites simulate adversarial flows or asset shapes
the hook is supposed to neutralise. The most load-bearing ones:

| Suite | What it pins |
|---|---|
| `IntegralPathIndependence.t.sol` | Same-block splitter receives strictly less output (paid more fee) than one big swap of the same total amount, once the trajectory crosses safeHigh. Finer splits cost more than coarser splits. Multi-block splits incur no penalty (the window reset works). |
| `CumulativeFeeBehavior.t.sol` | Each of the three dispatch cases — Growth / Unwind / Flip — observed end-to-end through V4 swaps. Window reset + multi-pool isolation. |
| `SandwichAttack.t.sol` | Sandwich attacker's second leg pays a higher fee because the first leg already pushed the pool's cumulative. |
| `FeeAccrualBenefit.t.sol` | An honest LP earns fees on their own position. A drive-by `add → remove` attacker cannot drain fees that accrued on someone else's position (per-owner V4 position salt). |
| `JITLiquidity.t.sol` | A just-in-time LP cannot harvest fees that accrued before they joined. |
| `AsymmetricDecimals.t.sol` | Smart fee math is well-defined at extreme reserve ratios (12 orders of magnitude, e.g. USDC at 6 decimals vs WETH at 18). |
| `RecipientIsSelf.t.sol`, `EntryAmountAndPathGuards.t.sol`, `ETHRefundDrain.t.sol`, `DonationAndStuckTokens.t.sol`, `ReentrancyAttempt.t.sol`, `GasGriefToken.t.sol`, `HookFlagsManipulation.t.sol`, `DoSResistance.t.sol`, `FirstMintInflation.t.sol`, `DeepMultiHop.t.sol`, `CrossPoolIsolation.t.sol` | Router-layer input guards and adversarial-token-shape resistance. |

### 9.4 Invariant fuzz campaign

`Invariants.t.sol` runs 256 invariant rounds × 500 random handler calls
per round = **128 000 random operations**, picking from three actors and
three operations (`swapExactIn`, `addLiquidity`, `removeLiquidity`) with
bounded magnitudes. The handler swallows `revert`s so the campaign keeps
moving even when a random call would normally fail. Across the run the
following invariants hold without exception (0 violations recorded over
the campaign):

| Invariant | What it proves |
|---|---|
| **`poolLiquidityEqualsSumOfPositions`** | The pool's in-range liquidity reported by `StateLibrary` equals the sum of every actor's per-owner V4 position (seeder + Alice + Bob + Carol). The per-owner-salt LP model is never out of sync with the manager's view by even one wei. |
| **`managerSolventWhileLiquidityLives`** | While the pool has any liquidity, the `PoolManager` holds non-zero balances of both currencies. Catches drain paths. |

Additionally, the in-handler `swap` operation asserts $K_{\text{after}}
\ge K_{\text{before}}$ on the virtual constant $K = L^2$, so 42 000
random swaps did not produce a single case of $K$ decreasing across a
swap.

### 9.5 Fork testing

`ForkTest.t.sol` and `ForkSwapShapesTest.t.sol` (7 tests total) run the
full stack against the canonical V4 `PoolManager` on whichever chain the
environment variable `FORK_RPC_URL` points to. When unset the tests skip
cleanly, so default `forge test` runs remain green offline. The fork
suites verify (a) the mined hook address has the right permission bits
on the target chain's actual `PoolManager`, (b) single-hop and multi-hop
swaps against the live manager succeed end-to-end, (c) `StateLibrary`
reads work against the live deployment, and (d) native-ETH round trip
plus exact-output swap shapes function as expected.

### 9.6 Coverage targets

The library-level coverage report under `forge coverage` shows 100 %
lines, branches, and functions on `SmartFeeLib`, `SpryFeeTypes`, and
`VirtualReserves`; near-100 % on `HookMiner`. The headline figures for
`SpryHook` and `SpryRouter` are subject to forge-coverage's per-
deployment aggregation artefact (each test contract that deploys its
own hook / router instance contributes its own coverage trace, and lcov
reports the *intersection* across instances). Behavioural coverage —
every public method called, every branch executed by *at least one*
test deployment — is at parity with the libraries.

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
6. **No protocol fee** at the manager level until the audit is closed
   and the mechanism is well-understood by operators: leave
   `PoolManager.setProtocolFee` at its default.

---

## 11. Conclusion

Spry mitigates impermanent loss not by removing it (which would require an
external price oracle and a re-staking insurance pool, neither of which
exist permissionlessly on every chain) but by **pricing it correctly
through the fee**. Small swaps that produce little IL pay the tier's
base rate. Large swaps that move the price meaningfully pay a fee scaled
to the IL they're about to inflict, integrated over the cumulative
trajectory the same block has already traversed so a splitter cannot
arbitrage the curve sub-block. The excess accrues to LPs through V4's
standard fee channel.

By delivering this mechanism as a Uniswap V4 hook rather than a stand-
alone AMM, Spry avoids re-implementing — and re-auditing — pool storage,
swap math, position accounting (canonical ERC-721 positions via
`PositionManager`), multi-pool isolation, native-ETH handling, flash-
accounting multi-hop, and ERC-6909 claim tokens. The Spry surface is
under 1 000 lines of Solidity; the V4 surface we inherit is approximately
10× larger and already audited at scale. This reduction in attack
surface, combined with the empirical guarantees in section 9, leaves
Spry in a strong position for an external audit to bring it to mainnet
readiness.

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

*Document version*: current. The on-chain code described herein lives at
the tip of the `main` branch of the Spry contracts repository. The
whitepaper and the code are released under GPL-3.0-or-later (see `LICENSE`).
