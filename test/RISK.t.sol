// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RISK} from "../src/RISK.sol";

contract RISKTest is Test {
    RISK token;

    function setUp() public {
        token = new RISK();
    }

    function test_supplyAndFactoryDistribution() public {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.name(), "IMD RISK");
        assertEq(token.symbol(), "RISK");
        assertEq(token.decimals(), 18);
        address distributor = makeAddr("distributor");
        address poolSeeder = makeAddr("poolSeeder");
        token.transfer(distributor, 1e26);
        token.transfer(poolSeeder, 9e26);
        assertEq(token.balanceOf(distributor), 1e26);
        assertEq(token.balanceOf(poolSeeder), 9e26);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_transferAndAllowance(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 1);
    }

    function test_noMintAndInvalidTransfer() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(makeAddr("empty"));
        vm.expectRevert();
        token.transfer(address(this), 1);
    }
}
