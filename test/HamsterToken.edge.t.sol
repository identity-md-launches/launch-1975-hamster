// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @notice Deploys the token and performs the launch payout in a single transaction, the way
/// ProjectFactory.launchCustom does: the constructor is the factory for the duration of the call.
contract OneShotLaunch {
    HamsterToken public immutable token;

    constructor(address distributor, address poolManager, address remainderTo, uint256 poolBps) {
        token = new HamsterToken();
        uint256 supply = token.totalSupply();
        require(token.balanceOf(address(this)) == supply, "constructor did not mint to the deployer");
        uint256 swarm = (supply * 1_000) / 10_000;
        uint256 pool = (supply * poolBps) / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer false");
        require(token.transfer(poolManager, pool), "pool transfer false");
        require(token.transfer(remainderTo, supply - swarm - pool), "remainder transfer false");
    }
}

/// @notice The inputs the implementation did not think about: zero, one wei, the full balance, the
/// same call twice, the infinite allowance, ETH, unknown selectors, and the launch done in one
/// transaction. Edge cases are pinned as plain unit tests beside the fuzzed ones.
/// forge-config: default.fuzz.runs = 1000
contract HamsterTokenEdgeTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    address constant FACTORY = address(0xFAC7);
    address constant DISTRIBUTOR = address(0xD157);
    address constant POOL_MANAGER = address(0x9001);
    address constant DEV_VAULT = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    HamsterToken token;

    function setUp() public {
        vm.prank(FACTORY);
        token = new HamsterToken();
    }

    // ---------------------------------------------------------------- supply and construction

    function test_supplyIsExactlyOneBillionAtEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_constructorIsNotPayable() public {
        vm.deal(address(this), 1 ether);
        bytes memory code = type(HamsterToken).creationCode;
        address deployed;
        assembly {
            deployed := create(1, add(code, 32), mload(code))
        }
        assertEq(deployed, address(0), "a payable constructor accepted ETH");
        assertEq(address(this).balance, 1 ether, "the failed deployment kept the ETH");
    }

    function test_twoDeploymentsAreIndependentSupplies() public {
        vm.prank(ALICE);
        HamsterToken second = new HamsterToken();
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0, "the second deployment touched the first");
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- one-transaction launch

    /// @dev The launch as the factory performs it, in one transaction: mint to the deployer, then
    /// 10% swarm, 10% pool and 80% remainder, every flow arriving whole.
    function test_launchInOneTransaction() public {
        OneShotLaunch launch = new OneShotLaunch(DISTRIBUTOR, POOL_MANAGER, DEV_VAULT, 1_000);
        HamsterToken launched = launch.token();
        assertEq(launched.balanceOf(DISTRIBUTOR), 100_000_000 ether, "swarm share short");
        assertEq(launched.balanceOf(POOL_MANAGER), 100_000_000 ether, "pool share short");
        assertEq(launched.balanceOf(DEV_VAULT), 800_000_000 ether, "dev vault short");
        assertEq(launched.balanceOf(address(launch)), 0, "the factory kept something back");
        assertEq(launched.totalSupply(), SUPPLY);
    }

    /// @dev Whatever pool share the manifest ends up with, the three flows add up to the supply with
    /// no dust left at the factory and no flow arriving short.
    function testFuzz_launchSplitLeavesNoDust(uint256 poolBps) public {
        poolBps = bound(poolBps, 0, 9_000);
        OneShotLaunch launch = new OneShotLaunch(DISTRIBUTOR, POOL_MANAGER, DEV_VAULT, poolBps);
        HamsterToken launched = launch.token();
        uint256 swarm = SUPPLY / 10;
        uint256 pool = (SUPPLY * poolBps) / 10_000;
        assertEq(launched.balanceOf(DISTRIBUTOR), swarm);
        assertEq(launched.balanceOf(POOL_MANAGER), pool);
        assertEq(launched.balanceOf(DEV_VAULT), SUPPLY - swarm - pool);
        assertEq(launched.balanceOf(address(launch)), 0);
        assertEq(
            launched.balanceOf(DISTRIBUTOR) + launched.balanceOf(POOL_MANAGER) + launched.balanceOf(DEV_VAULT), SUPPLY
        );
    }

    /// @dev The launch cannot pay out more than it was minted: a split that asks for 100% + 1 wei
    /// fails at the factory rather than silently minting the difference.
    function test_launchCannotOverpay() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, FACTORY, SUPPLY, SUPPLY + 1)
        );
        vm.prank(FACTORY);
        token.transfer(DEV_VAULT, SUPPLY + 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- transfer edges

    function test_zeroAmountTransferSucceedsAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(ALICE, BOB, 0);
        vm.prank(ALICE); // Alice holds nothing
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_oneWeiTransfer() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, 1));
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 1);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1);
    }

    function test_transferExactBalanceLeavesZero() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(FACTORY), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        // One more wei from the emptied account fails with the exact error.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, FACTORY, 0, 1));
        vm.prank(FACTORY);
        token.transfer(ALICE, 1);
    }

    function test_transferFromEmptyAccountReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_selfTransferKeepsBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);

        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 10 ether));
        assertEq(token.balanceOf(ALICE), 10 ether, "self-transfer of the full balance changed it");

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 10 ether + 1)
        );
        vm.prank(ALICE);
        token.transfer(ALICE, 10 ether + 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_selfTransferIsIdentity(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        vm.prank(FACTORY);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToTheTokenContractIsAllowedButStranded() public {
        // Plain ERC-20 behaviour: the contract accepts its own tokens and has no way to move them.
        // Recorded so the behaviour is known, not because it is a defect.
        vm.prank(FACTORY);
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_sameTransferTwiceIsTwoTransfers() public {
        vm.startPrank(FACTORY);
        token.transfer(ALICE, 5 ether);
        token.transfer(ALICE, 5 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 10 ether);
    }

    /// @dev A chain of transfers through several holders conserves the supply and lands exactly.
    function testFuzz_multiHopConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(FACTORY);
        token.transfer(ALICE, a);
        vm.prank(ALICE);
        token.transfer(BOB, b);
        vm.prank(BOB);
        token.transfer(DEV_VAULT, c);
        assertEq(token.balanceOf(FACTORY), SUPPLY - a);
        assertEq(token.balanceOf(ALICE), a - b);
        assertEq(token.balanceOf(BOB), b - c);
        assertEq(token.balanceOf(DEV_VAULT), c);
        assertEq(
            token.balanceOf(FACTORY) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(DEV_VAULT),
            SUPPLY
        );
    }

    /// @dev Exactly one wei over whatever is held reverts, for any holding.
    function testFuzz_oneWeiOverBalanceReverts(uint256 held) public {
        held = bound(held, 0, SUPPLY - 1);
        vm.prank(FACTORY);
        token.transfer(ALICE, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, held + 1));
        vm.prank(ALICE);
        token.transfer(BOB, held + 1);
        assertEq(token.balanceOf(ALICE), held);
    }

    // ---------------------------------------------------------------- allowance edges

    function test_approveEmitsAndOverwritesRatherThanAccumulates() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(FACTORY, ALICE, 7 ether);
        vm.prank(FACTORY);
        assertTrue(token.approve(ALICE, 7 ether));

        vm.prank(FACTORY);
        assertTrue(token.approve(ALICE, 3 ether));
        assertEq(token.allowance(FACTORY, ALICE), 3 ether, "approve accumulated instead of overwriting");

        vm.prank(FACTORY);
        assertTrue(token.approve(ALICE, 0));
        assertEq(token.allowance(FACTORY, ALICE), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 1);
    }

    function test_infiniteAllowanceIsNeverDecremented() public {
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max);

        vm.startPrank(ALICE);
        assertTrue(token.transferFrom(FACTORY, BOB, 1));
        assertTrue(token.transferFrom(FACTORY, BOB, SUPPLY - 1));
        vm.stopPrank();

        assertEq(token.allowance(FACTORY, ALICE), type(uint256).max);
        assertEq(token.balanceOf(BOB), SUPPLY);
        assertEq(token.balanceOf(FACTORY), 0);
        // Infinite allowance is not an infinite balance.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, FACTORY, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 1);
    }

    function test_maxMinusOneAllowanceIsDecremented() public {
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max - 1);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 1);
        assertEq(token.allowance(FACTORY, ALICE), type(uint256).max - 2);
    }

    function test_allowanceDoesNotConjureBalance() public {
        vm.prank(ALICE); // Alice holds nothing
        token.approve(BOB, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1 ether));
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 1 ether);
        assertEq(token.allowance(ALICE, BOB), 1 ether, "a failed transferFrom spent the allowance");
    }

    function test_zeroAmountTransferFromNeedsNoAllowance() public {
        vm.prank(ALICE);
        assertTrue(token.transferFrom(FACTORY, BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(FACTORY, ALICE), 0);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, address(0), 1 ether);
        assertEq(token.allowance(FACTORY, ALICE), 1 ether);
    }

    function test_ownerSpendingItsOwnTokensViaTransferFromStillNeedsAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, FACTORY, 0, 1));
        vm.prank(FACTORY);
        token.transferFrom(FACTORY, ALICE, 1);
    }

    function test_allowanceIsPerSpender() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(FACTORY, BOB, 1);
    }

    /// @dev Spending an allowance in two chunks leaves exactly the remainder, and the chunk that
    /// crosses the line is refused with the remaining allowance named.
    function testFuzz_allowanceSpentInTwoChunks(uint256 allowance, uint256 first, uint256 second) public {
        allowance = bound(allowance, 0, SUPPLY);
        first = bound(first, 0, allowance);
        second = bound(second, 0, SUPPLY);
        vm.prank(FACTORY);
        token.approve(ALICE, allowance);

        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, first);
        uint256 remaining = allowance - first;
        assertEq(token.allowance(FACTORY, ALICE), remaining);

        vm.prank(ALICE);
        if (second > remaining) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, remaining, second)
            );
            token.transferFrom(FACTORY, BOB, second);
            assertEq(token.balanceOf(BOB), first);
        } else {
            assertTrue(token.transferFrom(FACTORY, BOB, second));
            assertEq(token.balanceOf(BOB), first + second);
            assertEq(token.allowance(FACTORY, ALICE), remaining - second);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- nothing else is reachable

    function test_rejectsEtherAndUnknownSelectors() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "the token accepted plain ETH");

        vm.prank(ALICE);
        (ok,) = address(token).call("");
        assertFalse(ok, "the token has a fallback");

        vm.prank(ALICE);
        (ok,) = address(token)
            .call(abi.encodeWithSignature("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));
        assertFalse(ok, "unknown selector was accepted");

        vm.prank(ALICE);
        (ok,) = address(token).call{value: 1}(abi.encodeWithSelector(token.transfer.selector, BOB, 0));
        assertFalse(ok, "a non-payable function accepted ETH");
        assertEq(address(token).balance, 0);
    }

    /// @dev The protected floor's full admin list, from a stranger and from the deployer: the supply
    /// never grows, the holder is never moved or frozen, and the holder can still transfer after.
    function test_adminListFromStrangerAndDeployerChangesNothing() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        address attacker = address(0xBEEF);

        string[22] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(FACTORY);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ALICE), held, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
        // The deployer cannot pull from a holder without an allowance either.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, FACTORY, 0, 1));
        vm.prank(FACTORY);
        token.transferFrom(ALICE, FACTORY, 1);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2));
        assertEq(token.balanceOf(BOB), held / 2);
    }

    /// @dev The same opcode scan the launch floor runs: no DELEGATECALL, CALLCODE or SELFDESTRUCT in
    /// the runtime, skipping PUSH immediates so data bytes are not mistaken for opcodes.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_constantsAreReadableByAnyone() public {
        vm.prank(address(0xBEEF));
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        vm.prank(address(0xBEEF));
        assertEq(token.TWITTER(), "@hamsterhourgame");
    }
}
