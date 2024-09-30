// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/*************************************************\
|-*-*-*-*-*-*-*-*-*   IMPORTS   *-*-*-*-*-*-*-*-*-|
\*************************************************/
// Interfaces
import {ICFC20} from "./interfaces/ICFC20.sol";
import {IWXFI} from "./interfaces/IWXFI.sol";
// Libraries
import {Math} from "./libs/Math.sol";
import {TransferHelper} from "./libs/TransferHelper.sol";
// Contracts, Abstracts
import {DeftPairManager} from "./DeftPairManager.sol";

contract DeftDEX is DeftPairManager {
    using Math for uint256;
    using TransferHelper for address;

    /*******************************\
    |-*-*-*-*-*   TYPES   *-*-*-*-*-|
    \*******************************/
    struct SwapAntiDeepStack {
        uint256 amount0In;
        uint256 amount1In;
        uint256 amount0Out;
        uint256 amount1Out;
    }

    struct RemoveLiquidityAntiDeepStack {
        address to;
        uint256 liquidity;
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 amountAMin;
        uint256 amountBMin;
    }

    /********************************\
    |-*-*-*-*-*   STATES   *-*-*-*-*-|
    \********************************/
    address public owner;
    address public feeTo;
    address public feeToSetter;
    uint256 public locked;

    /*******************************\
    |-*-*-*-*   CONSTANTS   *-*-*-*-|
    \*******************************/
    address public immutable WXFI;
    uint256 public constant MINIMUM_LIQUIDITY = 10**3;

    /*******************************\
    |-*-*-*-*   MODIFIERS   *-*-*-*-|
    \*******************************/
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "DeftDEX: EXPIRED");

        _;
    }

    /******************************\
    |-*-*-*-*   BUILT-IN   *-*-*-*-|
    \******************************/
    modifier noReentrant() {
        require(locked == 0, "DeftDEX: RE-ENTRANT");
        locked = 1;
        _;
        delete locked;
    }

    constructor(address fts, address wxfi) {
        owner = msg.sender;
        feeToSetter = fts;

        require(wxfi != address(0), "DeftDEX: ZERO_ADDRESS");

        WXFI = wxfi;
    }

    receive() external payable {
        require(msg.sender == WXFI, "DeftDEX: ONLY_WXFI");
    }

    /*******************************\
    |-*-*-*   ADMINSTRATION   *-*-*-|
    \*******************************/
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "DeftDEX: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "DeftDEX: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }

    /*******************************\
    |-*-*-*-*   DEX-LOGIC   *-*-*-*-|
    \*******************************/
    function skim(
        address to,
        address tokenA,
        address tokenB
    ) external noReentrant {
        (bytes32 pairID, address token0, address token1) = _pairChecker(
            tokenA,
            tokenB,
            false
        );

        token0.safeTransfer(
            to,
            ICFC20(token0).balanceOf(address(this)) - pairData[pairID].reserve0
        );
        token1.safeTransfer(
            to,
            ICFC20(token1).balanceOf(address(this)) - pairData[pairID].reserve1
        );
    }

    function sync(address tokenA, address tokenB) external noReentrant {
        (bytes32 pairID, address token0, address token1) = _pairChecker(
            tokenA,
            tokenB,
            false
        );

        _update(
            pairID,
            ICFC20(token0).balanceOf(address(this)),
            ICFC20(token1).balanceOf(address(this)),
            pairData[pairID].reserve0,
            pairData[pairID].reserve1
        );
    }

    function swapExactTokenForToken(
        uint256 amountIn,
        uint256 amountOutMin,
        address path0,
        address path1,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        noReentrant
        returns (uint256 amount, uint256 correctedFee)
    {
        (amount, correctedFee) = getAmountOut(amountIn, path0, path1);

        require(amount >= amountOutMin, "DeftDEX: INSUFFICIENT_OUTPUT_AMOUNT");

        path0.safeTransferFrom(msg.sender, address(this), amount);

        _swap(amount, path0, path1, to, correctedFee, false);
    }

    function swapTokenForExactToken(
        uint256 amountOut,
        uint256 amountInMax,
        address path0,
        address path1,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        noReentrant
        returns (uint256 amount, uint256 correctedFee)
    {
        (amount, correctedFee) = getAmountIn(amountOut, path0, path1);

        require(amount <= amountInMax, "DeftDEX: EXCESSIVE_INPUT_AMOUNT");

        path0.safeTransferFrom(msg.sender, address(this), amount);

        _swap(amount, path0, path1, to, correctedFee, false);
    }

    function swapExactXFIForToken(
        uint256 amountOutMin,
        address path0,
        address path1,
        address to,
        uint256 deadline
    )
        external
        payable
        ensure(deadline)
        noReentrant
        returns (uint256 amount, uint256 correctedFee)
    {
        require(path0 == WXFI, "DeftDEX: INVALID_PATH");

        (amount, correctedFee) = getAmountOut(msg.value, path0, path1);

        require(amount >= amountOutMin, "DeftDEX: INSUFFICIENT_OUTPUT_AMOUNT");

        IWXFI(WXFI).deposit{value: amount}();

        _swap(amount, path0, path1, to, correctedFee, false);
    }

    function swapTokenForExactXFI(
        uint256 amountOut,
        uint256 amountInMax,
        address path0,
        address path1,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        noReentrant
        returns (uint256 amount, uint256 correctedFee)
    {
        require(path1 == WXFI, "DeftDEX: INVALID_PATH");

        (amount, correctedFee) = getAmountIn(amountOut, path0, path1);

        require(amount <= amountInMax, "DeftDEX: EXCESSIVE_INPUT_AMOUNT");

        path0.safeTransferFrom(msg.sender, address(this), amount);

        _swap(amount, path0, path1, to, correctedFee, true);
    }

    function swapExactTokenForXFI(
        uint256 amountIn,
        uint256 amountOutMin,
        address path0,
        address path1,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        noReentrant
        returns (uint256 amount, uint256 correctedFee)
    {
        require(path1 == WXFI, "DeftDEX: INVALID_PATH");

        (amount, correctedFee) = getAmountOut(amountIn, path0, path1);

        require(amount >= amountOutMin, "DeftDEX: INSUFFICIENT_OUTPUT_AMOUNT");

        path0.safeTransferFrom(msg.sender, address(this), amount);

        _swap(amount, path0, path1, to, correctedFee, true);
    }

    function swapXFIForExactToken(
        uint256 amountOut,
        address path0,
        address path1,
        address to,
        uint256 deadline
    )
        external
        payable
        ensure(deadline)
        noReentrant
        returns (uint256 amount, uint256 correctedFee)
    {
        require(path0 == WXFI, "DeftDEX: INVALID_PATH");

        (amount, correctedFee) = getAmountIn(amountOut, path0, path1);

        require(amount <= msg.value, "DeftDEX: EXCESSIVE_INPUT_AMOUNT");

        IWXFI(WXFI).deposit{value: amount}();

        _swap(amount, path0, path1, to, correctedFee, false);

        if (msg.value > amount)
            (msg.sender).safeTransferXFI(msg.value - amount);
    }

    function swapExactTokenForTokenSupportingFOT(
        uint256 amountIn,
        uint256 amountOutMin,
        address path0,
        address path1,
        address to,
        uint256 deadline
    ) external ensure(deadline) noReentrant {
        path0.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 balanceBefore = ICFC20(path1).balanceOf(to);

        _swapSupportingFOT(path0, path1, to, false);

        require(
            ICFC20(path1).balanceOf(to) - balanceBefore >= amountOutMin,
            "DeftDEX: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactXFIForTokenSupportingFOT(
        uint256 amountOutMin,
        address path0,
        address path1,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) noReentrant {
        require(path0 == WXFI, "DeftDEX: INVALID_PATH");

        IWXFI(WXFI).deposit{value: msg.value}();

        uint256 balanceBefore = ICFC20(path1).balanceOf(to);

        _swapSupportingFOT(path0, path1, to, false);

        require(
            ICFC20(path1).balanceOf(to) - balanceBefore >= amountOutMin,
            "DeftDEX: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactTokenForXFISupportingFOT(
        uint256 amountIn,
        uint256 amountOutMin,
        address path0,
        address path1,
        address to,
        uint256 deadline
    ) external ensure(deadline) noReentrant {
        require(path1 == WXFI, "DeftDEX: INVALID_PATH");

        path0.safeTransferFrom(msg.sender, address(this), amountIn);

        _swapSupportingFOT(path0, path1, to, true);

        uint256 amountOut = ICFC20(WXFI).balanceOf(address(this));

        require(
            amountOut >= amountOutMin,
            "DeftDEX: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        noReentrant
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        bytes32 pairID;
        (amountA, amountB, pairID) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );

        TransferHelper.safeTransferFrom(
            tokenA,
            msg.sender,
            address(this),
            amountA
        );
        TransferHelper.safeTransferFrom(
            tokenB,
            msg.sender,
            address(this),
            amountB
        );

        (uint112 reserve0, uint112 reserve1, ) = getReserves(pairID);
        uint256 balance0 = ICFC20(pairData[pairID].tokens[0]).balanceOf(
            address(this)
        );
        uint256 balance1 = ICFC20(pairData[pairID].tokens[1]).balanceOf(
            address(this)
        );
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;
        bool feeOn = _mintFee(pairID, reserve0, reserve1);
        uint256 _totalSupply = totalSupply(pairID);
        address _to = to; // to avoid deep-stack error

        if (_totalSupply == 0) {
            liquidity = (amount0 * amount1).sqrt() - MINIMUM_LIQUIDITY;

            _mint(pairID, address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = ((amount0 * _totalSupply) / reserve0).min(
                (amount1 * _totalSupply) / reserve1
            );
        }

        require(liquidity != 0, "DeftDEX: INSUFFICIENT_LIQUIDITY_MINTED");

        _mint(pairID, _to, liquidity);
        _update(pairID, balance0, balance1, reserve0, reserve1);

        if (feeOn)
            pairData[pairID].kLast =
                pairData[pairID].reserve0 *
                pairData[pairID].reserve1;

        emit Mint(msg.sender, amount0, amount1);
    }

    function addLiquidityXFI(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountXFIMin,
        address to,
        uint256 deadline
    )
        external
        payable
        ensure(deadline)
        noReentrant
        returns (
            uint256 amountToken,
            uint256 amountXFI,
            uint256 liquidity
        )
    {
        bytes32 pairID;
        (amountToken, amountXFI, pairID) = _addLiquidity(
            token,
            WXFI,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountXFIMin
        );

        token.safeTransferFrom(msg.sender, address(this), amountToken);
        IWXFI(WXFI).deposit{value: amountXFI}();

        (uint112 reserve0, uint112 reserve1, ) = getReserves(pairID);
        uint256 balance0 = ICFC20(pairData[pairID].tokens[0]).balanceOf(
            address(this)
        );
        uint256 balance1 = ICFC20(pairData[pairID].tokens[1]).balanceOf(
            address(this)
        );
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;
        bool feeOn = _mintFee(pairID, reserve0, reserve1);
        uint256 _totalSupply = totalSupply(pairID);
        address _to = to; // to avoid deep-stack error

        if (_totalSupply == 0) {
            liquidity = (amount0 * amount1).sqrt() - MINIMUM_LIQUIDITY;

            _mint(pairID, address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = ((amount0 * _totalSupply) / reserve0).min(
                (amount1 * _totalSupply) / reserve1
            );
        }

        require(liquidity != 0, "DeftDEX: INSUFFICIENT_LIQUIDITY_MINTED");

        _mint(pairID, _to, liquidity);
        _update(pairID, balance0, balance1, reserve0, reserve1);

        if (feeOn)
            pairData[pairID].kLast =
                pairData[pairID].reserve0 *
                pairData[pairID].reserve1;

        emit Mint(msg.sender, amount0, amount1);

        if (msg.value > amountXFI)
            (msg.sender).safeTransferXFI(msg.value - amountXFI);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        noReentrant
        returns (uint256 amountTokenA, uint256 amountTokenB)
    {
        (amountTokenA, amountTokenB) = _removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            to,
            true
        );
    }

    function removeLiquidityXFI(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountXFIMin,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        noReentrant
        returns (uint256 amountToken, uint256 amountXFI)
    {
        (amountToken, amountXFI) = _removeLiquidity(
            token,
            WXFI,
            liquidity,
            amountTokenMin,
            amountXFIMin,
            to,
            false
        );
    }

    function removeLiquidityXFISupportingFOT(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountXFIMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) noReentrant returns (uint256 amountXFI) {
        (, amountXFI) = _removeLiquidity(
            token,
            WXFI,
            liquidity,
            amountTokenMin,
            amountXFIMin,
            to,
            false
        );
    }

    function _removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        bool canTransferToken
    ) private returns (uint256, uint256) {
        RemoveLiquidityAntiDeepStack memory ads = RemoveLiquidityAntiDeepStack(
            to,
            liquidity,
            tokenA,
            tokenB,
            0,
            0,
            amountAMin,
            amountBMin
        );

        (bytes32 pairID, address token0, address token1) = _pairChecker(
            ads.tokenA,
            ads.tokenB,
            false
        );

        transferFrom(pairID, msg.sender, address(this), ads.liquidity);

        (uint112 reserve0, uint112 reserve1, ) = getReserves(pairID);
        uint256 balance0 = ICFC20(token0).balanceOf(address(this));
        uint256 balance1 = ICFC20(token1).balanceOf(address(this));
        uint256 lp = balanceOf(pairID, address(this));
        bool feeOn = _mintFee(pairID, reserve0, reserve1);
        uint256 _totalSupply = totalSupply(pairID);
        uint256 amount0 = (lp * balance0) / _totalSupply; // using balances ensures pro-rata distribution
        uint256 amount1 = (lp * balance1) / _totalSupply; // using balances ensures pro-rata distribution

        require(
            amount0 != 0 && amount1 != 0,
            "DeftDEX: INSUFFICIENT_LIQUIDITY_BURNED"
        );

        _burn(pairID, address(this), lp);

        if (canTransferToken || token0 != WXFI) token0.safeTransfer(ads.to, amount0);
        else {
            IWXFI(WXFI).withdraw(amount0);
            (ads.to).safeTransferXFI(amount0);
        }

        if (canTransferToken || token1 != WXFI) token1.safeTransfer(ads.to, amount1);
        else {
            IWXFI(WXFI).withdraw(amount1);
            (ads.to).safeTransferXFI(amount1);
        }

        balance0 = ICFC20(token0).balanceOf(address(this));
        balance1 = ICFC20(token1).balanceOf(address(this));

        _update(pairID, balance0, balance1, reserve0, reserve1);

        if (feeOn)
            pairData[pairID].kLast =
                uint256(pairData[pairID].reserve0) *
                pairData[pairID].reserve1;

        emit Burn(msg.sender, amount0, amount1, ads.to);

        (ads.amountA, ads.amountB) = ads.tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);

        require(
            ads.amountA >= ads.amountAMin,
            "DeftDEX: INSUFFICIENT_A_AMOUNT"
        );
        require(
            ads.amountB >= ads.amountBMin,
            "DeftDEX: INSUFFICIENT_B_AMOUNT"
        );

        return (ads.amountA, ads.amountB);
    }

    /*******************************\
    |-*-*-*-*   INTERNALS   *-*-*-*-|
    \*******************************/
    function _swap(
        uint256 amount,
        address path0,
        address path1,
        address to,
        uint256 correctedFee,
        bool unwrapable
    ) private {
        // input = path0 | output = path1
        (bytes32 pairID, address token0, ) = _pairChecker(path0, path1, false);

        // amount0Out = 0 | amount1Out = amounts[1]
        _finalizeSwap(
            pairID,
            path0 == token0 ? 0 : amount,
            path1 != token0 ? amount : 0,
            to,
            correctedFee,
            unwrapable
        );
    }

    function _swapSupportingFOT(
        address path0,
        address path1,
        address to,
        bool unwrapable
    ) private {
        // input = path0 | output = path1
        (bytes32 pairID, address token0, ) = _pairChecker(path0, path1, false);

        (uint112 reserve0, uint112 reserve1, ) = getReserves(pairID);
        (uint256 reserveInput, ) = path0 == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        uint256 amountInput = ICFC20(path0).balanceOf(address(this)) -
            reserveInput;
        (uint256 amountOutput, uint256 correctedFee) = getAmountOut(
            amountInput,
            path0,
            path1
        );

        // amount0Out = 0 | amount1Out = amountOutput
        _finalizeSwap(
            pairID,
            path0 == token0 ? 0 : amountOutput,
            path0 != token0 ? amountOutput : 0,
            to,
            correctedFee,
            unwrapable
        );
    }

    function _finalizeSwap(
        bytes32 pairID,
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        uint256 correctedFee,
        bool unwrapable
    ) private {
        require(
            amount0Out != 0 || amount1Out != 0,
            "DeftDEX: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        (uint112 reserve0, uint112 reserve1, ) = getReserves(pairID);

        require(
            amount0Out < reserve0 && amount1Out < reserve1,
            "DeftDEX: INSUFFICIENT_LIQUIDITY"
        );

        address token0 = pairData[pairID].tokens[0];
        address token1 = pairData[pairID].tokens[1];

        require(
            to != token0 && to != token1 && to != address(this),
            "DeftDEX: INVALID_TO"
        );

        if (amount0Out != 0) {
            if (token0 == WXFI && unwrapable) {
                IWXFI(WXFI).withdraw(amount0Out);
                to.safeTransferXFI(amount0Out);
            } else token0.safeTransfer(to, amount0Out);
        }
        if (amount1Out != 0) {
            if (token1 == WXFI && unwrapable) {
                IWXFI(WXFI).withdraw(amount1Out);
                to.safeTransferXFI(amount1Out);
            } else token1.safeTransfer(to, amount1Out);
        }

        uint256 balance0 = ICFC20(token0).balanceOf(address(this));
        uint256 balance1 = ICFC20(token1).balanceOf(address(this));

        if (amount0Out != 0) balance0 -= amount0Out;
        if (amount1Out != 0) balance1 -= amount1Out;

        SwapAntiDeepStack memory ads = SwapAntiDeepStack(
            balance0 > reserve0 - amount0Out
                ? balance0 - (reserve0 - amount0Out)
                : 0,
            balance1 > reserve1 - amount1Out
                ? balance1 - (reserve1 - amount1Out)
                : 0,
            amount0Out,
            amount1Out
        );

        require(
            ads.amount0In != 0 || ads.amount1In != 0,
            "DeftDEX: INSUFFICIENT_INPUT_AMOUNT"
        );

        require(
            (balance0 * 1000 - ads.amount0In * correctedFee) *
                (balance1 * 1000 - ads.amount1In * correctedFee) >=
                uint256(reserve0) * reserve1 * 1e6,
            "DeftDEX: K"
        );

        _update(pairID, balance0, balance1, reserve0, reserve1);

        emit Swap(
            msg.sender,
            ads.amount0In,
            ads.amount1In,
            ads.amount0Out,
            ads.amount1Out,
            to
        );
    }

    function _mintFee(
        bytes32 pairID,
        uint112 reserve0,
        uint112 reserve1
    ) private returns (bool feeOn) {
        feeOn = feeTo != address(0);
        uint256 _kLast = pairData[pairID].kLast;

        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = (uint256(reserve0) * reserve1).sqrt();
                uint256 rootKLast = _kLast.sqrt();

                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply(pairID) *
                        (rootK - rootKLast);
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity = numerator / denominator;

                    if (liquidity != 0) _mint(pairID, feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            pairData[pairID].kLast = 0;
        }
    }
}
