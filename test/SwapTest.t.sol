// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Spry} from "../contracts/Spry.sol";
import {WETH9} from "./WETH.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract SmartFeeLibTest is Test {
    Spry public pair;
    ERC20Mock public token0;
    ERC20Mock public token1;
    WETH9 public weth;

    function setUp() public {
        weth = new WETH9();
        vm.label(address(weth), "WETH");
        token0 = new ERC20Mock();
        vm.label(address(token0), "Token0");
        token1 = new ERC20Mock();
        vm.label(address(token1), "Token1");
        pair = new Spry(address(this), address(weth));
        pair.setFeeTo(address(this));
        vm.label(address(pair), "Pair");
    }

    function testSwapExactTokenForToken() public {
        deal(address(token0), address(this), 1e24);
        deal(address(token1), address(this), 1e24);
        token0.approve(address(pair), type(uint256).max);
        token1.approve(address(pair), type(uint256).max);

        (uint256 amountA, uint256 amountB, uint liquidity) = pair.addLiquidity(
            address(token0),
            address(token1),
            2e18,
            1e18,
            1,
            1,
            address(this),
            block.timestamp + 10
        );
        console.log("The liquidity added is: ", liquidity);
        console.log("amountA: ", amountA);
        console.log("amountB: ", amountB);
    }

    // function testSwapTokenForExactToken() public {
    //     deal(address(token0), address(this), 1e30);
    //     deal(address(token1), address(this), 1e30);
    //     token0.approve(address(pair), type(uint256).max);
    //     token1.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidity(
    //         address(token0),
    //         address(token1),
    //         1e19,
    //         1e19,
    //         1e19,
    //         1e19,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     (, uint fee) = pair.swapTokenForExactToken(
    //         9.9999995e18,
    //         1e28,
    //         address(token1),
    //         address(token0),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     assertLt(fee, 55, "Fee exceeds its maximum");

    //     console.log("The corrected fee is: ", fee);
    // }

    // function testSwapExactETHForToken() public {
    //     deal(address(this), 10 ether);
    //     deal(address(token0), address(this), 1e30);
    //     deal(address(weth), address(this), 1e30);
    //     token0.approve(address(pair), type(uint256).max);
    //     weth.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidityETH{value: 1 ether}(
    //         address(token0),
    //         1e18,
    //         5e17,
    //         1e16,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     (uint balance, uint balance0) = (
    //         weth.balanceOf(address(pair)),
    //         token0.balanceOf(address(pair))
    //     );
    //     console.log("WETH balance of pair is: ", balance);
    //     console.log("Token 0 balance of pair is: ", balance0);

    //     bytes memory data = abi.encodeWithSignature(
    //         "swapExactETHForToken(uint256,address,address,address,uint256)",
    //         1e16,
    //         address(weth),
    //         address(token0),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     (bool success, bytes memory returnData) = address(pair).call{
    //         value: 0.5 ether
    //     }(data);
    //     assertTrue(success, "Call not successfull");

    //     (, uint fee) = abi.decode(returnData, (uint256, uint256));

    //     assertLt(fee, 55, "Fee exceeds its maximum");

    //     console.log("The corrected fee is: ", fee);
    // }

    // function testSwapTokenForExactETH() public {
    //     deal(address(this), 10 ether);
    //     deal(address(token0), address(this), 1e30);
    //     deal(address(weth), address(this), 1e30);
    //     token0.approve(address(pair), type(uint256).max);
    //     weth.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidityETH{value: 1 ether}(
    //         address(token0),
    //         1e18,
    //         5e17,
    //         1e16,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     (uint balance, uint balance0) = (
    //         weth.balanceOf(address(pair)),
    //         token0.balanceOf(address(pair))
    //     );
    //     console.log("WETH balance of pair is: ", balance);
    //     console.log("Token 0 balance of pair is: ", balance0);

    //     bytes memory data = abi.encodeWithSignature(
    //         "swapTokenForExactETH(uint256,uint256,address,address,address,uint256)",
    //         2e17,
    //         1e18,
    //         address(token0),
    //         address(weth),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     (bool success, bytes memory returnData) = address(pair).call(data);
    //     assertTrue(success, "Call not successfull");

    //     (, uint fee) = abi.decode(returnData, (uint256, uint256));

    //     assertLt(fee, 55, "Fee exceeds its maximum");

    //     console.log("The corrected fee is: ", fee);
    // }

    // function testSwapExactTokenForETH() public {
    //     deal(address(this), 10 ether);
    //     deal(address(token0), address(this), 1e30);
    //     deal(address(weth), address(this), 1e30);
    //     token0.approve(address(pair), type(uint256).max);
    //     weth.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidityETH{value: 1 ether}(
    //         address(token0),
    //         1e18,
    //         5e17,
    //         1e16,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     (uint balance, uint balance0) = (
    //         weth.balanceOf(address(pair)),
    //         token0.balanceOf(address(pair))
    //     );
    //     console.log("WETH balance of pair is: ", balance);
    //     console.log("Token 0 balance of pair is: ", balance0);

    //     bytes memory data = abi.encodeWithSignature(
    //         "swapExactTokenForETH(uint256,uint256,address,address,address,uint256)",
    //         2e17,
    //         1e16,
    //         address(token0),
    //         address(weth),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     (bool success, bytes memory returnData) = address(pair).call(data);
    //     assertTrue(success, "Call not successfull");

    //     (, uint fee) = abi.decode(returnData, (uint256, uint256));

    //     assertLt(fee, 55, "Fee exceeds its maximum");

    //     console.log("The corrected fee is: ", fee);
    // }

    // function testSwapETHForExactToken() public {
    //     deal(address(this), 10 ether);
    //     deal(address(token0), address(this), 1e30);
    //     deal(address(weth), address(this), 1e30);
    //     token0.approve(address(pair), type(uint256).max);
    //     weth.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidityETH{value: 1 ether}(
    //         address(token0),
    //         1e18,
    //         5e17,
    //         1e16,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     (uint balance, uint balance0) = (
    //         weth.balanceOf(address(pair)),
    //         token0.balanceOf(address(pair))
    //     );
    //     console.log("WETH balance of pair is: ", balance);
    //     console.log("Token 0 balance of pair is: ", balance0);

    //     bytes memory data = abi.encodeWithSignature(
    //         "swapETHForExactToken(uint256,address,address,address,uint256)",
    //         2e17,
    //         address(weth),
    //         address(token0),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     (bool success, bytes memory returnData) = address(pair).call{
    //         value: 0.5 ether
    //     }(data);
    //     assertTrue(success, "Call not successfull");

    //     (, uint fee) = abi.decode(returnData, (uint256, uint256));

    //     assertLt(fee, 55, "Fee exceeds its maximum");

    //     console.log("The corrected fee is: ", fee);
    // }

    // function testRemoveLiquidity() public {
    //     deal(address(token0), address(this), 1e24);
    //     deal(address(token1), address(this), 1e24);
    //     token0.approve(address(pair), type(uint256).max);
    //     token1.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidity(
    //         address(token0),
    //         address(token1),
    //         1e19,
    //         1e19,
    //         5e17,
    //         5e17,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     (uint balance0, uint balance1) = (
    //         token0.balanceOf(address(pair)),
    //         token1.balanceOf(address(pair))
    //     );
    //     console.log("Token 0 balance of pair is: ", balance0);
    //     console.log("Token 1 balance of pair is: ", balance1);

    //     (uint amount0, uint amount1) = pair.removeLiquidity(
    //         address(token0),
    //         address(token1),
    //         liquidity,
    //         1e16,
    //         1e16,
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     console.log("Token 0 amount is: ", amount0);
    //     console.log("Token 1 amount is: ", amount1);

    //     assertEq(amount0, balance0 - 1000);
    //     assertEq(amount1, balance1 - 1000);
    // }

    // function testRemoveLiquidityETH() public {
    //     deal(address(this), 10 ether);
    //     deal(address(token0), address(this), 1e30);
    //     deal(address(weth), address(this), 1e30);
    //     token0.approve(address(pair), type(uint256).max);
    //     weth.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidityETH{value: 1 ether}(
    //         address(token0),
    //         1e18,
    //         5e17,
    //         1e16,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     (uint balance, uint balance0) = (
    //         weth.balanceOf(address(pair)),
    //         token0.balanceOf(address(pair))
    //     );
    //     console.log("WETH balance of pair is: ", balance);
    //     console.log("Token 0 balance of pair is: ", balance0);

    //     (uint amount, uint amount0) = pair.removeLiquidityETH(
    //         address(token0),
    //         liquidity,
    //         1e16,
    //         1e16,
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     console.log("WETH amount is: ", amount);
    //     console.log("Token 0 amount is: ", amount0);

    //     assertEq(amount, balance - 1000);
    //     assertEq(amount0, balance0 - 1000);
    // }

    // function testSwapExactTokenForTokenSupportingFOT() public {
    //     deal(address(token0), address(this), 1e30);
    //     deal(address(token1), address(this), 1e30);
    //     token0.approve(address(pair), type(uint256).max);
    //     token1.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidity(
    //         address(token0),
    //         address(token1),
    //         1e19,
    //         1e19,
    //         5e17,
    //         5e17,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     pair.swapExactTokenForTokenSupportingFOT(
    //         1e18,
    //         1e16,
    //         address(token1),
    //         address(token0),
    //         address(this),
    //         block.timestamp + 10
    //     );
    // }

    // function testMultipleSwaps() public {
    //     deal(address(token0), address(this), 1e24);
    //     deal(address(token1), address(this), 1e24);
    //     token0.approve(address(pair), type(uint256).max);
    //     token1.approve(address(pair), type(uint256).max);

    //     (, , uint liquidity) = pair.addLiquidity(
    //         address(token0),
    //         address(token1),
    //         1e19,
    //         1e19,
    //         5e17,
    //         5e17,
    //         address(this),
    //         block.timestamp + 10
    //     );
    //     console.log("The liquidity added is: ", liquidity);

    //     (uint amount, uint fee) = pair.swapExactTokenForToken(
    //         1e18,
    //         1e16,
    //         address(token1),
    //         address(token0),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     console.log("The first time fee is: ", fee);
    //     assertLt(fee, 55, "Fee exceeds its maximum");

    //     (amount, fee) = pair.swapExactTokenForToken(
    //         1e18,
    //         1e16,
    //         address(token0),
    //         address(token1),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     console.log("The second time fee is: ", fee);
    //     assertLt(fee, 55, "Fee exceeds its maximum");

    //     (amount, fee) = pair.swapExactTokenForToken(
    //         1.1e20,
    //         1e16,
    //         address(token1),
    //         address(token0),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     console.log("The second time fee is: ", fee);
    //     assertLt(fee, 55, "Fee exceeds its maximum");

    //     (amount, fee) = pair.swapExactTokenForToken(
    //         5e20,
    //         1e16,
    //         address(token0),
    //         address(token1),
    //         address(this),
    //         block.timestamp + 10
    //     );

    //     console.log("The second time fee is: ", fee);
    //     assertLt(fee, 55, "Fee exceeds its maximum");
    // }

    receive() external payable {
        require(msg.sender == address(pair));
    }
}
