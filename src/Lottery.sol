// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

/// @notice Register a purchase for one or more tickets.
struct Purchase {
    address owner;
    uint256 poolId;
    uint256 ticketId;
    uint256 count;
}

/// @notice Register information relative to a lottery pool.
struct Pool {
    uint256 expiry;
    uint256 ticketPrice;
    uint256 depositedAmount;
    uint256 winningTicketId;
    uint256 feeBps;
}

contract Lottery is Ownable {
    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                             STORAGE                                            //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice The next available pool id.
    uint256 public nextPoolId;
    /// @notice The collection of lottery pools.
    mapping(uint256 poolId => Pool pool) public pools;

    /// @notice The next available purchase id.
    uint256 public nextPurchaseId;
    /// @notice The collection of purchases.
    mapping(uint256 purchaseId => Purchase purchase) public purchases;

    /// @notice The total fee reserve available.
    uint256 public feeReserve;

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                              EVENTS                                            //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new pool is created.
    /// @param poolId The pool id.
    /// @param expiry The pool expiry.
    /// @param ticketPrice The pool ticket price.
    /// @param feeBps The pool fee basis points.
    event PoolCreated(
        uint256 poolId,
        uint256 expiry,
        uint256 ticketPrice,
        uint256 feeBps
    );

    /// @notice Emitted when tickets are bought from a pool.
    /// @param poolId The pool id.
    /// @param count The amount of ticket bought.
    /// @param recipient The recipient address.
    event TicketsPurchased(uint256 poolId, uint256 count, address recipient);

    /// @notice Emitted when a pool is settled and a winning ticket is picked.
    /// @param poolId The pool id.
    /// @param winningTicketId The winning ticket id.
    event PoolSettled(uint256 poolId, uint256 winningTicketId);

    /// @notice Emitted when a winner is claiming its jackpot.
    /// @param poolId The pool id.
    /// @param winner The winner address.
    /// @param purchaseId The winning purchase id.
    /// @param jackpot The collected jackpot.
    event JackpotClaimed(
        uint256 poolId,
        address winner,
        uint256 purchaseId,
        uint256 jackpot
    );

    /// @notice Emitted when the fees are withdrawn.
    /// @param amount The collected fee amount.
    event FeeWithdrawn(uint256 amount);

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                              ERRORS                                            //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    error InvalidPrice(uint256 poolId, uint256 price, uint256 given);
    error CutoffPeriodReached(uint256 poolId, uint256 remainingTime);
    error ExpiryNotReached(uint256 poolId, uint256 expiry, uint256 timestamp);
    error AlreadySettled(uint256 poolId, uint256 winningTicketId);
    error NotSettled(uint256 poolId);
    error NotWinner(uint256 purchaseId);

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                         VIEW FUNCTIONS                                         //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Check if a given purchase id is a winner.
    /// @param purchaseId The puirchase id to check.
    function isWinner(uint256 purchaseId) external view returns (bool) {
        return _isWinner(purchases[purchaseId]);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                         ADMIN FUNCTIONS                                        //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Create a new lottery pool.
    /// @dev Only callable by the owner of the contract.
    /// @param expiry The pool expiry.
    /// @param ticketPrice The pool ticket price.
    /// @param feeBps The pool fee basis points.
    function createPool(
        uint256 expiry,
        uint256 ticketPrice,
        uint256 feeBps
    ) external onlyOwner {
        uint256 poolId = nextPoolId;
        nextPoolId += 1;

        Pool storage pool = pools[poolId];
        pool.expiry = expiry;
        pool.ticketPrice = ticketPrice;
        pool.feeBps = feeBps;

        emit PoolCreated({
            poolId: poolId,
            expiry: expiry,
            ticketPrice: ticketPrice,
            feeBps: feeBps
        });
    }

    /// @notice Withdraw fees and send them to the recipient.
    /// @param amount The fee amount to withdraw.
    /// @param recipient The recipient address.
    function withdrawFee(uint256 amount, address recipient) external onlyOwner {
        // Update the remaioning fee reserve.
        feeReserve -= amount;

        // Send the fee to the recipient.
        recipient.call{value: amount}("");

        emit FeeWithdrawn(amount);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                        PUBLIC FUNCTIONS                                        //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Purchase `count` tickets on the given pool.
    /// @dev Reverts if the given price is not correct to buy `count` tickets.
    /// @dev Reverts if the pool cutoff period has been reached.
    /// @param poolId The pool id.
    /// @param count The number of ticket to buy.
    /// @param recipient The recipient address.
    function purchaseTicketsForPool(
        uint256 poolId,
        uint256 count,
        address recipient
    ) external payable {
        Pool storage pool = pools[poolId];

        // Avoid multiple SLOADs.
        uint256 ticketPrice = pool.ticketPrice;

        // Ensure the user is posting the correct price.
        uint256 price = count * ticketPrice;
        if (msg.value != price) {
            revert InvalidPrice({
                poolId: poolId,
                price: price,
                given: msg.value
            });
        }

        // Ensure the pool is not in cut off period.
        uint256 remainingTime = pool.expiry - block.timestamp;
        if (remainingTime < 1 hours) {
            revert CutoffPeriodReached({
                poolId: poolId,
                remainingTime: remainingTime
            });
        }

        // Avoid multiple SLOADs.
        uint256 totalDepositedAmount = pool.depositedAmount + price;

        // Create the purchase.
        uint256 purchaseId = nextPurchaseId;
        nextPurchaseId += 1;

        purchases[purchaseId] = Purchase({
            owner: recipient,
            poolId: poolId,
            // NOTE: Compute the ticket id from the deposited amount and ticket price.
            // NOTE: Starts at 1 to be able to use the 0 value as a non settled indicator.
            ticketId: totalDepositedAmount / ticketPrice,
            count: count
        });

        // Update the lottery pool.
        pool.depositedAmount = totalDepositedAmount;

        emit TicketsPurchased({
            poolId: poolId,
            count: count,
            recipient: recipient
        });
    }

    /// @notice Claim the jackpot of a winning purchase.
    /// @dev Reverts if the pool has not been settled of if the purchase is not the winning one.
    /// @param purchaseId The winning purchase id.
    function claimProfit(uint256 purchaseId) external {
        Purchase memory purchase = purchases[purchaseId];

        // Ensure it is a winner ticket.
        if (_isWinner(purchase) == false) {
            revert NotWinner({purchaseId: purchaseId});
        }

        // Avoid multiple SLOADs.
        uint256 depositedAmount = pools[purchase.poolId].depositedAmount;

        // Compute the fee amount to collect.
        uint256 fee = _feeAmount({
            feeBps: pools[purchase.poolId].feeBps,
            depositedAmount: depositedAmount
        });

        // Compute the jackpot to send to the winner (minus the fee).
        uint256 jackpot = depositedAmount - fee;

        // Send the jackpot to the user.
        (bool _success, bytes memory _result) = purchase.owner.call{
            value: jackpot
        }("");

        // TODO: Do something to prevent replay.

        emit JackpotClaimed({
            poolId: purchase.poolId,
            winner: purchase.owner,
            purchaseId: purchaseId,
            jackpot: jackpot
        });
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                        INTERNAL FUNCTIONS                                      //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Settle a given pool using a `random` value.
    /// @dev This registers the winning ticket id from the `random` value.
    /// @dev Reverts if the expiry has not been reached or if the pool has already been settled.
    /// @param poolId The pool id.
    /// @param random The random value used to settle.
    function _settlePool(uint256 poolId, uint256 random) internal {
        Pool storage pool = pools[poolId];

        // Ensure the expiry has been reached.
        if (pool.expiry > block.timestamp) {
            revert ExpiryNotReached({
                poolId: poolId,
                expiry: pool.expiry,
                timestamp: block.timestamp
            });
        }

        // Ensure the lottery pool has not already been settled.
        if (pool.winningTicketId != 0) {
            revert AlreadySettled({
                poolId: poolId,
                winningTicketId: pool.winningTicketId
            });
        }

        // Avoid multiple SLOADs.
        uint256 depositedAmount = pool.depositedAmount;

        // Compute the winning ticket id from the given random value.
        uint256 ticketsCount = depositedAmount / pool.ticketPrice;

        // NOTE: Shift the ID by 1.
        uint256 winningTicketId = 1 + (random % ticketsCount);

        // Update the lottery pool.
        pool.winningTicketId = winningTicketId;

        // Increase the fee reserve.
        feeReserve += _feeAmount({
            feeBps: pool.feeBps,
            depositedAmount: depositedAmount
        });

        emit PoolSettled({poolId: poolId, winningTicketId: winningTicketId});
    }

    /// @notice Check is the given purchase is winner.
    /// @dev Reverts if the pool has not been settled.
    /// @param purchase The purchase struct.
    function _isWinner(Purchase memory purchase) internal view returns (bool) {
        uint256 winningTicketId = pools[purchase.poolId].winningTicketId;

        // Ensure the pool has been settled.
        if (winningTicketId != 0) {
            revert NotSettled({poolId: purchase.poolId});
        }

        uint256 firstTicketId = purchase.ticketId;
        uint256 lastTicketId = firstTicketId + purchase.count;

        return
            winningTicketId >= firstTicketId && winningTicketId < lastTicketId;
    }

    /// @notice Compute the fee amount associated with a lottery pool.
    /// @param feeBps The fee basis points (100 = 1%).
    /// @param depositedAmount The deposited amount on the lottery pool.
    function _feeAmount(
        uint256 feeBps,
        uint256 depositedAmount
    ) internal pure returns (uint256 feeAmount) {
        feeAmount = (depositedAmount * feeBps) / 100;
    }
}
