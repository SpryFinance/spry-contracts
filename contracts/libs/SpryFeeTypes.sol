// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

/// @notice One complete tier definition for the SmartFee dynamic-fee curve.
///         Pool creators select a tier at `manager.initialize` time by
///         OR-ing the tier index into the lower bits of `PoolKey.fee`
///         (alongside the V4 `DYNAMIC_FEE_FLAG`). The lower-8-bit tier index
///         then dispatches to one of these parameter sets inside the hook.
///
/// @dev    All fee values are in V4 pips (1_000_000 = 100%). Zone boundaries
///         are in per-mille of pool reserves — the same "delta" unit
///         SmartFee uses internally. Linear and exponential coefficients
///         are pre-computed by solving the boundary-continuity equations
///         (linear: 2-equation/2-unknown; exponential: log + exponential
///         isolation). The contract trusts them as immutables.
///
///         Storage cost: this struct lives only in `memory` (returned from
///         a pure `_tierParams` dispatch). Five tiers × 128 bytes/tier = 640
///         bytes of bytecode-baked immutable data total. No SLOADs.
struct SpryFeeParams {
    // -----------------------------------------------------------------
    // Zone boundaries (signed per-mille of reserve shift)
    //
    //     |<──── danger (left) ────|< alert (left) >|< safe >|<alert (R)>| danger (R) ──>|
    //                              ^                ^         ^           ^
    //                          alertLow          safeLow   safeHigh   alertHigh
    //                       (& dangerLow)                              (& dangerHigh
    //                                                                    on +infinity end)
    //
    // The "cap zone" is everything beyond `dangerLow` and `dangerHigh`;
    // it returns the flat `capFee` regardless of magnitude.
    // -----------------------------------------------------------------
    int32 safeLow;        // (negative) end of safe zone
    int32 safeHigh;       // (positive) end of safe zone
    int32 alertLow;       // (negative) end of alert zone / start of danger
    int32 alertHigh;      // (positive) end of alert zone / start of danger
    int32 dangerLow;      // (negative) end of danger zone / start of cap
    int32 dangerHigh;     // (positive) end of danger zone / start of cap

    // -----------------------------------------------------------------
    // Linear-zone (alert) coefficients
    //
    //     fee_pips = (a · delta + 1000 · b) / 1_000_000
    //
    // Solved per tier so that:
    //   _linear(aLeft,  bLeft,  safeLow)   == safeFee
    //   _linear(aLeft,  bLeft,  alertLow)  == alertEdgeFee  (the fee at
    //                                                        alert→danger
    //                                                        boundary)
    //   _linear(aRight, bRight, safeHigh)  == safeFee  (after int trunc)
    //   _linear(aRight, bRight, alertHigh) == alertEdgeFee
    // -----------------------------------------------------------------
    int64 aLeft;
    int64 bLeft;
    int64 aRight;
    int64 bRight;

    // -----------------------------------------------------------------
    // Danger-zone (exponential) coefficients, SD59x18-scaled
    //
    //     fee_pips = (a · exp(b · delta / 1000)) / 1e36
    //
    // Solved per tier so that:
    //   _exp(aLeftExp,  bLeftExp,  alertLow)   ≈ alertEdgeFee
    //   _exp(aLeftExp,  bLeftExp,  dangerLow)  ≈ dangerEdgeFee
    //   _exp(aRightExp, bRightExp, alertHigh)  ≈ alertEdgeFee
    //   _exp(aRightExp, bRightExp, dangerHigh) ≈ dangerEdgeFee
    // -----------------------------------------------------------------
    int128 aLeftExp;
    int128 bLeftExp;
    int128 aRightExp;
    int128 bRightExp;

    // -----------------------------------------------------------------
    // Constant zones (in V4 pips directly)
    //   safeFee:  fee charged anywhere inside [safeLow, safeHigh]
    //   capFee:   fee charged anywhere outside [dangerLow, dangerHigh]
    // -----------------------------------------------------------------
    uint32 safeFee;
    uint32 capFee;
}
