// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {AnchoredProviderFactory} from "../contracts/AnchoredProviderFactory.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {OracleBase} from "../contracts/oracles/providers/OracleBase.sol";
import {toTimeMs} from "../contracts/oracles/utils/TimeMs.sol";

import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";

contract SyntheticRatioOracle is OracleBase {
    constructor(address owner, uint256 maxTimeDrift) OracleBase(owner, maxTimeDrift) {}

    function setData(bytes32 feedId, uint64 price, uint16 spread, uint256 refTimeSec) external {
        oracleData[feedId] = IOffchainOracle.OracleData({
            price: price,
            spread0: spread,
            spread1: 0xFFFF,
            timestampMs: toTimeMs(refTimeSec * 1000)
        });
    }
}

contract AnchoredSyntheticRatioSpreadPoC is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant ONE_BPS_E18 = 1e14;
    uint256 private constant STEP_DENOM = 1e8 * BPS_BASE_U;

    bytes32 private constant BASE_FEED = keccak256("BTC-USD");
    bytes32 private constant QUOTE_FEED = keccak256("ETH-USD");
    bytes32 private constant MAJORS = keccak256("MAJORS");

    address private constant BTC = address(0xB7C);
    address private constant ETH = address(0xE74);

    uint256 private constant FLOOR = 5e13; // 0.5 bps
    uint16 private constant MAX_SPREAD_BPS = 300;
    uint256 private constant MAX_REF_STALENESS = 60;
    uint256 private constant T0 = 1_000_000;

    SyntheticRatioOracle private oracle;
    AnchoredProviderFactory private providerFactory;
    MockPoolFactory private poolFactory;
    AnchoredPriceProvider private provider;
    address private inSwapProvider;

    function inSwap() external view returns (address) {
        return inSwapProvider;
    }

    function setUp() public {
        vm.deal(address(this), 1 ether);
        vm.warp(T0);

        oracle = new SyntheticRatioOracle(address(this), 60);
        providerFactory = new AnchoredProviderFactory(address(this));
        providerFactory.addOracle(address(oracle));
        providerFactory.setEnvelope(MAJORS, IAnchoredProviderFactory.Envelope({
            minMarginMin: 0,
            minMarginMax: FLOOR,
            stalenessMin: 0,
            stalenessMax: MAX_REF_STALENESS,
            maxSpreadMin: 1,
            maxSpreadMax: MAX_SPREAD_BPS,
            exists: false
        }));
        providerFactory.setFeedClass(BASE_FEED, MAJORS);

        address providerAddress = providerFactory.createAnchoredProvider(
            address(oracle),
            BASE_FEED,
            QUOTE_FEED,
            FLOOR,
            MAX_REF_STALENESS,
            MAX_SPREAD_BPS,
            false,
            int256(0),
            BTC,
            ETH
        );
        provider = AnchoredPriceProvider(providerAddress);

        poolFactory = new MockPoolFactory();
        poolFactory.setPool(address(this), true);
        oracle.addApprovedFactory(address(poolFactory));
        oracle.register{value: 1}(BASE_FEED, address(this), address(poolFactory));
        oracle.register{value: 1}(QUOTE_FEED, address(this), address(poolFactory));
    }

    function test_syntheticRatioAskIsTighterThanExactDenominatorUncertainty() public {
        uint256 baseMid = 65_000 * 1e8;
        uint256 quoteMid = 3_000 * 1e8;
        uint16 baseSpreadBps = 0;
        uint16 quoteSpreadBps = 300;

        oracle.setData(BASE_FEED, uint64(baseMid), baseSpreadBps, block.timestamp);
        oracle.setData(QUOTE_FEED, uint64(quoteMid), quoteSpreadBps, block.timestamp);

        inSwapProvider = address(provider);
        (, uint128 ask) = provider.getBidAndAskPrice();

        uint256 synthMid = Math.mulDiv(baseMid, 1e8, quoteMid);
        uint256 linearHalf = (uint256(baseSpreadBps) + uint256(quoteSpreadBps)) * ONE_BPS_E18 + FLOOR;
        uint256 linearAsk = Math.mulDiv(
            synthMid,
            Q64 * (BPS_BASE_U + linearHalf),
            STEP_DENOM,
            Math.Rounding.Ceil
        );
        assertEq(uint256(ask), linearAsk, "provider uses linear spread addition");

        uint256 baseUp = BPS_BASE_U + uint256(baseSpreadBps) * ONE_BPS_E18;
        uint256 quoteDown = BPS_BASE_U - uint256(quoteSpreadBps) * ONE_BPS_E18;
        uint256 exactUpperFactor = Math.mulDiv(baseUp, BPS_BASE_U, quoteDown) + FLOOR;
        uint256 exactAsk = Math.mulDiv(
            synthMid,
            Q64 * exactUpperFactor,
            STEP_DENOM,
            Math.Rounding.Ceil
        );

        assertLt(uint256(ask), exactAsk, "ask is tighter than exact ratio uncertainty");
        assertGt((exactAsk - uint256(ask)) * 10_000 / exactAsk, 7, "gap is about 8-9 bps");
    }
}
