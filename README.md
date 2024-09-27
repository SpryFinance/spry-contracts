# <img src="https://github.com/DeftFinance/deft-dex-contracts/blob/main/assets/DEFT-Logo.png"  width="28px" height="28px"> Deft Dex

## Deft-DEX
Deft is a decentralized exchange (DEX) designed to address the significant issue of impermanent loss in uniform liquidity constant product automated market makers (AMMs), a prevalent concern for liquidity providers (LPs) in traditional DEXs. Deft introduces innovative features such as uniform liquidity and an advanced dynamic fee calculation mechanism to mitigate impermanent loss, creating a more secure and profitable environment for LPs. Additionally, Deft ensures a fair and efficient trading experience for liquidity takers (LTs), balancing the needs of all participants. By addressing these critical challenges and leveraging cutting-edge technology, Deft sets a new standard in the decentralized finance (DeFi) space, fostering greater confidence and participation among users.
The main aim here is to keep the Liquidity Takers (LTs) incentivized as well as protect the Liquidity Providers (LPs) from harsh price changes which will lead to impermanent loss. Considering the previous research and studies, the goal of this research is to reduce and optimize the impermanent loss which is a feature of Constant Product Market Makers (CPMM), rather than completely omitting the impermanent loss or making a profit from it. 
Empowering the ERC6909 and comprehensive pair manager, DEFT utilizes the most recent pool management tools as well as providing a great user experience.

**Deft shields liquidity providers (LPs) from the adverse effects of drastic price changes caused by arbitrageurs, enabling them to earn more than just static fees. This protective mechanism ensures that LPs can enjoy enhanced profitability and a more stable investment environment.**

## Smart Fee Calculation Mechanism
The core concept of Deft's algorithm is finding the new coordination of the pool for a possible swap request. After calculating the delta and finding the new coordinate, the system now autonomously
decides whether to alter the swap fee to protect the LPs reaching for an impermanent loss state. The delta intervals for fee calculations are defined as the impermanent loss plot. 
These intervals are demonstrated in the figure below:

<img src="https://github.com/DeftFinance/deft-dex-contracts/blob/main/assets/algo-fig.png" width="50%" height="40%"> 

Based on the plot we can define 3 zones:
1. Safe Zone (**$\large -0.25 < \delta < 0.33$**)
2. Alert Zone (**$\large -0.50 < \delta < -0.25 \ | \ \large 0.33 < \delta < 1.00$**)
3. Danger Zone (**$\large -1.00 < \delta < -0.50 \ | \ \delta > 1.00$**)

Based on the different characteristics of these regions, different fee calculations are considered. In the Safe Zone, the fee is the same as UniswapV2, which is 3 in Basis point of 1000.
In the Alert Zone, a linear regression method is used that gradually increases the fee from 3 to 20 based on the swap parameters. Finally, in the Danger Zone, an exponential scheme is adopted.
As the reserves and spot prices drastically change during a swap which pushes the state coordinates to such a region, the corresponding fee calculation differs from the two abovementioned regions.
Considering this fact, an exponential regression is used that changes the fee from 20 to 50 in the basis point.
The entire algorithm is also presented in this flowchart:

<img src="https://github.com/DeftFinance/deft-dex-contracts/blob/main/assets/flow.png" width="60%" height="60%"> 

## White-paper

***For more information, consider reading the whitepaper provided in this [link](https://github.com/DeftFinance/deft-dex-contracts/blob/main/assets/DeftDex-Whitepaper.pdf).***

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Foundry Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
