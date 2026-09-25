// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepeIce} from "../src/PepeIce.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";

contract PepeIceTest is Test {
    PepeIce internal ice;

    function setUp() public {
        ice = new PepeIce();
    }

    function test_factoryGetsFixedSupplyAndMetadata() public view {
        assertEq(ice.name(), "pepes ice");
        assertEq(ice.symbol(), "ICE");
        assertEq(ice.decimals(), 18);
        assertEq(ice.totalSupply(), 10 ** 27);
        assertEq(ice.balanceOf(address(this)), 10 ** 27);
    }

    function test_transferAndAllowanceAreExact() public {
        address spender = address(0xCAFE);
        address recipient = address(0xBEEF);
        assertTrue(ice.transfer(recipient, 50 ether));
        ice.approve(spender, 100 ether);
        vm.prank(spender);
        assertTrue(ice.transferFrom(address(this), recipient, 60 ether));
        assertEq(ice.balanceOf(recipient), 110 ether);
        assertEq(ice.balanceOf(address(this)), 10 ** 27 - 110 ether);
        assertEq(ice.allowance(address(this), spender), 40 ether);
        assertEq(ice.totalSupply(), 10 ** 27);
    }

    function test_invalidTransfersRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        ice.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(123), 0, 1));
        vm.prank(address(123));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        ice.transfer(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(123), 0, 1));
        vm.prank(address(123));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        ice.transferFrom(address(this), address(123), 1);
    }

    function test_noAdminOrSecondMintPath() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory payload = abi.encodeWithSignature(signatures[i], address(0xBEEF), 1 ether);
            (bool deployerOk,) = address(ice).call(payload);
            assertFalse(deployerOk);
            vm.prank(address(0xBEEF));
            (bool attackerOk,) = address(ice).call(payload);
            assertFalse(attackerOk);
            assertEq(ice.totalSupply(), 10 ** 27);
        }
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 10 ** 27);
        assertTrue(ice.transfer(address(0xBEEF), amount));
        assertEq(ice.balanceOf(address(this)) + ice.balanceOf(address(0xBEEF)), 10 ** 27);
        assertEq(ice.totalSupply(), 10 ** 27);
    }
}
