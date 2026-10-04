// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ChainlinkOracle} from "../../contracts/oracles/providers/ChainlinkOracle.sol";
import {ReportV3} from "../../contracts/interfaces/IDataStreams.sol";

contract AuditFeeToken is ERC20 {
    constructor() ERC20("Fee token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Models the Chainlink RewardManager pull described by the official integration flow.
/// The report consumer must approve this contract before calling VerifierProxy.verify().
contract AuditRewardManager {
    function collect(IERC20 token, address payer, uint256 fee) external {
        token.transferFrom(payer, address(this), fee);
    }
}

/// @dev Minimal fee-aware VerifierProxy. Signature verification is irrelevant to this PoC;
/// it reaches the payment step first, exactly where ChainlinkOracle has no allowance.
contract AuditFeeChargingVerifierProxy {
    AuditRewardManager public immutable rewardManager;
    uint256 public immutable fee;

    constructor(AuditRewardManager rewardManager_, uint256 fee_) {
        rewardManager = rewardManager_;
        fee = fee_;
    }

    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory)
    {
        address feeToken = abi.decode(parameterPayload, (address));
        rewardManager.collect(IERC20(feeToken), msg.sender, fee);
        return payload;
    }
}

/// @notice On networks with a Data Streams FeeManager (including Base), report verification
/// requires a fee-token allowance to RewardManager. ChainlinkOracle passes a token address to
/// verify(), but never quotes the fee or grants that allowance. Funding it therefore cannot make
/// updateReport usable, and no owner/admin method can repair the allowance after deployment.
contract ChainlinkOracleFeeManagerAuditTest is Test {
    uint256 private constant T0 = 1_000_000;
    uint256 private constant FEE = 1e18;

    AuditFeeToken private feeToken;
    AuditRewardManager private rewardManager;
    AuditFeeChargingVerifierProxy private verifier;
    ChainlinkOracle private oracle;

    function setUp() public {
        vm.warp(T0);

        feeToken = new AuditFeeToken();
        rewardManager = new AuditRewardManager();
        verifier = new AuditFeeChargingVerifierProxy(rewardManager, FEE);
        oracle = new ChainlinkOracle(address(this), 60, address(verifier), address(feeToken));

        // Funding is not the missing step. The verifier's RewardManager needs allowance.
        feeToken.mint(address(oracle), 100 * FEE);
    }

    function test_fundedOracleCannotPayFeeManagerBecauseRewardManagerHasNoAllowance() public {
        bytes32 feedId = bytes32(uint256(3) << 240 | uint256(1));
        bytes memory report = abi.encode(
            ReportV3({
                feedId: feedId,
                validFromTimestamp: uint32(T0),
                observationsTimestamp: uint32(T0),
                nativeFee: 0,
                linkFee: uint192(FEE),
                expiresAt: uint32(T0 + 60),
                price: int192(100e18),
                bid: int192(99e18),
                ask: int192(101e18)
            })
        );

        emit log_named_uint("fee-token balance already held by oracle", feeToken.balanceOf(address(oracle)));
        emit log_named_uint(
            "allowance granted to Chainlink RewardManager",
            feeToken.allowance(address(oracle), address(rewardManager))
        );

        assertEq(feeToken.balanceOf(address(oracle)), 100 * FEE, "oracle is fully funded");
        assertEq(feeToken.allowance(address(oracle), address(rewardManager)), 0, "no approval path");

        vm.expectRevert();
        oracle.updateReport(report);

        assertEq(feeToken.balanceOf(address(oracle)), 100 * FEE, "verification never collects the fee");
    }

    function test_adminCannotRepairAllowanceThroughOracleFallback() public {
        (bool ok,) = address(oracle).call(
            abi.encodeCall(IERC20.approve, (address(rewardManager), type(uint256).max))
        );

        assertFalse(ok, "oracle fallback rejects an attempted token approval");
        assertEq(feeToken.allowance(address(oracle), address(rewardManager)), 0);
    }
}
