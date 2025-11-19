// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IDOManager} from "../../src/IDOManager.sol";
import {KYCRegistry} from "../../src/kyc/KYCRegistry.sol";
import {AdminManager} from "../../src/admin_manager/AdminManager.sol";
import {IIDOManager} from "../../src/interfaces/IIDOManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Malicious token for reentrancy testing
contract MaliciousToken is MockERC20 {
    address public target;
    bool public shouldAttack;

    constructor() MockERC20("Malicious", "MAL", 18) {}

    function setTarget(address _target) external {
        target = _target;
    }

    function enableAttack() external {
        shouldAttack = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (shouldAttack && target != address(0)) {
            shouldAttack = false; // Prevent infinite recursion
            // Try to reenter
            IDOManager(target).claimTokens(1);
        }
        return super.transfer(to, amount);
    }
}

contract IDOManagerTest is Test {
    IDOManager public idoManager;
    KYCRegistry public kycRegistry;
    AdminManager public adminManager;

    MockERC20 public usdt;
    MockERC20 public usdc;
    MockERC20 public flx;
    MockERC20 public randomToken;
    MockERC20 public idoToken;
    MaliciousToken public maliciousToken;

    address public owner = address(this);
    address public admin = makeAddr("admin");
    address public reservesAdmin = makeAddr("reservesAdmin");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

    uint32 constant HUNDRED_PERCENT = 10_000_000;

    function setUp() public {
        // Deploy mock tokens
        usdt = new MockERC20("USDT", "USDT", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        flx = new MockERC20("FLX", "FLX", 18);
        randomToken = new MockERC20("RANDOM", "RND", 18);
        idoToken = new MockERC20("IDO Token", "IDO", 18);
        maliciousToken = new MaliciousToken();

        // Deploy KYC registry
        kycRegistry = new KYCRegistry(owner);

        // Deploy admin manager
        adminManager = new AdminManager(owner, admin);

        // Deploy IDO manager
        idoManager = new IDOManager(
            address(usdt),
            address(usdc),
            address(flx),
            address(kycRegistry),
            reservesAdmin,
            address(adminManager),
            owner
        );

        // Setup: Verify users for KYC
        kycRegistry.verify(user1);
        kycRegistry.verify(user2);
        kycRegistry.verify(user3);

        // Setup: Set static prices for stablecoins (8 decimals precision)
        vm.startPrank(admin);
        idoManager.setStaticPrice(address(usdt), 1e8); // $1.00
        idoManager.setStaticPrice(address(usdc), 1e8); // $1.00
        idoManager.setStaticPrice(address(flx), 1e8);  // $1.00
        vm.stopPrank();
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _createBasicIDO(
        uint64 startTime,
        uint64 endTime
    ) internal returns (uint256) {
        return _createIDOWithParams(
            startTime,
            endTime,
            100e18, // minAllocation
            10000e18, // totalAllocationByUser
            1000000e18, // totalAllocation
            30 days, // cliffDuration
            180 days, // vestingDuration
            1 days, // unlockInterval
            1000000 // tgeUnlockPercent (10%)
        );
    }

    function _createIDOWithParams(
        uint64 startTime,
        uint64 endTime,
        uint256 minAllocation,
        uint256 totalAllocationByUser,
        uint256 totalAllocation,
        uint64 cliffDuration,
        uint64 vestingDuration,
        uint64 unlockInterval,
        uint64 tgeUnlockPercent
    ) internal returns (uint256) {
        IIDOManager.IDOInput memory idoInput = IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 1,
                totalAllocated: 0,
                minAllocation: minAllocation,
                totalAllocationByUser: totalAllocationByUser,
                totalAllocation: totalAllocation
            }),
            bonuses: IIDOManager.IDOBonuses({
                phase1BonusPercent: 2000000, // 20%
                phase2BonusPercent: 1000000, // 10%
                phase3BonusPercent: 500000   // 5%
            }),
            schedules: IIDOManager.IDOSchedules({
                idoStartTime: startTime,
                idoEndTime: endTime,
                claimStartTime: 0,
                tgeTime: 0,
                cliffDuration: cliffDuration,
                vestingDuration: vestingDuration,
                unlockInterval: unlockInterval,
                twapCalculationWindowHours: 24,
                timeoutForRefundAfterVesting: 90 days,
                tgeUnlockPercent: tgeUnlockPercent
            }),
            refundPenalties: IIDOManager.RefundPenalties({
                fullRefundPenalty: 500000,         // 5%
                fullRefundPenaltyBeforeTge: 200000, // 2%
                refundPenalty: 1000000              // 10%
            }),
            refundPolicy: IIDOManager.RefundPolicy({
                fullRefundDuration: 7 days,
                isRefundIfClaimedAllowed: true,
                isRefundUnlockedPartOnly: false,
                isRefundInCliffAllowed: true,
                isFullRefundBeforeTGEAllowed: true,
                isPartialRefundInCliffAllowed: true,
                isFullRefundInCliffAllowed: true,
                isPartialRefundInVestingAllowed: true,
                isFullRefundInVestingAllowed: false
            }),
            initialPriceUsdt: 1e8,     // $1.00 per token
            fullRefundPriceUsdt: 5e7   // $0.50 per token
        });

        vm.prank(admin);
        return idoManager.createIDO(idoInput);
    }

    function _mintAndApprove(address user, address token, uint256 amount) internal {
        MockERC20(token).mint(user, amount);
        vm.prank(user);
        IERC20(token).approve(address(idoManager), amount);
    }

    function _investUser(
        address user,
        uint256 idoId,
        uint256 amount,
        address token
    ) internal {
        _mintAndApprove(user, token, amount);
        vm.prank(user);
        idoManager.invest(idoId, amount, token);
    }

    function _setupFullLifecycle(uint256 idoId) internal {
        uint64 tgeTime = uint64(block.timestamp + 10 days);
        uint64 claimStartTime = tgeTime;

        vm.startPrank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, claimStartTime);
        vm.stopPrank();

        // Mint IDO tokens to contract
        idoToken.mint(address(idoManager), 10000000e18);
    }

    function _advanceToTGE(uint256 idoId) internal {
        (, , , uint64 tgeTime, , , , , , ) = idoManager.idoSchedules(idoId);
        vm.warp(tgeTime);
    }

    function _advanceToAfterCliff(uint256 idoId) internal {
        (, , , uint64 tgeTime, uint64 cliffDuration, , , , , ) = idoManager.idoSchedules(idoId);
        vm.warp(tgeTime + cliffDuration + 1);
    }

    function _advanceToMidVesting(uint256 idoId) internal {
        (, , , uint64 tgeTime, uint64 cliffDuration, uint64 vestingDuration, , , , ) = idoManager.idoSchedules(idoId);
        vm.warp(tgeTime + cliffDuration + (vestingDuration / 2));
    }

    function _advanceToAfterVesting(uint256 idoId) internal {
        (, , , uint64 tgeTime, uint64 cliffDuration, uint64 vestingDuration, , , , ) = idoManager.idoSchedules(idoId);
        vm.warp(tgeTime + cliffDuration + vestingDuration + 1);
    }

    function _calculateExpectedTokens(
        uint256 amountInUSD,
        uint256 pricePerToken,
        uint256 bonusPercent
    ) internal pure returns (uint256) {
        uint256 baseTokens = (amountInUSD * 1e8) / pricePerToken;
        uint256 bonusMultiplier = HUNDRED_PERCENT + bonusPercent;
        return (baseTokens * bonusMultiplier) / HUNDRED_PERCENT;
    }

    // ============================================
    // Test 1-5: Basic Tests (Already Implemented)
    // ============================================

    function test_isStablecoin_USDT() public view {
        assertTrue(idoManager.isStablecoin(address(usdt)));
    }

    function test_isStablecoin_InvalidToken() public view {
        assertFalse(idoManager.isStablecoin(address(randomToken)));
    }

    function test_invest_RevertsWithInvalidToken() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("InvalidToken()"));
        idoManager.invest(idoId, 1000e18, address(randomToken));
    }

    function test_invest_RevertsBeforeStart() public {
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("IDONotStarted()"));
        idoManager.invest(idoId, 1000e6, address(usdt));
    }

    function test_invest_RevertsWithZeroAmount() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _mintAndApprove(user1, address(usdt), 1000e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("BelowMinAllocation()"));
        idoManager.invest(idoId, 0, address(usdt));
    }

    // ============================================
    // createIDO Tests
    // ============================================

    function test_createIDO_Success() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        vm.expectEmit(true, true, false, false);
        emit IIDOManager.IDOCreated(1, 1, startTime, endTime);

        uint256 idoId = _createBasicIDO(startTime, endTime);

        assertEq(idoId, 1);
        assertEq(idoManager.idoCount(), 1);

        // Verify IDO storage
        (uint256 totalParticipants, uint256 totalRaisedUSDT, , ) = idoManager.idos(idoId);
        assertEq(totalParticipants, 0);
        assertEq(totalRaisedUSDT, 0);
    }

    function test_createIDO_RevertsNonAdmin() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        IIDOManager.IDOInput memory idoInput = IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 1,
                totalAllocated: 0,
                minAllocation: 100e18,
                totalAllocationByUser: 10000e18,
                totalAllocation: 1000000e18
            }),
            bonuses: IIDOManager.IDOBonuses({
                phase1BonusPercent: 2000000,
                phase2BonusPercent: 1000000,
                phase3BonusPercent: 500000
            }),
            schedules: IIDOManager.IDOSchedules({
                idoStartTime: startTime,
                idoEndTime: endTime,
                claimStartTime: 0,
                tgeTime: 0,
                cliffDuration: 30 days,
                vestingDuration: 180 days,
                unlockInterval: 1 days,
                twapCalculationWindowHours: 24,
                timeoutForRefundAfterVesting: 90 days,
                tgeUnlockPercent: 1000000
            }),
            refundPenalties: IIDOManager.RefundPenalties({
                fullRefundPenalty: 500000,
                fullRefundPenaltyBeforeTge: 200000,
                refundPenalty: 1000000
            }),
            refundPolicy: IIDOManager.RefundPolicy({
                fullRefundDuration: 7 days,
                isRefundIfClaimedAllowed: true,
                isRefundUnlockedPartOnly: false,
                isRefundInCliffAllowed: true,
                isFullRefundBeforeTGEAllowed: true,
                isPartialRefundInCliffAllowed: true,
                isFullRefundInCliffAllowed: true,
                isPartialRefundInVestingAllowed: true,
                isFullRefundInVestingAllowed: false
            }),
            initialPriceUsdt: 1e8,
            fullRefundPriceUsdt: 5e7
        });

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("CallerNotAdmin()"));
        idoManager.createIDO(idoInput);
    }

    function test_createIDO_RevertsInvalidTimeRange() public {
        uint64 startTime = uint64(block.timestamp + 30 days);
        uint64 endTime = uint64(block.timestamp); // End before start

        vm.expectRevert(abi.encodeWithSignature("InvalidIDOTimeRange()"));
        _createBasicIDO(startTime, endTime);
    }

    function test_createIDO_RevertsInvalidTotalAllocation() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        vm.expectRevert(abi.encodeWithSignature("InvalidTotalAllocation()"));
        _createIDOWithParams(
            startTime,
            endTime,
            100e18,
            10000e18,
            0, // Zero total allocation
            30 days,
            180 days,
            1 days,
            1000000
        );
    }

    function test_createIDO_RevertsInvalidVestingDuration() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        vm.expectRevert(abi.encodeWithSignature("InvalidVestingDuration()"));
        _createIDOWithParams(
            startTime,
            endTime,
            100e18,
            10000e18,
            1000000e18,
            30 days,
            0, // Zero vesting duration
            1 days,
            1000000
        );
    }

    function test_createIDO_RevertsInvalidUnlockInterval() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        vm.expectRevert(abi.encodeWithSignature("InvalidUnlockInterval()"));
        _createIDOWithParams(
            startTime,
            endTime,
            100e18,
            10000e18,
            1000000e18,
            30 days,
            180 days,
            0, // Zero unlock interval
            1000000
        );
    }

    function test_createIDO_RevertsUnlockIntervalTooLarge() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        vm.expectRevert(abi.encodeWithSignature("UnlockIntervalTooLarge()"));
        _createIDOWithParams(
            startTime,
            endTime,
            100e18,
            10000e18,
            1000000e18,
            30 days,
            180 days,
            200 days, // Interval > vesting duration
            1000000
        );
    }

    function test_createIDO_RevertsInvalidTGEUnlockPercent() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        vm.expectRevert(abi.encodeWithSignature("InvalidTGEUnlockPercent()"));
        _createIDOWithParams(
            startTime,
            endTime,
            100e18,
            10000e18,
            1000000e18,
            30 days,
            180 days,
            1 days,
            20000000 // > 100%
        );
    }

    function test_createIDO_MultipleIDOs() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        uint256 idoId1 = _createBasicIDO(startTime, endTime);
        uint256 idoId2 = _createBasicIDO(startTime + 40 days, endTime + 70 days);

        assertEq(idoId1, 1);
        assertEq(idoId2, 2);
        assertEq(idoManager.idoCount(), 2);
    }

    // ============================================
    // invest Tests
    // ============================================

    function test_invest_Success_USDT_Phase1() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint256 investAmount = 1000e6; // 1000 USDT

        // Mint and approve BEFORE expectEmit to avoid catching Transfer event
        _mintAndApprove(user1, address(usdt), investAmount);

        vm.expectEmit(true, true, false, false);
        emit IIDOManager.Investment(idoId, user1, 1000e18, address(usdt), 1000e18, 1200e18, 200e18);

        vm.prank(user1);
        idoManager.invest(idoId, investAmount, address(usdt));

        // Verify storage
        (uint256 totalParticipants, uint256 totalRaisedUSDT, , ) = idoManager.idos(idoId);
        assertEq(totalParticipants, 1);
        assertEq(totalRaisedUSDT, 1000e18);

        // Verify user info
        (uint256 investedUsdt, uint256 allocatedTokens, , , bool claimed) = idoManager.getUserInfo(idoId, user1);
        assertEq(investedUsdt, 1000e18);
        assertEq(allocatedTokens, 1200e18); // 1000 + 20% bonus
        assertFalse(claimed);
    }

    function test_invest_RevertsIDOEnded_AfterEndTime() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.warp(endTime + 1);

        _mintAndApprove(user1, address(usdt), 1000e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("IDOEnded()"));
        idoManager.invest(idoId, 1000e6, address(usdt));
    }

    function test_invest_RevertsStaticPriceNotSet() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        // Unset static price for USDT by setting it to 0
        vm.prank(admin);
        idoManager.setStaticPrice(address(usdt), 0);

        _mintAndApprove(user1, address(usdt), 1000e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("StaticPriceNotSet()"));
        idoManager.invest(idoId, 1000e6, address(usdt));
    }

    function test_invest_RevertsAlreadyInvested() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        // Try to invest again
        _mintAndApprove(user1, address(usdt), 1000e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("AlreadyInvested()"));
        idoManager.invest(idoId, 1000e6, address(usdt));
    }

    function test_invest_RevertsKYCRequired() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        address nonKYCUser = makeAddr("nonKYCUser");
        _mintAndApprove(nonKYCUser, address(usdt), 1000e6);

        vm.prank(nonKYCUser);
        vm.expectRevert(abi.encodeWithSignature("KYCRequired()"));
        idoManager.invest(idoId, 1000e6, address(usdt));
    }

    function test_invest_CorrectTokenConversion_6Decimals() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint256 investAmount = 500e6; // 500 USDT (6 decimals)
        _investUser(user1, idoId, investAmount, address(usdt));

        (uint256 investedUsdt, , , , ) = idoManager.getUserInfo(idoId, user1);
        assertEq(investedUsdt, 500e18); // Normalized to 18 decimals
    }

    function test_invest_CorrectTokenConversion_18Decimals() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint256 investAmount = 500e18; // 500 FLX (18 decimals)
        _investUser(user1, idoId, investAmount, address(flx));

        (uint256 investedUsdt, , , , ) = idoManager.getUserInfo(idoId, user1);
        assertEq(investedUsdt, 500e18); // Already 18 decimals
    }

    function test_invest_UpdatesReservesTracking() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint256 investAmount = 1000e6;
        _investUser(user1, idoId, investAmount, address(usdt));

        assertEq(idoManager.totalRaisedInToken(idoId, address(usdt)), investAmount);
    }

    // ============================================
    // claimTokens Tests
    // ============================================

    function test_claimTokens_Success_AfterTGE() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));
        _setupFullLifecycle(idoId);

        _advanceToTGE(idoId);

        uint256 balanceBefore = idoToken.balanceOf(user1);

        vm.expectEmit(true, true, false, false);
        emit IIDOManager.TokensClaimed(idoId, user1, 120e18);

        vm.prank(user1);
        idoManager.claimTokens(idoId);

        uint256 balanceAfter = idoToken.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, 120e18); // 10% of 1200 tokens

        // Verify tracking
        assertEq(idoManager.totalClaimedTokens(idoId), 120e18);
    }

    function test_claimTokens_Success_AfterVesting() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));
        _setupFullLifecycle(idoId);

        _advanceToAfterVesting(idoId);

        vm.prank(user1);
        idoManager.claimTokens(idoId);

        uint256 balance = idoToken.balanceOf(user1);
        assertEq(balance, 1200e18); // All tokens
    }

    function test_claimTokens_Success_MultipleClaims() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));
        _setupFullLifecycle(idoId);

        // Claim at TGE
        _advanceToTGE(idoId);
        vm.prank(user1);
        idoManager.claimTokens(idoId);
        assertEq(idoToken.balanceOf(user1), 120e18);

        // Claim mid-vesting
        _advanceToMidVesting(idoId);
        vm.prank(user1);
        idoManager.claimTokens(idoId);
        assertGt(idoToken.balanceOf(user1), 120e18);

        // Claim after vesting
        _advanceToAfterVesting(idoId);
        vm.prank(user1);
        idoManager.claimTokens(idoId);
        assertEq(idoToken.balanceOf(user1), 1200e18);
    }

    function test_claimTokens_RevertsClaimNotStarted() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));
        // Don't set up lifecycle

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("ClaimNotStarted()"));
        idoManager.claimTokens(idoId);
    }

    function test_claimTokens_RevertsTokenAddressNotSet() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        uint64 tgeTime = uint64(block.timestamp + 10 days);
        vm.prank(admin);
        idoManager.setClaimStartTime(idoId, tgeTime);

        vm.warp(tgeTime);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("TokenAddressNotSet()"));
        idoManager.claimTokens(idoId);
    }

    function test_claimTokens_RevertsNothingToClaim() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));
        _setupFullLifecycle(idoId);

        // Warp to TGE and claim the TGE unlock (10%)
        uint64 tgeTime = uint64(block.timestamp + 10 days);
        vm.warp(tgeTime);

        vm.prank(user1);
        idoManager.claimTokens(idoId);

        // Try to claim again immediately - no new tokens vested yet
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("NothingToClaim()"));
        idoManager.claimTokens(idoId);
    }

    // ============================================
    // processRefund Tests
    // ============================================

    function test_processRefund_Success_FullRefund_BeforeTGE() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        uint256 balanceBefore = usdt.balanceOf(user1);

        vm.expectEmit(true, true, false, false);
        emit IIDOManager.Refund(idoId, user1, 1200e18, 980e6);

        vm.prank(user1);
        idoManager.processRefund(idoId, true); // Full refund

        uint256 balanceAfter = usdt.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, 980e6); // 1000 - 2% penalty
    }

    function test_processRefund_RevertsNothingToRefund() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        // Refund once
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // Try to refund again
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("NothingToRefund()"));
        idoManager.processRefund(idoId, true);
    }

    // ============================================
    // Admin Setter Tests
    // ============================================

    function test_setStaticPrice_Success() public {
        vm.expectEmit(true, false, false, true);
        emit IIDOManager.StaticPriceSet(address(usdt), 2e8);

        vm.prank(admin);
        idoManager.setStaticPrice(address(usdt), 2e8);

        assertEq(idoManager.staticPrices(address(usdt)), 2e8);
    }

    function test_setStaticPrice_RevertsNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("CallerNotAdmin()"));
        idoManager.setStaticPrice(address(usdt), 2e8);
    }

    function test_setTokenAddress_Success() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.expectEmit(true, true, false, false);
        emit IIDOManager.TokenAddressSet(idoId, address(idoToken));

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        (, , IIDOManager.IDOInfo memory info, ) = idoManager.idos(idoId);
        assertEq(info.tokenAddress, address(idoToken));
    }

    function test_setTokenAddress_RevertsNonAdmin() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("CallerNotAdmin()"));
        idoManager.setTokenAddress(idoId, address(idoToken));
    }

    function test_setClaimStartTime_Success() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint64 claimTime = uint64(block.timestamp + 40 days);

        vm.expectEmit(true, false, false, true);
        emit IIDOManager.ClaimStartTimeSet(idoId, claimTime);

        vm.prank(admin);
        idoManager.setClaimStartTime(idoId, claimTime);

        (, , uint64 claimStartTime, , , , , , , ) = idoManager.idoSchedules(idoId);
        assertEq(claimStartTime, claimTime);
    }

    function test_setClaimStartTime_RevertsNonAdmin() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("CallerNotAdmin()"));
        idoManager.setClaimStartTime(idoId, uint64(block.timestamp + 40 days));
    }

    function test_setTgeTime_Success() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint64 tgeTime = uint64(block.timestamp + 40 days);

        vm.expectEmit(true, false, false, true);
        emit IIDOManager.TgeTimeSet(idoId, tgeTime);

        vm.prank(admin);
        idoManager.setTgeTime(idoId, tgeTime);

        (, , , uint64 storedTgeTime, , , , , , ) = idoManager.idoSchedules(idoId);
        assertEq(storedTgeTime, tgeTime);
    }

    function test_setTgeTime_RevertsNonAdmin() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("CallerNotAdmin()"));
        idoManager.setTgeTime(idoId, uint64(block.timestamp + 40 days));
    }

    // ============================================
    // View Function Tests
    // ============================================

    function test_currentPhase_Phase1() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        IIDOManager.Phase phase = idoManager.currentPhase(idoId);
        assertEq(uint(phase), uint(IIDOManager.Phase.Phase1));
    }

    function test_getUnlockedPercent_BeforeTGE() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint256 percent = idoManager.getUnlockedPercent(idoId);
        assertEq(percent, 0);
    }

    function test_getUnlockedPercent_AtTGE() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _setupFullLifecycle(idoId);
        _advanceToTGE(idoId);

        uint256 percent = idoManager.getUnlockedPercent(idoId);
        assertEq(percent, 1000000); // 10%
    }

    function test_getUnlockedPercent_AfterVesting() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _setupFullLifecycle(idoId);
        _advanceToAfterVesting(idoId);

        uint256 percent = idoManager.getUnlockedPercent(idoId);
        assertEq(percent, HUNDRED_PERCENT); // 100%
    }

    function test_getUserInfo_AfterInvestment() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        (uint256 investedUsdt, uint256 allocatedTokens, , , bool claimed) = idoManager.getUserInfo(idoId, user1);
        assertEq(investedUsdt, 1000e18);
        assertEq(allocatedTokens, 1200e18);
        assertFalse(claimed);
    }

    // ============================================
    // Integration Tests
    // ============================================

    function test_fullLifecycle_InvestClaimComplete() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        // Invest
        _investUser(user1, idoId, 1000e6, address(usdt));
        assertEq(usdt.balanceOf(address(idoManager)), 1000e6);

        // Setup lifecycle
        _setupFullLifecycle(idoId);

        // Claim at TGE
        _advanceToTGE(idoId);
        vm.prank(user1);
        idoManager.claimTokens(idoId);
        assertEq(idoToken.balanceOf(user1), 120e18);

        // Claim after vesting
        _advanceToAfterVesting(idoId);
        vm.prank(user1);
        idoManager.claimTokens(idoId);
        assertEq(idoToken.balanceOf(user1), 1200e18);
    }

    function test_fullLifecycle_MultipleUsers() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        // Multiple users invest
        _investUser(user1, idoId, 1000e6, address(usdt));
        _investUser(user2, idoId, 500e6, address(usdc));
        _investUser(user3, idoId, 750e6, address(usdt));

        _setupFullLifecycle(idoId);
        _advanceToAfterVesting(idoId);

        // All users claim
        vm.prank(user1);
        idoManager.claimTokens(idoId);
        vm.prank(user2);
        idoManager.claimTokens(idoId);
        vm.prank(user3);
        idoManager.claimTokens(idoId);

        assertEq(idoToken.balanceOf(user1), 1200e18);
        assertEq(idoToken.balanceOf(user2), 600e18);
        assertEq(idoToken.balanceOf(user3), 900e18);
    }

    // ============================================
    // Security Tests
    // ============================================

    function test_claimTokens_ReentrancyProtection() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        // Set up with malicious token
        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(maliciousToken));

        maliciousToken.setTarget(address(idoManager));
        maliciousToken.enableAttack();
        maliciousToken.mint(address(idoManager), 10000e18);

        uint64 tgeTime = uint64(block.timestamp + 10 days);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        vm.warp(tgeTime);

        // The reentrancy attempt should fail with ReentrancyGuard error
        vm.prank(user1);
        vm.expectRevert();
        idoManager.claimTokens(idoId);
    }
}
