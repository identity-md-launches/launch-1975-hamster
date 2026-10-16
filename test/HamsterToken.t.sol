// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

contract HamsterTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    /// @dev Stands in for the launch factory, which deploys the token and receives the supply.
    address constant FACTORY = address(0xFAC7);
    address constant DISTRIBUTOR = address(0xD157);
    address constant POOL_MANAGER = address(0x9001);
    /// @dev The requester's economics.remainderTo (the dev vault).
    address constant DEV_VAULT = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    HamsterToken token;

    function setUp() public {
        vm.prank(FACTORY);
        token = new HamsterToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "Hamster");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.TWITTER(), "@hamsterhourgame");
    }

    function test_wholeSupplyMintedOnceToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_deployerIsWhoeverDeploys() public {
        vm.prank(ALICE);
        HamsterToken other = new HamsterToken();
        assertEq(other.balanceOf(ALICE), SUPPLY);
        assertEq(other.balanceOf(FACTORY), 0);
    }

    // ---------------------------------------------------------------- launch distribution

    /// @dev The factory's payout: 10% swarm, 10% pool, 80% dev vault, each arriving whole.
    function test_launchSplitArrivesExactly() public {
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY / 10;
        uint256 vault = SUPPLY - swarm - pool;

        vm.startPrank(FACTORY);
        assertTrue(token.transfer(DISTRIBUTOR, swarm));
        assertTrue(token.transfer(POOL_MANAGER, pool));
        assertTrue(token.transfer(DEV_VAULT, vault));
        vm.stopPrank();

        assertEq(token.balanceOf(DISTRIBUTOR), 100_000_000 ether);
        assertEq(token.balanceOf(POOL_MANAGER), 100_000_000 ether);
        assertEq(token.balanceOf(DEV_VAULT), 800_000_000 ether);
        assertEq(token.balanceOf(FACTORY), 0);
        assertEq(token.totalSupply(), SUPPLY);

        // Claims out of the distributor are whole too.
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, swarm));
        assertEq(token.balanceOf(ALICE), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
    }

    // ---------------------------------------------------------------- transfers

    function test_transferMovesExactAmountAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20Events.Transfer(FACTORY, ALICE, 123 ether);
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, 123 ether));
        assertEq(token.balanceOf(ALICE), 123 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 123 ether);
    }

    function test_transferMoreThanBalanceReverts() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 10 ether + 1)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 10 ether + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(FACTORY);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(FACTORY);
        assertTrue(token.approve(ALICE, 50 ether));
        assertEq(token.allowance(FACTORY, ALICE), 50 ether);

        vm.prank(ALICE);
        assertTrue(token.transferFrom(FACTORY, BOB, 30 ether));
        assertEq(token.balanceOf(BOB), 30 ether);
        assertEq(token.allowance(FACTORY, ALICE), 20 ether);
    }

    function test_transferFromBeyondAllowanceReverts() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 5 ether, 5 ether + 1)
        );
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 5 ether + 1);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, ALICE, 1);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(FACTORY);
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- no privileged powers

    /// @dev No mint, owner, pause, blocklist or seize entry point exists; every call reverts and the
    /// supply and balances are unchanged, whether the factory or a stranger tries.
    function test_noPrivilegedEntryPoints() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 1 ether);

        string[9] memory signatures = [
            "mint(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "setTransfersEnabled(bool)"
        ];
        address[2] memory callers = [FACTORY, BOB];
        for (uint256 i; i < signatures.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, uint256(1 ether)));
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 1 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1 ether));
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != FACTORY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(FACTORY), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromSpendsExactAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        token.approve(ALICE, allowance);

        vm.prank(ALICE);
        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, allowance, amount)
            );
            token.transferFrom(FACTORY, BOB, amount);
        } else {
            assertTrue(token.transferFrom(FACTORY, BOB, amount));
            assertEq(token.balanceOf(BOB), amount);
            assertEq(token.allowance(FACTORY, ALICE), allowance - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}

interface IERC20Events {
    event Transfer(address indexed from, address indexed to, uint256 value);
}
