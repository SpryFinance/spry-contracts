// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {SmartFeeLib, ReserveInOut} from "../contracts/libs/SmartFeeLib.sol";

contract SmartFeeLibTest is Test {
    // function testFeeCalculations() public pure {
    //     ReserveInOut memory reserveInOutZero = ReserveInOut(0, 0, 0, 0);
    //     assertEq(
    //         SmartFeeLib.getCorrectedFee(reserveInOutZero),
    //         0,
    //         "Fee should be 0 when reserves are zero."
    //     );

    //     ReserveInOut memory reserveInOutNormal = ReserveInOut(
    //         100,
    //         0,
    //         1000,
    //         1000
    //     );
    //     assertEq(
    //         SmartFeeLib.getCorrectedFee(reserveInOutNormal),
    //         3,
    //         "Normal fee within thresholds should be 3."
    //     );

    //     ReserveInOut memory reserveInOutLowerBoundary = ReserveInOut(
    //         50,
    //         0,
    //         1000,
    //         2000
    //     );
    //     uint256 expectedLowerFee = uint256(
    //         SmartFeeLib._calculateModifiedFee(
    //             SmartFeeLib.A_LEFT,
    //             SmartFeeLib.B_LEFT,
    //             -250
    //         )
    //     );
    //     assertEq(
    //         SmartFeeLib.getCorrectedFee(reserveInOutLowerBoundary),
    //         expectedLowerFee,
    //         "Fee at lower boundary should be calculated using linear regression."
    //     );

    //     ReserveInOut memory reserveInOutUpperBoundary = ReserveInOut(
    //         334,
    //         0,
    //         1000,
    //         300
    //     );
    //     uint256 expectedUpperFee = uint256(
    //         SmartFeeLib._calculateModifiedFee(
    //             SmartFeeLib.A_RIGHT,
    //             SmartFeeLib.B_RIGHT,
    //             334
    //         )
    //     );
    //     assertEq(
    //         SmartFeeLib.getCorrectedFee(reserveInOutUpperBoundary),
    //         expectedUpperFee,
    //         "Fee at upper boundary should be calculated using linear regression."
    //     );

    //     ReserveInOut memory reserveInOutLowerExp = ReserveInOut(10, 0, 1000, 10000);
    //     uint256 expectedLowerExpFee = uint256(SmartFeeLib._calculateStopCF(SmartFeeLib.A_LEFT_EXP, SmartFeeLib.B_LEFT_EXP, -500));
    //     assertEq(SmartFeeLib.getCorrectedFee(reserveInOutLowerExp), expectedLowerExpFee, "Exponential fee calculation should apply for extreme lower stop limit.");

        // ReserveInOut memory reserveInOutUpperExp = ReserveInOut(1000, 0, 1000, 100);
        // uint256 expectedUpperExpFee = uint256(SmartFeeLib._calculateStopCF(SmartFeeLib.A_RIGHT_EXP, SmartFeeLib.B_RIGHT_EXP, 1000));
        // assertEq(SmartFeeLib.getCorrectedFee(reserveInOutUpperExp), expectedUpperExpFee, "Exponential fee calculation should apply for extreme upper stop limit.");

        // ReserveInOut memory reserveInOutHighDelta = ReserveInOut(
        //     10000,
        //     0,
        //     1000,
        //     10
        // );
        // assertEq(
        //     SmartFeeLib.getCorrectedFee(reserveInOutHighDelta),
        //     55,
        //     "Default fee for high delta out of bounds should be 55."
        // );

        // ReserveInOut memory reserveInOutLowDelta = ReserveInOut(10, 0, 1000, 50000);
        // assertEq(SmartFeeLib.getCorrectedFee(reserveInOutLowDelta), 55, "Default fee for low delta out of bounds should be 55.");
    // }
}
