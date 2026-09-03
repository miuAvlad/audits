// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FaithfulAnchorOracle, FaithfulAnchoredPriceProvider} from "./mocks/FaithfulAnchor.sol";
import {EchidnaInspectableMetricOmmPool} from "./MetricOmmPool.echidna.t.sol";
import {MetricOmmEchidnaActor} from "./MetricOmmPoolMultiActor.echidna.t.sol";

contract MetricOmmPoolOracleBoundaryEchidna {
  uint256 internal constant TOKEN0_SCALE = 1e12;
  uint256 internal constant TOKEN1_SCALE = 1;
  uint256 internal constant MINIMAL_MINTABLE_LIQUIDITY = 1_000;
  uint256 internal constant MAX_TOKEN0_SWAP_AMOUNT = 1e9;
  uint256 internal constant MAX_TOKEN1_SWAP_AMOUNT = 1e21;
  uint24 internal constant DEFAULT_SPREAD_FEE_E6 = 10_000;
  uint256 internal constant ORACLE_MID_8 = 1e8;
  uint256 internal constant MAX_REF_STALENESS = 60;
  uint16 internal constant MAX_SPREAD_BPS = 500;
  bytes32 internal constant BASE_FEED_ID = bytes32(uint256(1));

  MockERC20 public immutable token0;
  MockERC20 public immutable token1;
  FaithfulAnchorOracle public immutable oracle;
  FaithfulAnchoredPriceProvider public immutable priceProvider;
  EchidnaInspectableMetricOmmPool public immutable pool;
  MetricOmmEchidnaActor public immutable trader;

  bool public lastFeedExpectedUsable;
  bool public badOracleSwapSucceeded;
  uint256 public freshSwapSuccesses;
  uint256 public blockedBadOracleSwaps;

  constructor() {
    token0 = new MockERC20("Echidna USDC", "eUSDC", 6);
    token1 = new MockERC20("Echidna WETH", "eWETH", 18);
    oracle = new FaithfulAnchorOracle();
    priceProvider = new FaithfulAnchoredPriceProvider(
      address(oracle),
      BASE_FEED_ID,
      bytes32(0),
      1e14,
      MAX_REF_STALENESS,
      MAX_SPREAD_BPS,
      address(token0),
      address(token1)
    );

    BinState[] memory nonNegativeBinStates = new BinState[](2);
    BinState[] memory negativeBinStates = new BinState[](2);
    for (uint256 i; i < 2; i++) {
      nonNegativeBinStates[i] =
        BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 1_000, addFeeBuyE6: 0, addFeeSellE6: 0});
      negativeBinStates[i] =
        BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 1_000, addFeeBuyE6: 0, addFeeSellE6: 0});
    }

    PoolExtensions memory extensions;
    ExtensionOrders memory extensionOrders;
    pool = new EchidnaInspectableMetricOmmPool(
      address(this),
      address(this),
      address(this),
      address(token0),
      address(token1),
      address(priceProvider),
      extensions,
      extensionOrders,
      TOKEN0_SCALE,
      TOKEN1_SCALE,
      1e18,
      1e18,
      MINIMAL_MINTABLE_LIQUIDITY,
      DEFAULT_SPREAD_FEE_E6,
      0,
      nonNegativeBinStates,
      negativeBinStates,
      0
    );

    trader = new MetricOmmEchidnaActor();
    token0.mint(address(trader), 1_000_000_000_000);
    token1.mint(address(trader), 1_000_000 ether);
    trader.addLiquidity(address(pool), 0, _rangeLiquidityDelta(-1, 1, 100_000));

    _setFeed(ORACLE_MID_8, 1, block.timestamp == 0 ? 1 : block.timestamp, block.timestamp != 0);
  }

  function setFreshFeed(uint96 midSeed, uint16 spreadSeed) external {
    uint256 refTime = block.timestamp == 0 ? 1 : block.timestamp;
    bool usable = block.timestamp != 0;
    _setFeed(_midFromSeed(midSeed), uint256(spreadSeed) % (MAX_SPREAD_BPS + 1), refTime, usable);
  }

  function setStaleFeed(uint96 midSeed, uint16 spreadSeed, uint32 ageSeed) external {
    uint256 age = MAX_REF_STALENESS + 1 + uint256(ageSeed) % 1 days;
    uint256 refTime = block.timestamp > age ? block.timestamp - age : 0;
    _setFeed(_midFromSeed(midSeed), uint256(spreadSeed) % (MAX_SPREAD_BPS + 1), refTime, false);
  }

  function setFutureFeed(uint96 midSeed, uint16 spreadSeed, uint32 futureSeed) external {
    uint256 refTime = block.timestamp + 1 + uint256(futureSeed) % 1 days;
    _setFeed(_midFromSeed(midSeed), uint256(spreadSeed) % (MAX_SPREAD_BPS + 1), refTime, false);
  }

  function setZeroMidFeed(uint16 spreadSeed) external {
    _setFeed(0, uint256(spreadSeed) % (MAX_SPREAD_BPS + 1), block.timestamp == 0 ? 1 : block.timestamp, false);
  }

  function setWideSpreadFeed(uint96 midSeed, uint16 spreadSeed) external {
    uint256 spread = uint256(MAX_SPREAD_BPS) + 1 + uint256(spreadSeed) % (10_000 - MAX_SPREAD_BPS);
    _setFeed(_midFromSeed(midSeed), spread, block.timestamp == 0 ? 1 : block.timestamp, false);
  }

  function swapAgainstCurrentOracle(uint8 directionSeed, uint96 amountSeed) external {
    bool zeroForOne = directionSeed % 2 == 0;
    uint256 maxAmount = zeroForOne ? MAX_TOKEN0_SWAP_AMOUNT : MAX_TOKEN1_SWAP_AMOUNT;
    try trader.swap(
      address(pool),
      address(trader),
      zeroForOne,
      int128(uint128(1 + uint256(amountSeed) % maxAmount)),
      zeroForOne ? uint128(0) : type(uint128).max
    ) returns (int128, int128) {
      if (lastFeedExpectedUsable) {
        freshSwapSuccesses++;
      } else {
        badOracleSwapSucceeded = true;
      }
    } catch {
      if (!lastFeedExpectedUsable) blockedBadOracleSwaps++;
    }
  }

  function echidna_bad_oracle_state_never_allows_swap() external view returns (bool) {
    return !badOracleSwapSucceeded;
  }

  function echidna_pool_solvency_under_oracle_failures() external view returns (bool) {
    (uint128 total0Scaled, uint128 total1Scaled) = pool.exposedBinTotals();
    (uint128 notional0Scaled, uint128 notional1Scaled) = pool.exposedNotionalFees();
    return token0.balanceOf(address(pool)) * TOKEN0_SCALE >= uint256(total0Scaled) + uint256(notional0Scaled)
      && token1.balanceOf(address(pool)) * TOKEN1_SCALE >= uint256(total1Scaled) + uint256(notional1Scaled);
  }

  function _setFeed(uint256 mid8, uint256 spreadBps, uint256 refTime, bool usable) internal {
    oracle.setFeed(BASE_FEED_ID, mid8, spreadBps, 0, refTime);
    lastFeedExpectedUsable = usable && mid8 > 0 && spreadBps <= MAX_SPREAD_BPS && refTime != 0 && refTime <= block.timestamp
      && block.timestamp - refTime <= MAX_REF_STALENESS;
  }

  function _midFromSeed(uint96 midSeed) internal pure returns (uint256) {
    return ORACLE_MID_8 + uint256(midSeed) % ORACLE_MID_8;
  }

  function _rangeLiquidityDelta(int8 low, int8 high, uint256 shares) internal pure returns (LiquidityDelta memory delta) {
    uint256 count = uint256(int256(high) - int256(low) + 1);
    delta.binIdxs = new int256[](count);
    delta.shares = new uint256[](count);
    for (uint256 i; i < count; i++) {
      delta.binIdxs[i] = int256(low) + int256(i);
      delta.shares[i] = shares;
    }
  }
}
