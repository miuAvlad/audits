// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {AnchoredPriceProvider} from "../../contracts/AnchoredPriceProvider.sol";
import {ReportV3} from "../../contracts/interfaces/IDataStreams.sol";
import {ChainlinkOracle} from "../../contracts/oracles/providers/ChainlinkOracle.sol";
import {MockDataStreamsVerifier} from "../mocks/MockDataStreamsVerifier.sol";
import {MockPoolFactory} from "../mocks/MockPoolFactory.sol";

contract ChainlinkLwbaRecenteringAuditTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant ONE_BPS_E18 = 1e14;

    // A standard v3 feed ID has schema version 3 in its high two bytes.
    bytes32 private constant FEED_ID = 0x0003000000000000000000000000000000000000000000000000000000000001;

    // Chainlink's stable-market documentation example:
    // best bid/ask = 0.99/1.00, hence top-of-book mid = 0.995;
    // liquidity-weighted bid/ask = 0.981/1.005.
    int192 private constant SOURCE_MID = 995_000_000_000_000_000;
    int192 private constant SOURCE_BID = 981_000_000_000_000_000;
    int192 private constant SOURCE_ASK = 1_005_000_000_000_000_000;

    ChainlinkOracle private oracle;
    AnchoredPriceProvider private provider;
    MockPoolFactory private poolFactory;

    address private inSwapProvider;

    function inSwap() external view returns (address) {
        return inSwapProvider;
    }

    function setUp() public {
        vm.warp(1_000_000);
        vm.deal(address(this), 1 ether);

        oracle = new ChainlinkOracle(address(this), 60, address(new MockDataStreamsVerifier()), makeAddr("feeToken"));

        oracle.updateReport(_wrap(_stableExampleReport()));

        // These fit the repository's representative majors envelope:
        // max spread 150 bps, min margin up to 10 bps.
        provider = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED_ID,
            bytes32(0),
            10 * ONE_BPS_E18,
            60,
            150,
            false,
            0,
            makeAddr("baseToken"),
            makeAddr("quoteToken")
        );

        poolFactory = new MockPoolFactory();
        poolFactory.setPool(address(this), true);
        oracle.addApprovedFactory(address(poolFactory));
        oracle.register{value: 1}(FEED_ID, address(this), address(poolFactory));
    }

    function test_officialStableExample_remainsUnsafeAfterMarginAndFiveBpsFee() public {
        inSwapProvider = address(provider);
        (uint128 providerBid, uint128 providerAsk) = provider.getBidAndAskPrice();

        uint256 sourceBidX64 = uint256(int256(SOURCE_BID)) * Q64 / 1e18;
        uint256 sourceAskX64 = uint256(int256(SOURCE_ASK)) * Q64 / 1e18;

        // Exact-input sells charge the notional fee on output. A 5 bps fee still
        // leaves the trader better off than Chainlink's original directional bid.
        uint256 netBidAfterFiveBpsFee = uint256(providerBid) * 9_995 / 10_000;
        uint256 residualOverpaymentBps = (netBidAfterFiveBpsFee - sourceBidX64) * 10_000 / sourceBidX64;

        console2.log("source LWBA bid (1e18)", _q64ToE18(sourceBidX64));
        console2.log("recentered provider bid (1e18)", _q64ToE18(providerBid));
        console2.log("net bid after 5 bps fee (1e18)", _q64ToE18(netBidAfterFiveBpsFee));
        console2.log("residual overpayment (whole bps)", residualOverpaymentBps);
        console2.log("source LWBA ask (1e18)", _q64ToE18(sourceAskX64));
        console2.log("recentered provider ask (1e18)", _q64ToE18(providerAsk));

        assertGt(providerBid, sourceBidX64, "provider pays sellers above source LWBA bid");
        assertGt(netBidAfterFiveBpsFee, sourceBidX64, "5 bps fee does not close the error");
        assertGe(residualOverpaymentBps, 4, "residual exceeds the contest's 1 bp Medium threshold");
        assertGt(providerAsk, sourceAskX64, "opposite edge remains conservative in this tuple");
    }

    function test_realSignedSamples_areProtectedByWholeBpsCeiling() public pure {
        // Values decoded from the repository's real signed v3 and HFS reports.
        _assertCeilingContainsOriginalBand(
            9_006_632_444_005_376_000, 9_005_399_041_067_735_000, 9_008_017_067_851_808_000
        );
        _assertCeilingContainsOriginalBand(
            284_610_975_428_932_343_750, 284_608_004_363_529_062_500, 284_616_434_905_239_960_937
        );
    }

    function _assertCeilingContainsOriginalBand(uint256 mid, uint256 bid, uint256 ask) private pure {
        uint256 half = (ask - bid) / 2;
        uint256 spreadBps = (10_000 * half + mid - 1) / mid;
        uint256 reconstructedBid = mid * (10_000 - spreadBps) / 10_000;
        uint256 reconstructedAsk = (mid * (10_000 + spreadBps) + 9_999) / 10_000;

        assertLe(reconstructedBid, bid, "whole-bps ceiling does not protect bid");
        assertGe(reconstructedAsk, ask, "whole-bps ceiling does not protect ask");
    }

    function _stableExampleReport() private view returns (bytes memory) {
        return abi.encode(
            ReportV3({
                feedId: FEED_ID,
                validFromTimestamp: uint32(block.timestamp),
                observationsTimestamp: uint32(block.timestamp),
                nativeFee: 0,
                linkFee: 0,
                expiresAt: uint32(block.timestamp + 60),
                price: SOURCE_MID,
                bid: SOURCE_BID,
                ask: SOURCE_ASK
            })
        );
    }

    function _wrap(bytes memory reportData) private pure returns (bytes memory) {
        bytes32[3] memory context;
        bytes32[] memory empty;
        return abi.encode(context, reportData, empty, empty, bytes32(0));
    }

    function _q64ToE18(uint256 value) private pure returns (uint256) {
        return value * 1e18 / Q64;
    }
}
