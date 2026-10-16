// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @notice Drives the token with a closed set of actors (the factory, the launch's recipients and
/// ordinary holders) in random order with bounded inputs. Every call either succeeds and is mirrored
/// in ghost state, or is expected to fail and is checked to fail with the exact ERC-20 error while
/// leaving state untouched. The handler itself never reverts, so the suite runs with
/// fail-on-revert on and any assertion inside the handler is a failure of the run.
contract HamsterHandler is CommonBase, StdCheats, StdUtils {
    HamsterToken public immutable token;
    uint256 public immutable supply;

    address[] public actors;
    mapping(address => bool) public isActor;

    /// @dev What each actor should hold, kept independently of the contract.
    mapping(address => uint256) public ghostBalance;
    /// @dev What each (owner, spender) allowance should be, kept independently of the contract.
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    /// @dev Volume that moved through successful transfers (transfer + transferFrom).
    uint256 public ghostVolume;
    /// @dev Count of calls that were expected to revert and did.
    uint256 public ghostExpectedReverts;
    /// @dev Count of privileged / foreign selectors tried; every one must have failed.
    uint256 public ghostPrivilegedAttempts;

    mapping(bytes32 => uint256) public calls;

    string[16] internal privilegedSignatures = [
        "mint(address,uint256)",
        "mint(uint256)",
        "mint()",
        "issue(uint256)",
        "burn(uint256)",
        "burnFrom(address,uint256)",
        "owner()",
        "setOwner(address)",
        "transferOwnership(address)",
        "pause()",
        "unpause()",
        "blacklist(address)",
        "freeze(address)",
        "seize(address)",
        "setTransfersEnabled(bool)",
        "upgradeTo(address)"
    ];

    constructor(HamsterToken token_, address[] memory actors_) {
        token = token_;
        supply = token_.totalSupply();
        for (uint256 i; i < actors_.length; ++i) {
            actors.push(actors_[i]);
            isActor[actors_[i]] = true;
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ---------------------------------------------------------------- happy paths

    /// @dev A transfer of at most the sender's balance (including zero and the full balance).
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external countCall("transfer") {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        require(ok, "transfer returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostVolume += amount;
    }

    /// @dev approve overwrites (never accumulates); the max value is the infinite allowance.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external countCall("approve") {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (amount % 7 == 0) amount = type(uint256).max; // keep the infinite-allowance branch reachable

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        require(ok, "approve returned false");

        ghostAllowance[owner][spender] = amount;
    }

    /// @dev A transferFrom within both the owner's balance and the spender's allowance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        external
        countCall("transferFrom")
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowance = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowance < cap) cap = allowance;
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        require(ok, "transferFrom returned false");

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostVolume += amount;
        if (allowance != type(uint256).max) ghostAllowance[owner][spender] = allowance - amount;
    }

    // ---------------------------------------------------------------- failure paths

    /// @dev Sending more than one holds reverts with the exact error and moves nothing.
    function transferMoreThanBalance(uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
        countCall("transferMoreThanBalance")
    {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        vm.prank(from);
        try token.transfer(to, amount) {
            revert("transfer over balance did not revert");
        } catch (bytes memory err) {
            require(
                keccak256(err)
                    == keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
                    ),
                "wrong error for transfer over balance"
            );
        }
        ghostExpectedReverts++;
    }

    /// @dev A spender may not take more than it was allowed, whatever the owner holds.
    function transferFromMoreThanAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
        countCall("transferFromMoreThanAllowance")
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowance = token.allowance(owner, spender);
        if (allowance == type(uint256).max) {
            // Nothing exceeds an infinite allowance; reset it so this path stays reachable.
            vm.prank(owner);
            token.approve(spender, 0);
            ghostAllowance[owner][spender] = 0;
            allowance = 0;
        }
        excess = bound(excess, 1, type(uint256).max - allowance);
        uint256 amount = allowance + excess;

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transferFrom over allowance did not revert");
        } catch (bytes memory err) {
            require(
                keccak256(err)
                    == keccak256(
                        abi.encodeWithSelector(
                            IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount
                        )
                    ),
                "wrong error for transferFrom over allowance"
            );
        }
        ghostExpectedReverts++;
    }

    /// @dev An allowance does not conjure a balance: within allowance but over the owner's balance
    /// reverts on the balance, and the allowance is untouched.
    function transferFromMoreThanBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
        countCall("transferFromMoreThanBalance")
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(owner);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghostAllowance[owner][spender] = type(uint256).max;

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transferFrom over balance did not revert");
        } catch (bytes memory err) {
            require(
                keccak256(err)
                    == keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
                    ),
                "wrong error for transferFrom over balance"
            );
        }
        ghostExpectedReverts++;
    }

    /// @dev The zero address is never a valid receiver or spender.
    function zeroAddressTargets(uint256 fromSeed, uint256 amount) external countCall("zeroAddressTargets") {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        try token.transfer(address(0), amount) {
            revert("transfer to zero did not revert");
        } catch (bytes memory err) {
            require(
                keccak256(err)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))),
                "wrong error for transfer to zero"
            );
        }

        vm.prank(from);
        try token.approve(address(0), amount) {
            revert("approve of zero spender did not revert");
        } catch (bytes memory err) {
            require(
                keccak256(err)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))),
                "wrong error for approve of zero spender"
            );
        }

        vm.prank(from);
        token.approve(from, type(uint256).max);
        ghostAllowance[from][from] = type(uint256).max;
        vm.prank(from);
        try token.transferFrom(from, address(0), amount) {
            revert("transferFrom to zero did not revert");
        } catch (bytes memory err) {
            require(
                keccak256(err)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))),
                "wrong error for transferFrom to zero"
            );
        }
        ghostExpectedReverts += 3;
    }

    /// @dev No privileged entry point exists for anyone, the factory included: every call fails and
    /// (by the invariants) nothing changes.
    function privilegedCall(uint256 callerSeed, uint256 sigSeed, uint256 arg) external countCall("privilegedCall") {
        address caller = _actor(callerSeed);
        string memory sig = privilegedSignatures[bound(sigSeed, 0, privilegedSignatures.length - 1)];
        address target = _actor(arg);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, target, arg));
        require(!ok, string.concat("privileged call succeeded: ", sig));
        ghostPrivilegedAttempts++;
    }

    /// @dev The token takes no ETH: a plain value transfer and a value-bearing call both fail.
    function sendEther(uint256 fromSeed, uint256 amount) external countCall("sendEther") {
        address from = _actor(fromSeed);
        amount = bound(amount, 1, 100 ether);
        vm.deal(from, amount);

        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        require(!ok, "the token accepted ETH");

        vm.prank(from);
        (ok,) = address(token).call{value: amount}(abi.encodeWithSelector(token.transfer.selector, from, 0));
        require(!ok, "a payable transfer succeeded");
        require(address(token).balance == 0, "the token holds ETH");
        ghostExpectedReverts += 2;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    address constant FACTORY = address(0xFAC7);
    address constant DISTRIBUTOR = address(0xD157);
    address constant POOL_MANAGER = address(0x9001);
    address constant DEV_VAULT = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    HamsterToken token;
    HamsterHandler handler;
    bytes32 codeHash;

    function setUp() public {
        vm.prank(FACTORY);
        token = new HamsterToken();
        codeHash = address(token).codehash;

        // Start from the launched state: 10% swarm, 10% pool, 80% dev vault.
        vm.startPrank(FACTORY);
        token.transfer(DISTRIBUTOR, SUPPLY / 10);
        token.transfer(POOL_MANAGER, SUPPLY / 10);
        token.transfer(DEV_VAULT, SUPPLY - 2 * (SUPPLY / 10));
        vm.stopPrank();

        address[] memory actors = new address[](7);
        actors[0] = FACTORY;
        actors[1] = DISTRIBUTOR;
        actors[2] = POOL_MANAGER;
        actors[3] = DEV_VAULT;
        actors[4] = ALICE;
        actors[5] = BOB;
        actors[6] = CAROL;
        handler = new HamsterHandler(token, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.transferMoreThanBalance.selector;
        selectors[4] = handler.transferFromMoreThanAllowance.selector;
        selectors[5] = handler.transferFromMoreThanBalance.selector;
        selectors[6] = handler.zeroAddressTargets.selector;
        selectors[7] = handler.privilegedCall.selector;
        selectors[8] = handler.sendEther.selector;
        selectors[9] = handler.transfer.selector; // weight ordinary transfers a little higher
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The supply is fixed at deployment: no sequence of calls, failed or not, changes it.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "total supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev Conservation: the actors are a closed set, so what they hold together is the whole supply.
    /// Nothing leaks to, or appears from, anywhere else.
    function invariant_sumOfBalancesIsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "sum of balances != total supply");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// @dev Every balance equals what the mirrored bookkeeping says it should be: a balance only
    /// changes through the holder's own transfer or a transferFrom it approved.
    function invariant_balancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.ghostBalance(actor), "balance diverged from ghost");
            assertLe(token.balanceOf(actor), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Allowances are exactly what was approved, less exactly what was spent; the infinite
    /// allowance is never decremented.
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance diverged");
            }
        }
    }

    /// @dev The contract cannot change shape: same code, same metadata, no ETH, no privileged
    /// call ever succeeded.
    function invariant_contractIsImmutable() public view {
        assertEq(address(token).codehash, codeHash, "runtime code changed");
        assertEq(token.name(), "Hamster");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.TWITTER(), "@hamsterhourgame");
        assertEq(address(token).balance, 0, "the token holds ETH");
    }

    /// @dev Round trip: anything the factory, pool or vault paid out can come back whole, so the
    /// launch's flows carry no hidden fee in either direction.
    function invariant_roundTripIsLossless() public {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            uint256 held = token.balanceOf(actor);
            if (held == 0 || actor == FACTORY) continue;
            uint256 factoryBefore = token.balanceOf(FACTORY);
            vm.prank(actor);
            assertTrue(token.transfer(FACTORY, held));
            vm.prank(FACTORY);
            assertTrue(token.transfer(actor, held));
            assertEq(token.balanceOf(actor), held, "round trip lost tokens");
            assertEq(token.balanceOf(FACTORY), factoryBefore, "round trip left tokens behind");
        }
    }

    /// @dev Harness check: every call that was supposed to fail was counted as having failed, so
    /// the failure-path handlers are not silently skipping their checks.
    function invariant_everyExpectedFailureFailed() public view {
        assertEq(
            handler.ghostExpectedReverts() + handler.ghostPrivilegedAttempts(),
            handler.calls("transferMoreThanBalance") + handler.calls("transferFromMoreThanAllowance")
                + handler.calls("transferFromMoreThanBalance") + 3 * handler.calls("zeroAddressTargets")
                + handler.calls("privilegedCall") + 2 * handler.calls("sendEther"),
            "an expected failure did not fail"
        );
    }
}
