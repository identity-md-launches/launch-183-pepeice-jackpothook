// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JackpotFixture, JackpotHook} from "./fixtures/JackpotFixture.sol";

/// @notice Stateful sequences use real manager swaps and actual recipient balances as the payout ledger.
contract JackpotConservationTest is JackpotFixture {
    function testFuzz_mixedSequencesNeverPayMoreThanReceived(uint256 entropy) public {
        _seed();
        uint256 receivedEth = 0.01 ether;
        uint256 receivedIce = 10 ether;
        for (uint256 step; step < 40; ++step) {
            entropy = uint256(keccak256(abi.encode(entropy, step)));
            uint256 action = entropy % 3;
            if (action == 0) {
                bool zeroForOne = (entropy >> 8) % 2 == 0;
                bool exactIn = (entropy >> 9) % 2 == 0;
                bool ethSpecified = zeroForOne == exactIn;
                uint256 magnitude = ethSpecified
                    ? 0.001 ether + (entropy >> 16) % 0.01 ether
                    : 100 ether + (entropy >> 16) % 1000 ether;
                // magnitude is below 1100 ether in either currency.
                // forge-lint: disable-next-line(unsafe-typecast)
                int256 signedAmount = int256(magnitude);
                _swap(zeroForOne, exactIn ? -signedAmount : signedAmount, abi.encode(PLAYER));
                if (ethSpecified) receivedEth += magnitude / 100;
                else receivedIce += magnitude / 100;
            } else if (action == 1) {
                uint256 pees = (entropy >> 16) % 1000 + 1;
                _fill(pees);
                receivedIce += pees * 10 ether;
            } else {
                uint256 id = (entropy >> 16) % hook.nextTicketId(poolId);
                JackpotHook.Ticket memory entry = hook.ticket(poolId, id);
                if (entry.drawn) {
                    vm.expectRevert(JackpotHook.AlreadyDrawn.selector);
                    hook.draw(poolId, id);
                } else {
                    uint256 drawKind = (entropy >> 32) % 4;
                    uint256 earliest = entry.blockNumber + (drawKind == 3 ? 257 : 2);
                    if (block.number < earliest) vm.roll(earliest);
                    if (block.number - entry.blockNumber <= 256) {
                        uint256 roll = drawKind == 0 ? 77 : drawKind == 1 ? 20 * ((entropy >> 40) % 5 + 1) : 1;
                        vm.setBlockhash(entry.blockNumber + 1, _hashForRoll(poolId, id, roll));
                    }
                    hook.draw(poolId, id);
                    assertTrue(hook.ticket(poolId, id).drawn);
                }
            }
            (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
            assertLe(PLAYER.balance, receivedEth, "ETH payouts exceed all ETH received");
            assertLe(ice.balanceOf(PLAYER), receivedIce, "ICE payouts exceed all ICE received");
            assertEq(ethPot + PLAYER.balance, receivedEth, "ETH conservation");
            assertEq(icePot + ice.balanceOf(PLAYER), receivedIce, "ICE conservation");
            _assertBacking();
            vm.roll(block.number + 1);
        }
    }
}
