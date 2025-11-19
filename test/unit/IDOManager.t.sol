// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IDOManager} from "../../src/IDOManager.sol";
import {KYCRegistry} from "../../src/kyc/KYCRegistry.sol";
import {AdminManager} from "../../src/admin_manager/AdminManager.sol";
import {IIDOManager} from "../../src/interfaces/IIDOManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract IDOManagerTest is Test {
    IDOManager public idoManager;
    KYCRegistry public kycRegistry;
    AdminManager public adminManager;

    MockERC20 public usdt;
    MockERC20 public usdc;
    MockERC20 public flx;
    MockERC20 public randomToken;

    address public owner = address(this);
    address public admin = makeAddr("admin");
    address public reservesAdmin = makeAddr("reservesAdmin");
    address public user1 = makeAddr("user1");

    function setUp() public {
        // Deploy mock tokens
        usdt = new MockERC20("USDT", "USDT", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        flx = new MockERC20("FLX", "FLX", 18);
        randomToken = new MockERC20("RANDOM", "RND", 18);

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

        // Setup: Verify user1 for KYC
        kycRegistry.verify(user1);

        // Setup: Set static prices for stablecoins (8 decimals precision)
        vm.startPrank(admin);
        idoManager.setStaticPrice(address(usdt), 1e8); // $1.00
        idoManager.setStaticPrice(address(usdc), 1e8); // $1.00
        idoManager.setStaticPrice(address(flx), 1e8);  // $1.00
        vm.stopPrank();
    }

    // Helper function to create a basic IDO
    function _createBasicIDO(
        uint64 startTime,
        uint64 endTime
    ) internal returns (uint256) {
        IIDOManager.IDOInput memory idoInput = IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 1,
                totalAllocated: 0,
                minAllocation: 100e18, // 100 USD minimum
                totalAllocationByUser: 10000e18,
                totalAllocation: 1000000e18
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
                cliffDuration: 30 days,
                vestingDuration: 180 days,
                unlockInterval: 1 days,
                twapCalculationWindowHours: 24,
                timeoutForRefundAfterVesting: 90 days,
                tgeUnlockPercent: 1000000 // 10%
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

    // Test 1: isStablecoin returns true for USDT
    function test_isStablecoin_USDT() public {
        assertTrue(idoManager.isStablecoin(address(usdt)));
    }

    // Test 2: isStablecoin returns false for invalid token
    function test_isStablecoin_InvalidToken() public {
        assertFalse(idoManager.isStablecoin(address(randomToken)));
    }

    // Test 3: invest reverts with InvalidToken error for non-stablecoin
    function test_invest_RevertsWithInvalidToken() public {
        // Create an active IDO
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        // Try to invest with invalid token
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("InvalidToken()")
        );
        idoManager.invest(idoId, 1000e18, address(randomToken));
    }

    // Test 4: invest reverts with IDONotStarted error before start time
    function test_invest_RevertsBeforeStart() public {
        // Create an IDO that starts in the future
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        // Try to invest before start time
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("IDONotStarted()")
        );
        idoManager.invest(idoId, 1000e6, address(usdt));
    }

    // Test 5: invest reverts with BelowMinAllocation error for zero amount
    function test_invest_RevertsWithZeroAmount() public {
        // Create an active IDO
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 30 days);
        uint256 idoId = _createBasicIDO(startTime, endTime);

        // Mint tokens to user1 for investing
        usdt.mint(user1, 1000e6);

        // Approve IDO manager to spend tokens
        vm.prank(user1);
        usdt.approve(address(idoManager), 1000e6);

        // Try to invest with zero amount
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("BelowMinAllocation()")
        );
        idoManager.invest(idoId, 0, address(usdt));
    }
}
