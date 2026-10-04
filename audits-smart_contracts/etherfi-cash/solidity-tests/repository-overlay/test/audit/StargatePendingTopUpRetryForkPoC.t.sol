// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

interface IStargateFailedReceive {
    function unreceivedTokens(bytes32 guid, uint8 index) external view returns (bytes32);

    function retryReceiveToken(bytes32 guid, uint8 index, uint32 srcEid, address receiver, uint256 amountLD, bytes calldata composeMsg) external;
}

/**
 * @notice Optimism-fork reproduction of an actual EtherFi Base -> Optimism top-up
 *         that Stargate cached after native delivery to TopUpDest failed.
 *
 * The test deliberately does not mock Stargate, TopUpDest, or WETH. At the pinned
 * production block, the failed-delivery hash has been pending since 2026-04-08.
 * Calling retryReceiveToken as an arbitrary address makes the production native
 * Stargate pool retry with unrestricted gas. TopUpDest's receive() then wraps the
 * delivered ETH into canonical Optimism WETH.
 *
 * This proves both sides of Lead 2:
 *  - EtherFi transfers can enter Stargate's unreceived-token cache after source
 *    funds have left and the cross-chain message has been delivered; and
 *  - no privileged EtherFi/Stargate intervention is required to recover them.
 *
 * The recovered WETH enters TopUpDest's shared inventory. Assigning that inventory
 * to a particular Safe remains a separate, normal TOP_UP_ROLE operation and is not
 * modeled by this bridge-lifecycle PoC.
 */
contract StargatePendingTopUpRetryForkPoC is Test {
    uint256 internal constant FORK_BLOCK = 156_156_871;

    address internal constant OP_NATIVE_STARGATE_POOL = 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3;
    address internal constant ETHERFI_TOP_UP_DEST = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87;
    address internal constant OP_WETH = 0x4200000000000000000000000000000000000006;

    // This GUID was created by Base BusDriven transaction
    // 0xa3919c4124bcc178b26343a548e56e33e994900b2825d2174adfed6f6e9e3f44.
    // Its passenger originated in EtherFi TopUpFactory transaction
    // 0x35a9e44ae542191dc255a84e6d7f0323c14ad4262afa183dcc8c9d60c3b04fea.
    bytes32 internal constant GUID = 0xb962f16128e1c7515119312fd28697ddbcf2ef94321a3ed45f210908795c6e77;
    uint8 internal constant INDEX = 0;
    uint32 internal constant BASE_EID = 30_184;
    uint256 internal constant AMOUNT = 9_519_726_000_000_000_000;

    IStargateFailedReceive internal constant POOL = IStargateFailedReceive(OP_NATIVE_STARGATE_POOL);
    IERC20 internal constant WETH = IERC20(OP_WETH);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("optimism"), FORK_BLOCK);
    }

    function testFork_anyoneCanRetryRealPendingEtherFiTopUp() public {
        bytes memory composeMsg = "";
        bytes32 expectedCacheHash = keccak256(abi.encodePacked(BASE_EID, ETHERFI_TOP_UP_DEST, AMOUNT, composeMsg));

        // The production pool still holds the failed-delivery record at this block.
        assertEq(POOL.unreceivedTokens(GUID, INDEX), expectedCacheHash, "real EtherFi delivery is not pending");

        uint256 wethBefore = WETH.balanceOf(ETHERFI_TOP_UP_DEST);
        uint256 nativeBefore = ETHERFI_TOP_UP_DEST.balance;

        // No role or relationship to the original bridge is required. Stargate's
        // retryReceiveToken is intentionally permissionless after message delivery.
        address arbitraryKeeper = makeAddr("arbitraryKeeper");
        vm.prank(arbitraryKeeper);
        POOL.retryReceiveToken(GUID, INDEX, BASE_EID, ETHERFI_TOP_UP_DEST, AMOUNT, composeMsg);

        // retryReceiveToken deletes the cache before using the native pool's
        // unrestricted-gas _safeOutflow. TopUpDest.receive() wraps all ETH to WETH.
        assertEq(POOL.unreceivedTokens(GUID, INDEX), bytes32(0), "cache was not cleared");
        assertEq(WETH.balanceOf(ETHERFI_TOP_UP_DEST), wethBefore + AMOUNT, "TopUpDest did not receive WETH");
        assertEq(ETHERFI_TOP_UP_DEST.balance, nativeBefore, "TopUpDest should wrap the delivered native ETH");
    }
}
