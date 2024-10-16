// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

/*************************************************\
|-*-*-*-*-*-*-*-*-*   IMPORTS   *-*-*-*-*-*-*-*-*-|
\*************************************************/
// Interfaces
import {ICFC20Meta} from "./interfaces/ICFC20Meta.sol";
// Libraries
import {UQ112x112} from "./libs/UQ112x112.sol";
import {SmartFeeLib, ReserveInOut} from "./libs/SmartFeeLib.sol";
// Contracts, Abstracts
import {ModifiedERC6909} from "./ModifiedERC6909.sol";

/// @title Deft pair manager contract
/// @notice This contract provides pair-related tasks at low-level
/// @dev ERC6909 standard is intended to facilitate calculations
abstract contract DeftPairManager is ModifiedERC6909 {
    using UQ112x112 for uint112;
    using UQ112x112 for uint224;
    using SmartFeeLib for ReserveInOut;

    /*******************************\
    |-*-*-*-*-*   TYPES   *-*-*-*-*-|
    \*******************************/
    struct Pair {
        address[2] tokens;
        uint112 reserve0;
        uint112 reserve1;
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        uint256 kLast;
        uint32 blockTimestampLast;
    }

    /********************************\
    |-*-*-*-*-*   STATES   *-*-*-*-*-|
    \********************************/
    bytes32[] public allPairs;
    mapping(bytes32 pairID => Pair) public pairData;

    /********************************\
    |-*-*-*-*-*   EVENTS   *-*-*-*-*-|
    \********************************/
    event PairInitialized(
        address indexed token0,
        address indexed token1,
        bytes32 pairID,
        uint256 totalPairs
    );
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    /*******************************\
    |-*-*-*-*   MODIFIERS   *-*-*-*-|
    \*******************************/
    modifier pairMustExist(bytes32 pairID) {
        require(
            pairData[pairID].blockTimestampLast != 0,
            "DeftDEX: PAIR_DOESNT_EXIST"
        );
        _;
    }

    /******************************\
    |-*-*-*-*-*   VIEW   *-*-*-*-*-|
    \******************************/
    function name(bytes32 pairID)
        external
        view
        pairMustExist(pairID)
        returns (string memory)
    {
        return
            string(
                abi.encodePacked(
                    ICFC20Meta(pairData[pairID].tokens[0]).symbol(),
                    "/",
                    ICFC20Meta(pairData[pairID].tokens[1]).symbol(),
                    " Deft Pair"
                )
            );
    }

    function symbol(bytes32 pairID)
        external
        view
        pairMustExist(pairID)
        returns (string memory)
    {
        return
            string(
                abi.encodePacked(
                    ICFC20Meta(pairData[pairID].tokens[0]).symbol(),
                    "/",
                    ICFC20Meta(pairData[pairID].tokens[1]).symbol(),
                    "-DP"
                )
            );
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function getReserves(bytes32 pairID)
        public
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        )
    {
        (reserve0, reserve1, blockTimestampLast) = (
            pairData[pairID].reserve0,
            pairData[pairID].reserve1,
            pairData[pairID].blockTimestampLast
        );
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(
        uint256 amountIn,
        address path0,
        address path1
    ) public view returns (uint256 amountOut, uint256 correctedFee) {
        require(amountIn != 0, "DeftDEX: INSUFFICIENT_INPUT_AMOUNT");

        (bytes32 pairID, address token0, ) = _sortTokens(path0, path1);
        (uint256 reserveIn, uint256 reserveOut) = _sortReserves(
            pairID,
            token0,
            path0
        );

        require(
            reserveIn != 0 && reserveOut != 0,
            "DeftDEX: INSUFFICIENT_LIQUIDITY"
        );

        (uint256 amount0OutNoFee, uint256 amount1OutNoFee) = (path0 == token0)
            ? (uint256(0), (amountIn * reserveOut) / (reserveIn + amountIn))
            : ((amountIn * reserveOut) / (reserveIn + amountIn), uint256(0));

        ReserveInOut memory r = ReserveInOut(
            reserveIn,
            reserveOut,
            amount0OutNoFee,
            amount1OutNoFee
        );

        correctedFee = r.getCorrectedFee();
        amountOut =
            (amountIn * (1000 - correctedFee) * reserveOut) /
            (reserveIn * 1000 + (amountIn * (1000 - correctedFee)));
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(
        uint256 amountOut,
        address path0,
        address path1
    ) public view returns (uint256 amountIn, uint256 correctedFee) {
        require(amountOut != 0, "DeftDEX: INSUFFICIENT_OUTPUT_AMOUNT");

        (bytes32 pairID, address token0, ) = _sortTokens(path0, path1);
        (uint256 reserveIn, uint256 reserveOut) = _sortReserves(
            pairID,
            token0,
            path0
        );

        require(
            reserveIn != 0 && reserveOut != 0,
            "DeftDex: INSUFFICIENT_LIQUIDITY"
        );

        (uint256 amount0OutNoFee, uint256 amount1OutNoFee) = (path0 == token0)
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));

        ReserveInOut memory r = ReserveInOut(
            reserveIn,
            reserveOut,
            amount0OutNoFee,
            amount1OutNoFee
        );

        correctedFee = r.getCorrectedFee();
        amountIn =
            (reserveIn * amountOut * 1000) /
            ((reserveOut - amountOut) * (1000 - correctedFee)) +
            1;
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public pure returns (uint256) {
        require(amountA != 0, "DeftDEX: INSUFFICIENT_AMOUNT");
        require(reserveA != 0 && reserveB != 0, "DeftDEX: INSUFFICIENT_LIQUIDITY");

        return (amountA * reserveB) / reserveA;
    }

    /*******************************\
    |-*-*-*-*   INTERNALS   *-*-*-*-|
    \*******************************/
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    )
        internal
        returns (
            uint256 amountA,
            uint256 amountB,
            bytes32 pairID
        )
    {
        address token0;
        (pairID, token0, ) = _pairChecker(tokenA, tokenB, true);

        (uint256 reserveA, uint256 reserveB) = _sortReserves(
            pairID,
            token0,
            tokenA
        );

        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(
                    amountBOptimal >= amountBMin,
                    "DeftDEX: INSUFFICIENT_B_AMOUNT"
                );
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                require(
                    amountAOptimal >= amountAMin,
                    "DeftDEX: INSUFFICIENT_A_AMOUNT"
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function _update(
        bytes32 pairID,
        uint256 balance0,
        uint256 balance1,
        uint112 reserve0,
        uint112 reserve1
    ) internal {
        require(
            balance0 <= type(uint112).max && balance1 <= type(uint112).max,
            "DeftDEX: OVERFLOW"
        );

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);

        unchecked {
            uint32 timeElapsed = blockTimestamp -
                pairData[pairID].blockTimestampLast;

            if (timeElapsed != 0 && reserve0 != 0 && reserve1 != 0) {
                pairData[pairID].price0CumulativeLast +=
                    uint256((reserve1.encode()).uqdiv(reserve0)) *
                    timeElapsed;
                pairData[pairID].price1CumulativeLast +=
                    uint256((reserve0.encode()).uqdiv(reserve1)) *
                    timeElapsed;
            }
        }

        pairData[pairID].reserve0 = uint112(balance0);
        pairData[pairID].reserve1 = uint112(balance1);
        pairData[pairID].blockTimestampLast = blockTimestamp;

        emit Sync(uint112(balance0), uint112(balance1));
    }

    function _pairChecker(
        address tokenA,
        address tokenB,
        bool initializable
    )
        internal
        returns (
            bytes32 pairID,
            address token0,
            address token1
        )
    {
        (pairID, token0, token1) = _sortTokens(tokenA, tokenB);

        if (initializable && pairData[pairID].blockTimestampLast == 0) {
            allPairs.push(pairID);
            pairData[pairID].tokens = [token0, token1];

            emit PairInitialized(token0, token1, pairID, allPairs.length);
        }
    }

    function _sortReserves(
        bytes32 pairID,
        address token0,
        address tokenA
    ) private view returns (uint256 reserveA, uint256 reserveB) {
        (reserveA, reserveB) = tokenA == token0
            ? (pairData[pairID].reserve0, pairData[pairID].reserve1)
            : (pairData[pairID].reserve1, pairData[pairID].reserve0);
    }

    function _sortTokens(address tokenA, address tokenB)
        private
        pure
        returns (
            bytes32 pairID,
            address token0,
            address token1
        )
    {
        require(tokenA != tokenB, "DeftDEX: IDENTICAL_ADDRESSES");

        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        require(token0 != address(0), "DeftDEX: ZERO_ADDRESS");

        pairID = keccak256(abi.encodePacked(token0, token1));
    }
}
