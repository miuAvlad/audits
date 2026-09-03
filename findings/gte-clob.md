

### [H-2] `Book::_updateLimitPostOrder`  only updates `order.prevOrderId` in memory, breaking the doubly linked list

**Description:** Inside `Book::_updateLimitPostOrder` order is stored in memory not in storage leading to the value of the previous order id beeing 0 in the actual storage

```javascript
 function _updateLimitPostOrder(Book storage self, Limit storage limit, Order @> memory order) private {
        limit.numOrders++;

        if (limit.headOrder.isNull()) {
            limit.headOrder = order.id;
            limit.tailOrder = order.id;
        } else {
            Order storage tailOrder = self.orders[limit.tailOrder];
            tailOrder.nextOrderId = order.id;
@>           order.prevOrderId = tailOrder.id;
            limit.tailOrder = order.id;
        }

        emit LimitOrderCreated(BookEventNonce.inc(), order.id, order.price, order.amount, order.side);
    } 
```

**Impact:** Because the previous order Id will always be 0 in case of multiple orders with the same price, canceling an order that is not at the begining of the linked list will lead to all the orders that are set before it to be ignored. In the case the last order in the list(the newest) is canceled all the previous orders with the same price will be completly ignored because the removal of the order will set the header to 0. This leads to a simple DOS attack.
```javascript
 function _updateLimitRemoveOrder(Book storage self, Order storage order) private {
        uint256 price = order.price;

        Limit storage limit = order.side == Side.BUY ? self.bidLimits[price] : self.askLimits[price];

        if (limit.numOrders == 1) {
            if (order.side == Side.BUY) {
                delete self.bidLimits[price];
                self.bidTree.remove(price); 
            } else {
                delete self.askLimits[price];
                self.askTree.remove(price);
            }
            return;
        }

        limit.numOrders--;

        OrderId prev = order.prevOrderId;
        OrderId next = order.nextOrderId;

@>        if (!prev.isNull()) self.orders[prev].nextOrderId = next;
        else limit.headOrder = next;

@>        if (!next.isNull()) self.orders[next].prevOrderId = prev;
        else limit.tailOrder = prev;
    }
```

**Proof of Concept:**
    By modyfing the number of the order it is easy to see the actual orders that are beeing ignored, also you can comment the cancel operation to see the normal flux of filling an order  and how the balances of the accounts modify corectly.
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoCTestBase} from "./PoCTestBase.t.sol";
import {ICLOB} from "contracts/clob/ICLOB.sol";
import "contracts/clob/types/Order.sol";
import {console} from "forge-std/console.sol";
import {GTERouter} from "contracts/router/GTERouter.sol";
import "forge-std/Test.sol";
import {WETH} from "solady/tokens/WETH.sol";

import {CLOBTestBase} from "test/clob/utils/CLOBTestBase.sol";
import {ERC20Harness} from "test/harnesses/ERC20Harness.sol";
import {MockUniV2Router} from "test/mocks/MockUniV2Router.sol";
import {MockLaunchpad} from "test/mocks/MockLaunchpad.sol";

import {ICLOBManager, SettingsParams} from "contracts/clob/ICLOBManager.sol";
import {IAllowanceTransfer} from "@permit2/interfaces/IAllowanceTransfer.sol";

import {DeployPermit2} from "../../lib/permit2/test/utils/DeployPermit2.sol";


contract PoC is PoCTestBase {
    function test_submissionValidity() external {

        // ask 1 ETH @ 1000 USDC
        ICLOB.PostLimitOrderArgs memory args1 = ICLOB.PostLimitOrderArgs({
            amountInBase: 1e18,
            price:1000 * 1e18,
            cancelTimestamp: uint32(block.timestamp + 20 days),
            side: Side.SELL,
            clientOrderId : 0,
            limitOrderType: ICLOB.LimitOrderType.POST_ONLY
            });
        // bid 7 ETH @ 1000 USDC
        ICLOB.PostLimitOrderArgs memory args2 = ICLOB.PostLimitOrderArgs({
            amountInBase: 7e18,
            price:1000 * 1e18,
            cancelTimestamp: uint32(block.timestamp + 20 days),
            side: Side.BUY,
            clientOrderId : 0,
            limitOrderType: ICLOB.LimitOrderType.GOOD_TILL_CANCELLED
            });

        // Deal users tokens
        deal(address(tokenA),julien,1000000 ether);
        deal(address(weth),julien,1000000 ether);

        deal(address(tokenA),rite,1000000 ether);
        deal(address(weth),rite,1000000 ether);

        console.log("number of decimals for token A: ",tokenA.decimals());

        // Approve and deposit tokens on behalf of julien and rite
        vm.startPrank(julien);
        
        tokenA.approve(address(accountManager),type(uint256).max);
        weth.approve(address(accountManager),type(uint256).max);
        accountManager.deposit(julien,address(tokenA),100000 ether);
        accountManager.deposit(julien,address(weth),100000 ether);

        console.log("julien tokenA deposited in accountManager: ",accountManager.getAccountBalance(julien,address(tokenA)));
        console.log("julien weth deposited in accountManager: ",accountManager.getAccountBalance(julien,address(weth)));

        accountManager.getAccountBalance(julien,address(tokenA));

        vm.stopPrank();


        vm.startPrank(rite);
        
        tokenA.approve(address(accountManager),type(uint256).max);
        weth.approve(address(accountManager),type(uint256).max);
        accountManager.deposit(rite,address(tokenA),100000 ether);
        accountManager.deposit(rite,address(weth),100000 ether);

        console.log("rite tokenA deposited in accountManager: ",accountManager.getAccountBalance(rite,address(tokenA)));
        console.log("rite weth deposited in accountManager: ",accountManager.getAccountBalance(rite,address(weth)));

        accountManager.getAccountBalance(rite,address(tokenA));

        vm.stopPrank();

        // Post orders with same price
        vm.startPrank(julien);
        ICLOB(wethCLOB).postLimitOrder(julien,args1); // orderId = 1
        ICLOB(wethCLOB).postLimitOrder(julien,args1); // orderId = 2
        ICLOB(wethCLOB).postLimitOrder(julien,args1); // orderId = 3
        ICLOB(wethCLOB).postLimitOrder(julien,args1); // orderId = 4
        ICLOB(wethCLOB).postLimitOrder(julien,args1); // orderId = 5
        vm.stopPrank();


        // Get OrderId
        Order memory order1 = ICLOB(wethCLOB).getOrder(1);

        console.log( "order.prevOrderId for first order = ", order1.prevOrderId.unwrap());
        console.log( "order.nextOrderId for first order = ", order1.nextOrderId.unwrap());
        console.log( "order.price for first order = ", order1.price);



        Order memory order3 = ICLOB(wethCLOB).getOrder(3);

        console.log( "order.prevOrderId for second order = ", order3.prevOrderId.unwrap());
        console.log( "order.nextOrderId for second order = ", order3.nextOrderId.unwrap());
        console.log( "order.price for third order = ", order3.price);


        Order memory order5 = ICLOB(wethCLOB).getOrder(5);

        console.log( "order.prevOrderId for third order = ", order5.prevOrderId.unwrap());
        console.log( "order.nextOrderId for third order = ", order5.nextOrderId.unwrap());
        console.log( "order.price for fifth order = ", order5.price);

        
        assert(order5.prevOrderId.unwrap() == 0);
        assert(order3.prevOrderId.unwrap() == 0);
        assert(order3.price == order5.price);
        
        
        uint256[] memory canceled = new uint256[](1);
        canceled[0] = 5; // Can be modified to visualize the header beeing moved

        ICLOB.CancelArgs memory args3 = ICLOB.CancelArgs({orderIds:canceled});

        
        // This cancel part can be commented to see the balances beeing modified normally
        vm.startPrank(julien);
        ICLOB(wethCLOB).cancel(julien,args3); // orderId = 5
        vm.stopPrank();

        Order memory order6 = ICLOB(wethCLOB).getOrder(5);
        // make sure to delete the order
        console.log( "order.prevOrderId for third order = ", order6.prevOrderId.unwrap());
        console.log( "order.nextOrderId for third order = ", order6.nextOrderId.unwrap());
        console.log( "order.price for fifth order = ", order6.price);
      
        vm.startPrank(rite);
        ICLOB(wethCLOB).postLimitOrder(rite,args2);
        vm.stopPrank();

        console.log("rite tokenA deposited in accountManager: ",accountManager.getAccountBalance(rite,address(tokenA)));
        console.log("rite weth deposited in accountManager: ",accountManager.getAccountBalance(rite,address(weth)));

        console.log("julien tokenA deposited in accountManager: ",accountManager.getAccountBalance(julien,address(tokenA)));
        console.log("julien weth deposited in accountManager: ",accountManager.getAccountBalance(julien,address(weth)));

    }
}

// Examples you will see in the console by modifying the position in the list of the canceled order  (here are first and last)

//   rite tokenA deposited in accountManager:     95000.000000000000000000
//   rite weth deposited in accountManager:      100000000000000000000000
//   julien tokenA deposited in accountManager:  100000000000000000000000
//   julien weth deposited in accountManager:     99996.000000000000000000

//   rite tokenA deposited in accountManager:     95000.000000000000000000
//   rite weth deposited in accountManager:      100004997500000000000000
//   julien tokenA deposited in accountManager:  104998500000000000000000
//   julien weth deposited in accountManager:     99995.000000000000000000

```



**Recommended Mitigation:**

Modify the value in the storage not in memory.

```diff
function _updateLimitPostOrder(Book storage self, Limit storage limit, Order memory order) private {
        limit.numOrders++;

        if (limit.headOrder.isNull()) {
            limit.headOrder = order.id;
            limit.tailOrder = order.id;
        } else {
            Order storage tailOrder = self.orders[limit.tailOrder];
            tailOrder.nextOrderId = order.id;
-           order.prevOrderId = tailOrder.id;
+           self.orders[order.id].prevOrderId = tailOrder.id;
            limit.tailOrder = order.id;
        }

        emit LimitOrderCreated(BookEventNonce.inc(), order.id, order.price, order.amount, order.side);
    } 
```







