## Summary

Contract CurveConvex2Token inherits in order:

1. AbstractSingleSidedLP
2. RewardManagerMixin
3. AbstractYieldStrategy
4. Initializable

The Initializable base contract's constructor sets the initialized private variable to true which permanently disables the public function initialize(bytes). As consequence the _initialApproveTokens() is never called to set all the ERC-20 allowances that joinPoolAndStake() needs. Because _initialize is never invoked, no approvals are ever granted effectively blocking the core deposit/stake flow.
```javascript
  function _initialize(bytes calldata data) internal override {
        super._initialize(data);
        _initialApproveTokens();
    }
```

Not only that, because of the Initializable contract beeing inherited by AbstractYieldStrategy it means this contract too can't call the initialize function

 ```javascript  
function _initialize(bytes calldata data) internal override virtual {
        (string memory _name, string memory _symbol) = abi.decode(data, (string, string));
        s_name = _name;
        s_symbol = _symbol;

        s_lastFeeAccrualTime = uint32(block.timestamp);
        emit VaultCreated(address(this));
    }
 ``` 

meaning that `s_lastFeeAccrualTime` storage variable will never be initialized leading to miss calculation of fees in

 ```javascript
function _calculateAdditionalFeesInYieldToken() private view returns (uint256 additionalFeesInYieldToken) {
        uint256 timeSinceLastFeeAccrual = block.timestamp - s_lastFeeAccrualTime;
        // e ^ (feeRate * timeSinceLastFeeAccrual / YEAR)
        uint256 x = (feeRate * timeSinceLastFeeAccrual) / YEAR; // @note: x = feeRate*1e18
        if (x == 0) return 0;

        uint256 preFeeUserHeldYieldTokens = _yieldTokenBalance() - s_accruedFeesInYieldToken;  
        // Taylor approximation of e ^ x = 1 + x + x^2 / 2! + x^3 / 3! + ...
        uint256 eToTheX = DEFAULT_PRECISION + x + (x * x) / (2 * DEFAULT_PRECISION) + (x * x * x) / (6 * DEFAULT_PRECISION * DEFAULT_PRECISION);
        // Decay the user's yield tokens by e ^ (feeRate * timeSinceLastFeeAccrual / YEAR)
        uint256 postFeeUserHeldYieldTokens = preFeeUserHeldYieldTokens * DEFAULT_PRECISION / eToTheX;

        additionalFeesInYieldToken = preFeeUserHeldYieldTokens - postFeeUserHeldYieldTokens;
    }
 ```
 
Due to the fact that s_lastFeeAccrualTime is not initialized with `block.timestamp` at the creation of the contract its value will be 0. Calling the function will lead to misscalculation of additionalFeesInYieldToken leading to loss of funds.

### Root Cause
2025-06-notional-exponent-miuAvlad/notional-v4/src/proxy/Initializable.sol

Line 10 in 82c8710
```javascript 
 initialized = true; 
 bool private initialized;

    constructor() {
@>        initialized = true;
    }

    function initialize(bytes calldata data) external {
        if (initialized) revert InvalidInitialization();
        initialized = true;
        _initialize(data);
    }
```
Initializable contract sets the initialized variabile to true in the constructor making impossible to call the initialize function

Internal Pre-conditions
External Pre-conditions
Attack Path
Admin deploys the contract CurveConvex2Token
Initial tokens can not be approved because the approval happens inside the initialize function which can not be called due to initialized variable beeing set to true in the constructor.
Impact
No deposits or stakes can ever succeed, rendering the strategy unusable.
All calls to joinPoolAndStake (the primary deposit entry point) revert immediately.
Funds cannot be deployed; integrations relying on this strategy will silently fail.

### PoC

```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/src/Test.sol";
import "../src/rewards/ConvexRewardManager.sol";
import "../src/interfaces/IRewardManager.sol";
import "../src/single-sided-lp/CurveConvex2Token.sol";
import "../src/single-sided-lp/AbstractSingleSidedLP.sol";
import "../src/interfaces/Curve/ICurve.sol";
import "../src/oracles/Curve2TokenOracle.sol";
import "./TestWithdrawRequest.sol";
import "../src/interfaces/ITradingModule.sol";

contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol)
        ERC20(name, symbol)
    {}


    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }


    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract FakeCurvePool {
    ERC20Mock public token1;
    ERC20Mock public token2;

    constructor(address _t1, address _t2) {
        token1 = ERC20Mock(_t1);
        token2 = ERC20Mock(_t2);
    }

    function coins(uint256 idx) external view returns (address) {
        if (idx == 0) return address(token1);
        if (idx == 1) return address(token2);
        revert("Bad index");
    }


    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 /* minMint */
    ) external returns (uint256) {
        return amounts[0] + amounts[1];
    }
}

contract CurveConvex2Token_PoC is Test {
    CurveInterface curveInterface;
    address owner        = address(1);
    ERC20Mock   asset;
    ERC20Mock   lpToken;
    address curveGauge   = address(0xBEEF);
    address rewardPool   = address(0xCAFE);
    ConvexRewardManager rmImpl;
    IWithdrawRequestManager[] manager ;
    FakeCurvePool pool;

    CurveConvex2Token y;

    function setUp() public {
        vm.deal(owner, 1 ether);

        IWithdrawRequestManager manager = IWithdrawRequestManager(address(2));


        asset   = new ERC20Mock("USDC","USDC");
        lpToken = new ERC20Mock("LP","LP");
        asset.mint(owner, 1_000_000e6);
        lpToken.mint(owner, 1_000_000e18);
        rmImpl = new ConvexRewardManager();
        pool = new FakeCurvePool(address(asset), address(asset));
        vm.startPrank(owner);
          y = new CurveConvex2Token(
            /* maxPoolShare */ 100e18,
            address(asset),
            address(asset),   
            0.0010e18,
            address(rmImpl),
            DeploymentParams({
              pool:            address(pool),
              poolToken:       address(lpToken),
              gauge:           curveGauge,
              convexRewardPool: rewardPool,
              curveInterface:  curveInterface
            }),
            manager
          );
        vm.stopPrank();
    }

 function testJoinPoolRevertsForMissingApprove() public {

    asset.mint(address(y), 10_000e6);


    uint256[] memory amounts = new uint256[](2);

    amounts[0] = 10_000e6;
    amounts[1] = 0;

    uint256 minPoolClaim = 0;

    vm.prank(owner);
    vm.expectRevert();
    y.initialize("");

}
}
```
Mitigation
Move approvals into the constructor of CurveConvex2Token so that _initialApproveTokens() runs on every direct deploy, eliminating the need for initialize(...)



### PS
    This finding was deemd Valid but informational in Sherlock Contest even though it casues permanent DOS and loss of funds ()
