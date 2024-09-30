# <img src="https://github.com/DeftFinance/smart-contracts/blob/main/assets/DEFT-Logo.png"  width="28px" height="28px"> Deft Dex

Deft is a decentralized exchange (DEX) designed to address the significant issue of impermanent loss in uniform liquidity constant product automated market makers (AMMs), a prevalent concern for liquidity providers (LPs) in traditional DEXs. Deft introduces innovative features such as uniform liquidity and an advanced dynamic fee calculation mechanism to mitigate impermanent loss, creating a more secure and profitable environment for LPs. Additionally, Deft ensures a fair and efficient trading experience for liquidity takers (LTs), balancing the needs of all participants. By addressing these critical challenges and leveraging cutting-edge technology, Deft sets a new standard in the decentralized finance (DeFi) space, fostering greater confidence and participation among users.
The main aim here is to keep the Liquidity Takers (LTs) incentivized as well as protect the Liquidity Providers (LPs) from harsh price changes which will lead to impermanent loss. Considering the previous research and studies, the goal of this research is to reduce and optimize the impermanent loss which is a feature of Constant Product Market Makers (CPMM), rather than completely omitting the impermanent loss or making a profit from it. 

**Deft shields liquidity providers (LPs) from the adverse effects of drastic price changes caused by arbitrageurs, enabling them to earn more than just static fees. This protective mechanism ensures that LPs can enjoy enhanced profitability and a more stable investment environment.**

## Smart Fee Calculation Mechanism
The core concept of Deft's algorithm is finding the new coordination of the pool for a possible swap request. After calculating the delta and finding the new coordinate, the system now autonomously
decides whether to alter the swap fee to protect the LPs reaching for an impermanent loss state. The delta intervals for fee calculations are defined as the impermanent loss plot. 
These intervals are demonstrated in the figure below:

<img src="https://github.com/DeftFinance/smart-contracts/blob/main/assets/algo-fig.png" width="50%" height="40%"> 

Based on the plot we can define 3 zones:
1. Safe Zone (**$\large -0.25 < \delta < 0.33$**)
2. Alert Zone (**$\large -0.50 < \delta < -0.25 \ | \ \large 0.33 < \delta < 1.00$**)
3. Danger Zone (**$\large -1.00 < \delta < -0.50 \ | \ \delta > 1.00$**)

Based on the different characteristics of these regions, different fee calculations are considered. In the Safe Zone, the fee is the same as UniswapV2, which is 3 in Basis point of 1000.
In the Alert Zone, a linear regression method is used that gradually increases the fee from 3 to 20 based on the swap parameters. Finally, in the Danger Zone, an exponential scheme is adopted.
As the reserves and spot prices drastically change during a swap which pushes the state coordinates to such a region, the corresponding fee calculation differs from the two abovementioned regions.
Considering this fact, an exponential regression is used that changes the fee from 20 to 50 in the basis point.
The entire algorithm is also presented in this flowchart:

<img src="https://github.com/DeftFinance/smart-contracts/blob/main/assets/flow.png" width="60%" height="60%"> 

## ERC6909 Application

Deft DEX leverages the [**ERC6909** standard](https://eips.ethereum.org/EIPS/eip-6909), which is particularly well-suited for managing multiple tokens efficiently within a decentralized exchange (DEX environment). ERC6909 introduces a powerful framework that enables seamless interaction and handling of multiple token types under a single contract, simplifying the complexities typically associated with multi-token management.

Here’s how ERC6909 benefits Deft DEX:

1. **Unified Token Management**: ERC6909 allows Deft DEX to handle multiple tokens within one contract, reducing the overhead and operational complexity of managing multiple token standards separately.

2. **Efficient Transactions**: By consolidating token operations, ERC6909 streamlines the process of transferring, trading, and interacting with tokens. This leads to fewer contract calls, lower gas fees, and faster transaction times, which are critical for enhancing the user experience on Deft DEX.

3. **Improved Liquidity Management**: The standard's ability to natively support multiple token types allows Deft DEX to offer better liquidity management across diverse assets. Users can seamlessly swap between different token classes, increasing the flexibility of the platform and providing more trading options.

4. **Enhanced Interoperability**: With ERC6909, Deft DEX can interact with a wide range of token types and protocols, making it easier to integrate with other decentralized finance (DeFi) platforms. This interoperability enhances the ecosystem’s connectivity and broadens the scope of token interactions that Deft DEX can support.

5. **Simplified Smart Contract Architecture**: ERC6909 reduces the need for deploying multiple token contracts, simplifying the overall architecture of the Deft DEX platform. This not only minimizes the risk of smart contract bugs but also ensures easier auditing and maintenance of the platform.

By adopting ERC6909, Deft DEX sets itself apart as an advanced platform capable of handling the complex needs of modern decentralized exchanges while ensuring efficiency, scalability, and security in managing multiple token types.

## White-paper

***For more information, consider reading the whitepaper provided in this [link](https://github.com/DeftFinance/smart-contracts/blob/main/assets/DeftDex-Whitepaper.pdf).***

### Deployed SmartContract Address: ```0x6085f5473Ae09Df8680bB3Ab2E9Fe4E259028aAa```
