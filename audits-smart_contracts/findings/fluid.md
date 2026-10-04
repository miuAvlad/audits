### [M-1] Fragmenting collateral in d3 positions can make liquidation transaction gas cost be higher than the 5% penalty, decentivising liquidators and making the protocol prone to bad debt. 


**Description:** 
Chain targeted is Etherum mainnet.
Liquidation operation iterates through positions 2 times:
- first ensuring the liquidation threshold is met
- second ensuring the position was not overliquidated by checking if the `hf.limit` is reached.

The protocol, on liquidation operation, does not implement a batch for withdrawal position making liquidations per withdrawal position. This allows an attacker to split supply positions into multiple smaller positions forcing liquidators to liquidate smaller positions that are not profitable due to gas cost exceeding the 5% penalty given on liquidation.

Why is economically viable:
- The setup for the attack is economically viable due to supply positions not being forced to enter through HF check.
- Also an attacker can craft multiple nft's with small amounts of borrow.
- the setup can be made when gas cost is low
- Attacker can make it more gas eficient by chosing normal supply instead of d3 but the hf calculations for the liquidator would be less expensive (but still efficient)
- Attacker can create his own d3 pool (with small liquidity) with moneymarket listed tokens setting the maximum lp fee, 6.5% preventing swaps and fee accrual that could improve his health factor
- Attacker is looking to externalize bad debt 

As stated, the protocol is aware of the OOG scenario and is willing to reconsider the severity for a higher but reasonable number of positions 50/100.
The actual vulnerability in a scenario of 50/100 positions is not the OOG but is the "economic DOS" scenario in which liquidations are much more expensive than the penalty making any liquidation unprofitable and the nft prone to entering bad debt.

On a 50-100 positions available the attack becomes highly efficient due to :
- amounts that can be supplyed and borow growing significantly due to better fragmentaion
- gas cost needed for the liquidations to not be profitable lowering drastically to calm days gas cost ( not stres scenario with price movements anymore)
- fragmentation also makes the maximum amount liquidatable per operation much smaller leading to a much smaller penalty bonus aquiered by the liquidator.

In the testcase, a realist scenario with 10 positions is presented that still presents the same vulnerability. The important metrics of the testaces are:
- realistic gas cost for stress periods in which prices drop and liquidations are the most important mechanism for the protocol (smaller than 3.6 gwei)
- number of positions allowed in the nft
- realistic price movement
- supply collateral and borrow amounts
- gas cost for calm period used for the attack setup to 1 gwei 

The attack is relevant even for lower gas costs, the only downside for the attacker is that the amount borrowed must be smaller but the attack can be easily scaled by using multiple nfts due to setup cost being smaller too. As seen in the tests the cost of the setup is smaller than 1% of the borrow.

Considering 10 positions per nft with gas cost at 1 gwei(for the setup) creating 20 nfts with 1800 USDC borrows translates into 36_000 USDC borrow with a 180 USDC setup.

Mutliple scenarios can be tested with the POC but in this report I will focus on 3 possible scenarios. Indications of how to modify the test for all the scenarios (10, 20, 50 positons) will be present.
The ideal split is 1 positon of borrow and the rest positions d3 supply.

First scenario has 10 positions with a price movement from 4200 to 3900 (~7% price movement):

- the price movement is calculated using binary search to force the position into liquidation but not bad debt
- gas cost is set to 3.6 gwei, realistic for non-peak conditions; during stress market scenarios where transactions are highly competitive and gas prices rise significantly
- amount being supplyed is 0.5 eth + 0.0025*8 eth + 10*8 USDC getting the collateral value in usdc around 2100-2200 USDC; the collateral can be better split between the positions but I chose to stack most of it inside the normal supply due to easier transitions between scnarios; ideal split was 0.5*4200/9 collateral per position -> around 233 usd collateral per position.
- amount borrowed 1800 usdc
- on liquidation the liquidator is able to liquidate around 200 usd , the reason is that the collateral inside 1 position is arround 200 usdc after the price movement, the 0.5 eth in the first position is only for easier testing
- usd price used for setup is 9 USDC with a gas cost of 1 wei on setup;

output: 
```
  setupGasUsed: 2172126
  -> setupCostUsdc6: 9122929
  -> setupCostUsdc: 9
  ethPrice change: 3919816180276723067659
  positions: 10
  gasUsed (outer): 720471
  gasPrice: 3600000000
  -> gasCostEth: 2593695600000000
  paybackUsdc: 199999994
  withdrawEth: 53573939195581067
  -> bonusEth:   2551139961694336
```

Higher gas cost will lead to bigger diferences between the bonus and the amount consumated; around 5 gwei the amount that can be borrowed grows closer to 5k usdc or the gas price almost doubles.

Second scenario has 20 positions with price movement from 4200 to 3900 (~7% price movement):

- gas cost is set to 2.1 gwei 
- amount supplied stays the same
- amount borrow 1950 USDC
- the split between positions becomes smaller, 0.5*4200/19 -> 110 USDC collateral per positon
- the maximum amount allowed to be liquidated goes to 100 USDC lowering the penalty bonus significantly
- usd price used for setup is 20 USDC with a gas cost of 1 wei on setup;

output: 
```
  -> setupGasUsed: 4802075
  -> setupCostUsdc6: 20168715
  -> setupCostUsdc: 20
  ethPrice change: 3884775156856827921382
  positions: 20
  gasUsed (outer): 1382756
  gasPrice: 2100000000
  -> gasCostEth: 2903787600000000
  paybackUsdc: 99999994
  withdrawEth: 27028589676462898
  -> bonusEth:   1287075698879185
```
Gas cost is double the liquidation bonus making liquidations not only unprofitable but highly costly. Due to this huge differences the amount being supplyed and borrow can grow significantly in the range of 5-10k with the same 2.1 gwei gas cost

Third scenario has 50 positions with price movement from 4200 to 3900 (~7% price movement):

- gas cost is set to 1.1 gwei 
- amount supplied 2 eth + 48*0.0025 eth +48*10 USDC getting the total collateral to 9365 USDC
- amount borrow 7400 USDC
- the split between positions becomes 9365/49 -> 190 USDC collateral per positon
- the maximum amount allowed to be liquidated goes to 190 USDC lowering the penalty bonus significantly
- usd price used for setup is 50 USDC with a gas cost of 1 wei on setup;

output: 
```
  -> setupGasUsed: 12694287
  -> setupCostUsdc6: 53316005
  -> setupCostUsdc: 53
  ethPrice change: 3884052470108429307548
  positions: 50
  gasUsed (outer): 3497826
  gasPrice: 1100000000
  -> gasCostEth: 3847608600000000
  paybackUsdc: 189999990
  withdrawEth: 51363876012321390
  -> bonusEth:   2445898857729589
```

**Impact:**


The vulnerability proves that in market stress where prices drop and positions become liquidatable, when transaction activity is high, the procotocols mechanism of liquidation will fail to be profitable, it can even become costly for liquidators, decentivising liquidations and leading to bad debt accrual.

The scenarios depicted are highly realistic and best case scenario for the liquidator using 7% price movements, (3.6; 2.1; 1.1) gwei as gas cost in stress market conditions (actual gas cost can grow much bigger than 3.6 gwei in stress conditions; 3.6 gwei can be considered moderate stress from real data) and positions limit from 10 to 50.

In a scenario where prices drop even more, 7-20%, like 2024(1 day 20%), 2021(1 day 30-40%) with high volatility and activity grows due to liquidations and money movement on the chain the protocol will fail to liquidate positions entering bad debt.



**Proof of Concept:**

What to modify :
```
line 10 : uint256 internal constant ECON_GAS_PRICE = 1.1 gwei; // change gas cost
line 38 : _testLiquidateUnprofitableDueToGasVsPenalty_D3Many_D4Debt(50); // change number of positons
line 288-359: 
        uint256 collateralEth = 2 ether; // collateral supplyed in the first position
        uint256 d4DebtAmount0 = 7400 * 1e6; // the amount borrowed

        paybackAmount0 = 190 * 1e6; // the maximum amount the liquidator is able to liquidate from 1 position

 
```

**Recommended Mitigation:** On liquidation implement a batch for withdrawal positions making the fragmentation of collateral not cost extensive due to only 2 HF calculation.
