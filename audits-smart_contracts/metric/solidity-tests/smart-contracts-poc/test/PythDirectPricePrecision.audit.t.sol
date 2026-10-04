// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PythLazer} from "pyth-lazer-sdk/PythLazer.sol";

import {PythOracle} from "../contracts/oracles/providers/PythOracle.sol";
import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {AnchoredProviderFactory} from "../contracts/AnchoredProviderFactory.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {LazerTestPayload} from "./utils/LazerTestPayload.sol";

contract PythDirectPricePrecisionAuditTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint32 private constant FEED_ID_U32 = 4;
    bytes32 private constant FEED_ID = bytes32(uint256(FEED_ID_U32));
    bytes32 private constant MEME_CLASS = keccak256("MEME");

    // A correct $0.0000050099 observation. Normalizing exponent -10 to 8 decimals
    // floors this to $0.00000500 before the anchored band is constructed.
    int64 private constant RAW_PRICE = 50_099;
    int16 private constant RAW_EXPONENT = -10;
    uint64 private constant RAW_CONFIDENCE = 5; // ceil(5 / 50099 * 10_000) = 1 bps
    uint256 private constant TRUE_PRICE_18 = 5_009_900_000_000;

    uint256 private constant MIN_MARGIN = 5e13; // 0.5 bps
    uint16 private constant MAX_SPREAD_BPS = 150;

    PythOracle private oracle;
    AnchoredPriceProvider private provider;
    address private activeProvider;

    function inSwap() external view returns (address) {
        return activeProvider;
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 1 ether);

        address owner = makeAddr("pyth-owner");
        PythLazer implementation = new PythLazer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation), owner, abi.encodeWithSelector(PythLazer.initialize.selector, owner)
        );
        PythLazer lazer = PythLazer(address(proxy));

        vm.prank(owner);
        lazer.updateTrustedSigner(LazerTestPayload.signer(), 3_000_000_000_000_000);

        uint8[] memory expectedProperties = new uint8[](4);
        expectedProperties[0] = 0;
        expectedProperties[1] = 4;
        expectedProperties[2] = 5;
        expectedProperties[3] = 12;
        oracle = new PythOracle(address(this), address(lazer), 60, expectedProperties);

        _pushSignedObservation();

        AnchoredProviderFactory providerFactory = new AnchoredProviderFactory(address(this));
        providerFactory.addOracle(address(oracle));
        providerFactory.setEnvelope(
            MEME_CLASS,
            IAnchoredProviderFactory.Envelope({
                minMarginMin: 1e13,
                minMarginMax: 1e15,
                stalenessMin: 1,
                stalenessMax: 60,
                maxSpreadMin: 10,
                maxSpreadMax: 300,
                exists: false
            })
        );
        providerFactory.setFeedClass(FEED_ID, MEME_CLASS);

        provider = AnchoredPriceProvider(
            providerFactory.createAnchoredProvider(
                address(oracle),
                FEED_ID,
                bytes32(0),
                MIN_MARGIN,
                60,
                MAX_SPREAD_BPS,
                false,
                0,
                address(0xBEEF),
                address(0xCAFE)
            )
        );
        assertTrue(providerFactory.isProvider(address(provider)), "provider must satisfy factory eligibility");

        MockPoolFactory poolFactory = new MockPoolFactory();
        poolFactory.setPool(address(this), true);
        oracle.addApprovedFactory(address(poolFactory));
        oracle.register{value: 1}(FEED_ID, address(this), address(poolFactory));
        activeProvider = address(provider);
    }

    function test_signedPythPriceIsFlooredBeforeAnchoredBand() public {
        (uint128 bidX64, uint128 askX64) = provider.getBidAndAskPrice();

        uint256 truePriceX64 = Math.mulDiv(TRUE_PRICE_18, Q64, 1e18);
        uint256 quotedMidX64 = (uint256(bidX64) + uint256(askX64)) / 2;
        uint256 midpointErrorBps = Math.mulDiv(truePriceX64 - quotedMidX64, 10_000, truePriceX64);
        uint256 askUnderpricingBps = Math.mulDiv(truePriceX64 - askX64, 10_000, truePriceX64);

        emit log_named_decimal_uint("signed Pyth price", TRUE_PRICE_18, 18);
        emit log_named_decimal_uint("stored eight-decimal midpoint", _x64ToWad(quotedMidX64), 18);
        emit log_named_decimal_uint("anchored ask after 1.0 bps confidence + 0.5 bps floor", _x64ToWad(askX64), 18);
        emit log_named_uint("midpoint floor error (bps)", midpointErrorBps);
        emit log_named_uint("ask remains below signed price (bps)", askUnderpricingBps);

        assertGe(midpointErrorBps, 19, "normalization loses at least 19 bps");
        assertGe(askUnderpricingBps, 18, "anchored ask remains at least 18 bps below the signed price");
    }

    function _pushSignedObservation() private {
        uint64 timestampMicros = uint64(block.timestamp) * 1_000_000;
        bytes[] memory feeds = new bytes[](1);
        feeds[0] = LazerTestPayload.buildFeed(
            FEED_ID_U32, RAW_PRICE, RAW_EXPONENT, RAW_CONFIDENCE, timestampMicros
        );
        bytes memory update = LazerTestPayload.signAndWrap(
            LazerTestPayload.buildPayload(timestampMicros, 1, feeds)
        );

        (bool funded,) = address(oracle).call{value: 2}("");
        require(funded, "oracle funding failed");
        (bool pushed,) = address(oracle).call(abi.encodePacked(uint16(1), FEED_ID_U32, update));
        require(pushed, "signed Pyth update failed");
    }

    function _x64ToWad(uint256 valueX64) private pure returns (uint256) {
        return Math.mulDiv(valueX64, 1e18, Q64);
    }
}
