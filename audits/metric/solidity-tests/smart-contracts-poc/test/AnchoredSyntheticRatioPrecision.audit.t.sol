// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {AnchoredProviderFactory} from "../contracts/AnchoredProviderFactory.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";
import {TestOracle} from "./ProtectedPriceProvider.t.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";

/// @notice Demonstrates precision loss in production AnchoredPriceProvider synthetic ratios.
contract AnchoredSyntheticRatioPrecisionAuditTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant ORACLE_DECIMALS = 1e8;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    bytes32 private constant CHEAP_USD_FEED = keccak256("CHEAP-USD");
    bytes32 private constant EXPENSIVE_USD_FEED = keccak256("EXPENSIVE-USD");
    bytes32 private constant MAJORS = keccak256("MAJORS");

    // Correct, fresh USD observations: $1 USDC and $100,000.01 cbBTC.
    uint64 private constant CHEAP_USD_8 = 1e8;
    uint64 private constant EXPENSIVE_USD_8 = 100_000 * 1e8 + 1e6;

    // Ordinary majors-style configuration used by the repository tests.
    uint256 private constant MIN_MARGIN = 5e13; // 0.5 bps per side
    uint16 private constant MAX_SPREAD_BPS = 150;
    uint256 private constant MAX_REF_STALENESS = 60;

    TestOracle private oracle;
    AnchoredProviderFactory private providerFactory;
    MockPoolFactory private poolFactory;
    AnchoredPriceProvider private provider;
    address private inSwapProvider;

    /// @dev OracleBase binds reads to the provider reported by the calling pool.
    function inSwap() external view returns (address) {
        return inSwapProvider;
    }

    function setUp() public {
        vm.warp(1_000_000);
        vm.deal(address(this), 1 ether);

        oracle = new TestOracle(address(this), 60);
        providerFactory = new AnchoredProviderFactory(address(this));
        providerFactory.addOracle(address(oracle));
        providerFactory.setEnvelope(
            MAJORS,
            IAnchoredProviderFactory.Envelope({
                minMarginMin: 1e13,
                minMarginMax: 1e15,
                stalenessMin: 1,
                stalenessMax: MAX_REF_STALENESS,
                maxSpreadMin: 10,
                maxSpreadMax: 300,
                exists: false
            })
        );
        providerFactory.setFeedClass(CHEAP_USD_FEED, MAJORS);

        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        provider = AnchoredPriceProvider(
            providerFactory.createAnchoredProvider(
                address(oracle),
                CHEAP_USD_FEED,
                EXPENSIVE_USD_FEED,
                MIN_MARGIN,
                MAX_REF_STALENESS,
                MAX_SPREAD_BPS,
                false,
                0,
                address(0xC0FFEE),
                address(0xE0E0)
            )
        );
        assertTrue(providerFactory.isProvider(address(provider)), "provider passes the trusted factory predicate");

        poolFactory.setPool(address(this), true);
        oracle.register{value: 1}(CHEAP_USD_FEED, address(this), address(poolFactory));
        oracle.register{value: 1}(EXPENSIVE_USD_FEED, address(this), address(poolFactory));

        // Both legs are current, correct, and carry only one basis point of uncertainty.
        oracle.setData(CHEAP_USD_FEED, CHEAP_USD_8, 1, 0, block.timestamp);
        oracle.setData(EXPENSIVE_USD_FEED, EXPENSIVE_USD_8, 1, 0, block.timestamp);
    }

    function testUsdcCbBtcSyntheticRatioLosesValueBeforeBandConstruction() public {
        inSwapProvider = address(provider);
        (uint128 bidQ64, uint128 askQ64) = provider.getBidAndAskPrice();

        // Production first compresses the ratio back to an 8-decimal integer:
        // floor(1e8 * 1e8 / 100000.01e8) = 999, i.e. 0.00000999 cbBTC per USDC.
        uint256 truncatedMid8 = Math.mulDiv(CHEAP_USD_8, ORACLE_DECIMALS, EXPENSIVE_USD_8);
        assertEq(truncatedMid8, 999, "production synthetic mid is 999 eight-decimal units");

        // Keeping full precision gives approximately 0.0000099999 cbBTC per USDC.
        uint256 correctMidQ64 = Math.mulDiv(CHEAP_USD_8, Q64, EXPENSIVE_USD_8);
        uint256 quotedMidQ64 = (uint256(bidQ64) + uint256(askQ64)) / 2;
        uint256 underpricingBps = Math.mulDiv(correctMidQ64 - quotedMidQ64, BPS_DENOMINATOR, correctMidQ64);

        emit log_named_decimal_uint("base feed USD price", CHEAP_USD_8, 8);
        emit log_named_decimal_uint("quote feed USD price", EXPENSIVE_USD_8, 8);
        emit log_named_decimal_uint("correct synthetic midpoint", Math.mulDiv(correctMidQ64, 1e18, Q64), 18);
        emit log_named_decimal_uint("provider quoted midpoint", Math.mulDiv(quotedMidQ64, 1e18, Q64), 18);
        emit log_named_uint("underpricing (bps)", underpricingBps);

        assertGt(correctMidQ64, quotedMidQ64, "the synthetic ratio is materially underpriced");
        assertGt(underpricingBps, 8, "error exceeds 8 bps despite fresh, narrow-spread feeds");
    }
}
