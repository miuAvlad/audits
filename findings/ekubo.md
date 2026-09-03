### [H-1] LP's can bypass protocol fee accrual 


**Description:** Due to `Positions` contract implementing the protocol fee accrual logic and the storage slot of a position being dependent on the locker address not on the `Positions` contract address, any LP can bypass the protocol fee accrual by implementing their own smart contract with the main functionalities needed to withdraw their liquidity.

- Core contract maps positions to the locker address (slot is calculated using the locker address), in a normal flow all the positions are mapped to the `Positions` contract. 
- A user can store it's position inside the core contract mapped to it's own smart contract address (the locker) using a valid nft minted by the `Positions` contract.
- On withdraw/fee collecting the user bypasses the protocol fee accrual which is implemented inside `Positions` by calling his own smart contract which does not implement fee accrual for the protocol.

The smart contract needed to bypass the fees needs to have the same logic from Positions with only the protocol fees part missing.
```javascript
    ...
    // collect first in case we are withdrawing the entire amount
            if (withFees) {
                (amount0, amount1) = CORE.collectFees(
                    poolKey,
                    createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper})
                );

                // Collect swap protocol fees
                (uint128 swapProtocolFee0, uint128 swapProtocolFee1) =
@>                    _computeSwapProtocolFees(poolKey, amount0, amount1); 
 
                if (swapProtocolFee0 != 0 || swapProtocolFee1 != 0) {
                    CORE.updateSavedBalances(
                        poolKey.token0, poolKey.token1, bytes32(0), int128(swapProtocolFee0), int128(swapProtocolFee1)
                    );

                    amount0 -= swapProtocolFee0;
                    amount1 -= swapProtocolFee1;
                }
            }
    ...
```

The position slot calculated using the locker address.
```javascript
 function updatePosition(PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
        payable
        returns (PoolBalanceUpdate balanceUpdate)
    {
        ...

        if (liquidityDelta != 0) {
            (SqrtRatio sqrtRatioLower, SqrtRatio sqrtRatioUpper) =
                (tickToSqrtRatio(positionId.tickLower()), tickToSqrtRatio(positionId.tickUpper()));

            (int128 delta0, int128 delta1) =
                liquidityDeltaToAmountDelta(state.sqrtRatio(), liquidityDelta, sqrtRatioLower, sqrtRatioUpper);

            StorageSlot positionSlot = CoreStorageLayout.poolPositionsSlot(poolId, locker.addr(), positionId); 
            Position storage position;
            assembly ("memory-safe") {
                position.slot := positionSlot
            }

            uint128 liquidityNext = addLiquidityDelta(position.liquidity, liquidityDelta); 

        ...
```

**Impact:** 

- Users take the rewards without paying the protocol. (likelihood high)
- Protocol loses it's main source of income, the swap fee. (impact high)


**Proof of Concept:** Inside `FullTest.t.sol` modify the setup by adding fees to the positions contract creation.
```javascript 
function setUp() public virtual {
        core = new Core();
@>        positions = new Positions(core, owner, 100000000000, 10000000000);
        router = new Router(core);
        TestToken tokenA = new TestToken(address(this));
        TestToken tokenB = new TestToken(address(this));
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }
```
The test file includes 2 tests and the smart contract:
- `Attacker` smart contract which implements the logic needed
- `test_fee_bypass` used to showcase the fee bypass accrual
- `test_good` used to compare the balances of a user in the same conditions by calling collectFees using the `Positions` contract

The output for the 2 testcases:

- case 1 normal usage
```
user balance before fees: 990000000000000000349
user balance after fees:  990000271050541652357
```

- case 2 fee bypass
```
user balance before fees: 990000000000000000349
user balance after fees:  990000271050543121725
```
99000027105054|1652357
99000027105054|3121725


**Recommended Mitigation:** 

- Moving the protocol fee accrual logic inside core contract.

