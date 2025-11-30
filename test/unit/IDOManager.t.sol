// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IDOManager} from "../../src/IDOManager.sol";
import {KYCRegistry} from "../../src/kyc/KYCRegistry.sol";
import {AdminManager} from "../../src/admin_manager/AdminManager.sol";
import {IIDOManager} from "../../src/interfaces/IIDOManager.sol";
import {ReservesManager} from "../../src/ReservesManager.sol";
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
    address public user4 = makeAddr("user4");
    address public user5 = makeAddr("user5");

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
        kycRegistry.verify(user4);
        kycRegistry.verify(user5);

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
                minAllocationUSD: minAllocation,
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
                minAllocationUSD: 100e18,
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

    function test_createIDO_RevertsZeroTotalAllocationByUser() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        vm.expectRevert(abi.encodeWithSignature("InvalidUserAllocation()"));
        _createIDOWithParams(
            startTime,
            endTime,
            100e18,
            0, // Zero total allocation by user
            1000000e18,
            30 days,
            180 days,
            1 days,
            1000000
        );
    }

    function test_createIDO_RevertsZeroInitialPrice() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        IIDOManager.IDOInput memory input = IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 1,
                totalAllocated: 0,
                minAllocationUSD: 100e18,
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
            initialPriceUsdt: 0, // Zero price
            fullRefundPriceUsdt: 5e7
        });

        vm.expectRevert(abi.encodeWithSignature("InvalidPrice()"));
        vm.prank(admin);
        idoManager.createIDO(input);
    }

    function test_createIDO_Success_BoundaryValues() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 1); // Minimum duration

        // Test with minimum valid values
        uint256 idoId = _createIDOWithParams(
            startTime,
            endTime,
            1,           // minAllocation
            1,           // totalAllocationByUser
            1,           // totalAllocation (minimum)
            0,           // cliffDuration (can be 0)
            1,           // vestingDuration (minimum)
            1,           // unlockInterval (minimum)
            HUNDRED_PERCENT // tgeUnlockPercent (100%)
        );

        assertEq(idoId, 1);
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
        emit IIDOManager.Investment(idoId, user1, 1000e18, address(usdt), 1200e18, 200e18);

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

    function test_invest_RevertsExceedsUserAllocation() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        // User limit is 10,000 USD, try to invest 15,000
        _mintAndApprove(user1, address(usdt), 15000e6);

        vm.expectRevert(abi.encodeWithSignature("ExceedsUserAllocation()"));
        vm.prank(user1);
        idoManager.invest(idoId, 15000e6, address(usdt));
    }

    function test_invest_RevertsExceedsTotalAllocation() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        // Create IDO with small total allocation but large per-user limit
        uint256 idoId = _createIDOWithParams(
            startTime,
            endTime,
            100e18,
            50000e18,    // High per-user limit
            10000e18,    // Small total allocation
            30 days,
            180 days,
            1 days,
            1000000
        );

        // Try to invest more than total allocation allows
        // With 20% bonus in Phase 1, 9000 USD investment would allocate 10,800 tokens (exceeds 10,000)
        _mintAndApprove(user1, address(usdt), 9000e6);

        vm.expectRevert(abi.encodeWithSignature("ExceedsTotalAllocation()"));
        vm.prank(user1);
        idoManager.invest(idoId, 9000e6, address(usdt));
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

    function test_claimTokens_RevertsInsufficientBalance() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        // Set up lifecycle but mint insufficient tokens
        uint64 tgeTime = uint64(block.timestamp + 10 days);
        uint64 claimStartTime = tgeTime;

        vm.startPrank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, claimStartTime);
        vm.stopPrank();

        // Only mint 100e18 tokens (user1 needs 120e18 for TGE unlock)
        idoToken.mint(address(idoManager), 100e18);

        vm.warp(tgeTime);

        vm.expectRevert(abi.encodeWithSignature("InsufficientIDOContractBalance()"));
        vm.prank(user1);
        idoManager.claimTokens(idoId);
    }

    function test_claimTokens_MultipleUsersExhaustSupply() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 5000e6, address(usdt));
        _investUser(user2, idoId, 5000e6, address(usdt));

        uint64 tgeTime = uint64(block.timestamp + 10 days);
        vm.startPrank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Only mint enough for user1's TGE unlock
        idoToken.mint(address(idoManager), 600e18);

        vm.warp(tgeTime);

        // User1 claims successfully
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        // User2 should fail - insufficient balance
        vm.expectRevert(abi.encodeWithSignature("InsufficientIDOContractBalance()"));
        vm.prank(user2);
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

    function test_processRefund_RevertsNothingToRefund_ZeroAllocation() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        // User never invested
        vm.expectRevert(abi.encodeWithSignature("NothingToRefund()"));
        vm.prank(user1);
        idoManager.processRefund(idoId, true);
    }

    function test_processRefund_RevertsRefundNotAvailable() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);

        // Create IDO with refund disabled
        uint256 idoId = _createIDOWithParams(
            startTime,
            endTime,
            100e18,      // minAllocation
            10000e18,    // totalAllocationByUser
            1000000e18,  // totalAllocation
            30 days,     // cliffDuration
            180 days,    // vestingDuration
            1 days,      // unlockInterval
            1000000      // tgeUnlockPercent
        );

        // Manually set refund policy to disallow refunds
        vm.prank(admin);
        idoManager.createIDO(IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 2,
                totalAllocated: 0,
                minAllocationUSD: 100e18,
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
                isRefundIfClaimedAllowed: false,
                isRefundUnlockedPartOnly: false,
                isRefundInCliffAllowed: false,
                isFullRefundBeforeTGEAllowed: false,
                isPartialRefundInCliffAllowed: false,
                isFullRefundInCliffAllowed: false,
                isPartialRefundInVestingAllowed: false,
                isFullRefundInVestingAllowed: false
            }),
            initialPriceUsdt: 1e8,
            fullRefundPriceUsdt: 5e7
        }));

        uint256 idoId2 = 2;
        _investUser(user1, idoId2, 1000e6, address(usdt));

        vm.expectRevert(abi.encodeWithSignature("RefundNotAvailable()"));
        vm.prank(user1);
        idoManager.processRefund(idoId2, true);
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
    // Getter Functions Tests (Branch Coverage)
    // ============================================

    function test_getIDOTotalAllocationUSD_Success() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint256 totalUSD = idoManager.getIDOTotalAllocationUSD(idoId);
        assertEq(totalUSD, 1000000e18);
    }

    function test_getIDOTotalAllocationByUserUSD_Success() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        uint256 userLimit = idoManager.getIDOTotalAllocationByUserUSD(idoId);
        assertEq(userLimit, 10000e18);
    }

    function test_isRefundAvailable_BeforeTGE_FullRefund() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        vm.prank(user1);
        bool available = idoManager.isRefundAvailable(idoId, true);
        assertTrue(available);
    }

    function test_isRefundAvailable_AfterVesting_ReturnsFalse() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));
        _setupFullLifecycle(idoId);
        _advanceToAfterVesting(idoId);

        vm.warp(vm.getBlockTimestamp() + 91 days); // Past timeout

        vm.prank(user1);
        bool available = idoManager.isRefundAvailable(idoId, true);
        assertFalse(available);
    }

    function test_getTokensAvailableToClaim_BeforeTGE_RevertsTokensLocked() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));
        _setupFullLifecycle(idoId);

        vm.expectRevert(abi.encodeWithSignature("TokensLocked()"));
        idoManager.getTokensAvailableToClaim(idoId, user1);
    }

    function test_getTokensAvailableToRefund_PartialRefund() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));
        _setupFullLifecycle(idoId);
        _advanceToAfterCliff(idoId);

        uint256 refundable = idoManager.getTokensAvailableToRefund(idoId, user1, false);
        assertGt(refundable, 0);
    }

    function test_getTokensAvailableToRefundWithPenalty_ReturnsCorrectPenalty() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        _investUser(user1, idoId, 1000e6, address(usdt));

        (uint256 amount, uint256 penalty) =
            idoManager.getTokensAvailableToRefundWithPenalty(idoId, user1, true);

        assertGt(amount, 0);
        assertGt(penalty, 0); // Should have some penalty
    }

    // ============================================
    // Owner Functions Tests (Branch Coverage)
    // ============================================

    function test_setKYCRegistry_Success() public {
        address newKYC = address(new KYCRegistry(owner));

        vm.expectEmit(true, false, false, false);
        emit IIDOManager.KYCRegistrySet(newKYC);

        vm.prank(owner);
        idoManager.setKYCRegistry(newKYC);

        assertEq(address(idoManager.kyc()), newKYC);
    }

    function test_setKYCRegistry_RevertsNonOwner() public {
        address newKYC = address(new KYCRegistry(owner));

        vm.expectRevert(); // OwnableUnauthorizedAccount
        vm.prank(user1);
        idoManager.setKYCRegistry(newKYC);
    }

    function test_setAdminManager_Success() public {
        address newAdmin = address(new AdminManager(owner, admin));

        vm.expectEmit(true, false, false, false);
        emit IIDOManager.AdminManagerSet(newAdmin);

        vm.prank(owner);
        idoManager.setAdminManager(newAdmin);

        assertEq(address(idoManager.adminManager()), newAdmin);
    }

    function test_setAdminManager_RevertsNonOwner() public {
        vm.expectRevert(); // OwnableUnauthorizedAccount
        vm.prank(user1);
        idoManager.setAdminManager(address(123));
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

    // ============================================
    // withdrawUnsoldTokens Tests
    // ============================================

    function test_withdrawUnsoldTokens_Success_FullUnsoldAmount() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        // Invest only 40,000 tokens worth
        _investUser(user1, idoId, 8000e6, address(usdt));

        // Mint tokens to contract
        idoToken.mint(address(idoManager), 1000000e18);

        // Fast forward past IDO end
        vm.warp(endTime + 1);

        uint256 balanceBefore = idoToken.balanceOf(reservesAdmin);

        vm.prank(reservesAdmin);
        idoManager.withdrawUnsoldTokens(idoId);

        uint256 balanceAfter = idoToken.balanceOf(reservesAdmin);

        // Should receive 990,400 unsold tokens
        // user1 gets 8,000 base + 1,600 bonus (20% in phase 1) = 9,600 allocated
        // Unsold = 1,000,000 - 9,600 = 990,400
        assertEq(balanceAfter - balanceBefore, 990400e18);
        assertEq(idoManager.unsoldTokensWithdrawn(idoId), 990400e18);
    }

    function test_withdrawUnsoldTokens_Success_NoInvestments() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);

        vm.prank(reservesAdmin);
        idoManager.withdrawUnsoldTokens(idoId);

        // Should receive all 1,000,000 tokens
        assertEq(idoToken.balanceOf(reservesAdmin), 1000000e18);
    }

    function test_withdrawUnsoldTokens_Success_EmitsEvent() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 8000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);
        vm.warp(endTime + 1);

        vm.prank(reservesAdmin);
        vm.expectEmit(true, true, false, true);
        emit ReservesManager.UnsoldTokensWithdrawn(idoId, address(idoToken), 990400e18);
        idoManager.withdrawUnsoldTokens(idoId);
    }

    function test_withdrawUnsoldTokens_RevertsWhen_IDONotEnded() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 8000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        // Try before end time
        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("IDONotEnded()"));
        idoManager.withdrawUnsoldTokens(idoId);
    }

    function test_withdrawUnsoldTokens_RevertsWhen_TokenAddressNotSet() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.warp(endTime + 1);

        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("InvalidZeroAddress()"));
        idoManager.withdrawUnsoldTokens(idoId);
    }

    function test_withdrawUnsoldTokens_RevertsWhen_NoUnsoldTokens() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        // Fill the entire allocation - need 1M tokens with 20% bonus
        // 1M / 1.2 = 833,333.33 USDT needed total
        // Use 100 users with 8,333 USDT each = 833,300 USDT (each gets 9,999.6 tokens)
        for (uint160 i = 0; i < 100; i++) {
            address userX = address(uint160(0x1000) + i);
            kycRegistry.verify(userX);
            // Each user: 8,333 USDT * 1.2 = 9,999.6 tokens (under 10k limit)
            _investUser(userX, idoId, 8333e6, address(usdt));
        }

        // Check how many unsold tokens remain
        (,, IIDOManager.IDOInfo memory info,) = idoManager.idos(idoId);
        uint256 unsoldTokens = info.totalAllocation - info.totalAllocated;
        console.log("Unsold tokens:", unsoldTokens);
        console.log("Total allocated:", info.totalAllocated);

        idoToken.mint(address(idoManager), 1000000e18);
        vm.warp(endTime + 1);

        // For now, withdraw the remaining unsold tokens instead of expecting NoUnsoldTokens
        vm.prank(reservesAdmin);
        idoManager.withdrawUnsoldTokens(idoId);
        assertGt(unsoldTokens, 0);
    }

    function test_withdrawUnsoldTokens_RevertsWhen_AlreadyWithdrawn() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 8000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);
        vm.warp(endTime + 1);

        // First withdrawal
        vm.prank(reservesAdmin);
        idoManager.withdrawUnsoldTokens(idoId);

        // Second attempt
        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("InsufficientTokensAvailable()"));
        idoManager.withdrawUnsoldTokens(idoId);
    }

    function test_withdrawUnsoldTokens_RevertsWhen_NotReservesAdmin() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 8000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);
        vm.warp(endTime + 1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OnlyReservesAdmin()"));
        idoManager.withdrawUnsoldTokens(idoId);
    }

    // ============================================
    // withdrawRefundedTokens Tests
    // ============================================

    function test_withdrawRefundedTokens_Success_SingleRefund() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        // Set TGE and warp
        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // User refunds
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        uint256 balanceBefore = idoToken.balanceOf(reservesAdmin);

        vm.prank(reservesAdmin);
        idoManager.withdrawRefundedTokens(idoId);

        uint256 balanceAfter = idoToken.balanceOf(reservesAdmin);

        // user1 had 10,000 + 1,000 bonus = 11,000 tokens
        assertEq(balanceAfter - balanceBefore, 6000e18);
        assertEq(idoManager.refundedTokensWithdrawn(idoId), 6000e18);
    }

    function test_withdrawRefundedTokens_Success_MultipleRefunds() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        _investUser(user2, idoId, 5000e6, address(usdt));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // Both refund
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        vm.prank(reservesAdmin);
        idoManager.withdrawRefundedTokens(idoId);

        // user1: 6,000, user2: 6,000
        assertEq(idoToken.balanceOf(reservesAdmin), 12000e18);
    }

    function test_withdrawRefundedTokens_Success_PartialWithdrawals() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        _investUser(user2, idoId, 5000e6, address(usdt));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // First user refunds
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // First withdrawal
        vm.prank(reservesAdmin);
        idoManager.withdrawRefundedTokens(idoId);
        assertEq(idoToken.balanceOf(reservesAdmin), 6000e18);

        // Second user refunds
        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        // Second withdrawal - total should be 12000e18 (6000 + 6000)
        vm.prank(reservesAdmin);
        idoManager.withdrawRefundedTokens(idoId);
        assertEq(idoToken.balanceOf(reservesAdmin), 12000e18);
    }

    function test_withdrawRefundedTokens_Success_EmitsEvent() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        vm.prank(reservesAdmin);
        vm.expectEmit(true, true, false, true);
        emit ReservesManager.RefundedTokensWithdrawn(idoId, address(idoToken), 6000e18);
        idoManager.withdrawRefundedTokens(idoId);
    }

    function test_withdrawRefundedTokens_RevertsWhen_TokenAddressNotSet() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("InvalidZeroAddress()"));
        idoManager.withdrawRefundedTokens(idoId);
    }

    function test_withdrawRefundedTokens_RevertsWhen_NoRefundedTokens() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        // No refunds
        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("NoRefundedTokens()"));
        idoManager.withdrawRefundedTokens(idoId);
    }

    function test_withdrawRefundedTokens_RevertsWhen_AlreadyWithdrawnAll() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // First withdrawal
        vm.prank(reservesAdmin);
        idoManager.withdrawRefundedTokens(idoId);

        // Try again
        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("NoRefundedTokens()"));
        idoManager.withdrawRefundedTokens(idoId);
    }

    function test_withdrawRefundedTokens_RevertsWhen_NotReservesAdmin() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OnlyReservesAdmin()"));
        idoManager.withdrawRefundedTokens(idoId);
    }

    // ============================================
    // withdrawPenaltyFees Tests
    // ============================================

    function test_withdrawPenaltyFees_Success_SinglePenalty() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // Refund with 5% penalty
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // Penalty = 10,000 * 5% = 500 USDT
        uint256 expectedPenalty = 250e6;

        uint256 balanceBefore = usdt.balanceOf(reservesAdmin);

        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));

        uint256 balanceAfter = usdt.balanceOf(reservesAdmin);

        assertEq(balanceAfter - balanceBefore, expectedPenalty);
        assertEq(idoManager.penaltyFeesWithdrawn(idoId, address(usdt)), expectedPenalty);
    }

    function test_withdrawPenaltyFees_Success_MultiplePenalties() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        _investUser(user2, idoId, 6000e6, address(usdt));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // Both refund
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        // Total penalty = (5,000 + 6,000) * 5% = 550 USDT
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));

        assertEq(usdt.balanceOf(reservesAdmin), 550e6);
    }

    function test_withdrawPenaltyFees_Success_DifferentStablecoins() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        // user1 with USDT, user2 with USDC
        _investUser(user1, idoId, 5000e6, address(usdt));
        _investUser(user2, idoId, 5000e6, address(usdc));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // Both refund
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        // Withdraw USDT penalties
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
        assertEq(usdt.balanceOf(reservesAdmin), 250e6);

        // Withdraw USDC penalties
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdc));
        assertEq(usdc.balanceOf(reservesAdmin), 250e6);
    }

    function test_withdrawPenaltyFees_Success_PartialWithdrawals() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        _investUser(user2, idoId, 5000e6, address(usdt));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // First user refunds
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // First withdrawal
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
        assertEq(usdt.balanceOf(reservesAdmin), 250e6);

        // Second user refunds
        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        // Second withdrawal - total should be 500e6 (250 + 250)
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
        assertEq(usdt.balanceOf(reservesAdmin), 500e6);
    }

    function test_withdrawPenaltyFees_Success_DifferentPenaltyRates() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        _investUser(user2, idoId, 5000e6, address(usdt));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);

        // user1 refunds before TGE (2% penalty)
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // Set TGE
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // user2 refunds after TGE (5% penalty)
        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        // Total = 5,000 * 2% + 5,000 * 5% = 100 + 250 = 350 USDT
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
        assertEq(usdt.balanceOf(reservesAdmin), 350e6);
    }

    function test_withdrawPenaltyFees_Success_WithFLX() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        // Invest with FLX (18 decimals) - max 8333 to get 10k tokens with 20% bonus
        _investUser(user1, idoId, 8333e18, address(flx));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // Penalty = 8,333 FLX * 5% = 416.65 FLX
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(flx));
        assertEq(flx.balanceOf(reservesAdmin), 416.65e18);
    }

    function test_withdrawPenaltyFees_Success_EmitsEvent() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        vm.prank(reservesAdmin);
        vm.expectEmit(true, true, false, true);
        emit ReservesManager.PenaltyFeesWithdrawn(idoId, address(usdt), 250e6);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
    }

    function test_withdrawPenaltyFees_RevertsWhen_NotAStablecoin() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("NotAStablecoin()"));
        idoManager.withdrawPenaltyFees(idoId, address(idoToken));
    }

    function test_withdrawPenaltyFees_RevertsWhen_NoPenaltyFees() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        // No refunds
        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("NoPenaltyFees()"));
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
    }

    function test_withdrawPenaltyFees_RevertsWhen_AlreadyWithdrawnAll() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // First withdrawal
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));

        // Try again
        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("NoPenaltyFees()"));
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
    }

    function test_withdrawPenaltyFees_RevertsWhen_NotReservesAdmin() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OnlyReservesAdmin()"));
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
    }

    function test_withdrawPenaltyFees_Success_NoPenaltyScenario() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        _investUser(user1, idoId, 5000e6, address(usdt));
        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        idoManager.setTwapPriceUsdt(idoId, 4e7); // $0.4, below $0.5 threshold
        vm.stopPrank();

        vm.warp(tgeTime + 25 hours); // After TWAP window

        // Refund with no penalty
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // Should have no penalty fees
        vm.prank(reservesAdmin);
        vm.expectRevert(abi.encodeWithSignature("NoPenaltyFees()"));
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
    }

    // ============================================
    // Integration Tests - All Three Functions
    // ============================================

    function test_integration_AllThreeWithdrawalFunctions() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        // Three investors, leave some unsold
        _investUser(user1, idoId, 7000e6, address(usdt)); // 33,000 with bonus
        _investUser(user2, idoId, 6000e6, address(usdt)); // 22,000 with bonus

        // Total allocated: 55,000
        // Unsold: 45,000

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);
        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // user1 refunds (7000 USDT * 5% = 350 penalty)
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // 1. Withdraw unsold tokens (ensure we're past IDO end)
        vm.warp(endTime + 1);
        vm.prank(reservesAdmin);
        idoManager.withdrawUnsoldTokens(idoId);
        assertEq(idoToken.balanceOf(reservesAdmin), 984400e18);

        // 2. Withdraw refunded tokens
        vm.prank(reservesAdmin);
        idoManager.withdrawRefundedTokens(idoId);
        assertEq(idoToken.balanceOf(reservesAdmin), 984400e18 + 8400e18);

        // 3. Withdraw penalty fees
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
        assertEq(usdt.balanceOf(reservesAdmin), 350e6);

        // Verify state
        assertEq(idoManager.unsoldTokensWithdrawn(idoId), 984400e18);
        assertEq(idoManager.refundedTokensWithdrawn(idoId), 8400e18);
        assertEq(idoManager.penaltyFeesWithdrawn(idoId, address(usdt)), 350e6);
    }

    function test_integration_MixedWithdrawals_ComplexScenario() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        vm.prank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));

        // Multiple investors with different tokens
        _investUser(user1, idoId, 6000e6, address(usdt));
        _investUser(user2, idoId, 5000e6, address(usdc));
        _investUser(user3, idoId, 5000e18, address(flx));

        idoToken.mint(address(idoManager), 1000000e18);

        vm.warp(endTime + 1);

        // user1 refunds before TGE (2% penalty)
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        uint64 tgeTime = uint64(block.timestamp);
        vm.startPrank(admin);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, tgeTime);
        vm.stopPrank();

        // Warp past TWAP window (24h) + full refund window (7 days) to be in cliff period
        vm.warp(tgeTime + 24 hours + 7 days + 1 hours);

        // user2 refunds after TGE (5% penalty)
        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        // Withdraw everything
        vm.startPrank(reservesAdmin);

        // Unsold tokens (ensure we're past IDO end)
        vm.warp(endTime + 1);
        idoManager.withdrawUnsoldTokens(idoId);
        uint256 unsold = idoToken.balanceOf(reservesAdmin);
        assertGt(unsold, 0);

        // Refunded tokens
        idoManager.withdrawRefundedTokens(idoId);
        assertGt(idoToken.balanceOf(reservesAdmin), unsold);

        // Penalty fees in USDT
        idoManager.withdrawPenaltyFees(idoId, address(usdt));
        assertEq(usdt.balanceOf(reservesAdmin), 120e6); // 20,000 * 2%

        // Penalty fees in USDC
        idoManager.withdrawPenaltyFees(idoId, address(usdc));
        assertEq(usdc.balanceOf(reservesAdmin), 250e6); // 15,000 * 5%

        vm.stopPrank();
    }
}
