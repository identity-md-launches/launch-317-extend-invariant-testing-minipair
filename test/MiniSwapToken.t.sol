// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MiniSwapToken} from "../src/MiniSwapToken.sol";

contract MiniSwapTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    MiniSwapToken internal token;
    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(factory);
        token = new MiniSwapToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Mini Swap");
        assertEq(token.symbol(), "MSWAP");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), 10 ** 27);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(factory), SUPPLY);
    }

    function test_creationCodeHasNoConstructorArguments() public {
        // The creation code alone must deploy: the factory appends nothing.
        bytes memory code = type(MiniSwapToken).creationCode;
        address deployed;
        assembly {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(deployed != address(0));
        assertEq(MiniSwapToken(deployed).balanceOf(address(this)), SUPPLY);
    }

    function test_noAdminOrMintEntryPoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "initialize(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, uint256(1));
            vm.prank(factory);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferAndAllowanceAreExact() public {
        vm.prank(factory);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(factory), SUPPLY - 1_000e18);

        vm.prank(alice);
        assertTrue(token.approve(bob, 400e18));
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 400e18));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsWhenBalanceIsShort() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(factory, bob, 1);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_transfersConserveSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != factory);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(factory);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(factory), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
