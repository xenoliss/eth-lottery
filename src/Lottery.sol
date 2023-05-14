// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

import {VRFV2WrapperConsumerBase, LinkTokenInterface} from "chainlink/v0.8/VRFV2WrapperConsumerBase.sol";

/// @notice Register a receipt for one or more tickets.
struct Receipt {
    /// @notice The owner address.
    address owner;
    /// @notice The associated pool id.
    /// @dev 2**64 - 1 = 18446744073709551616, which should not be reached.
    uint64 poolId;
    /// @notice The starting ticket id this receipt is for.
    /// @dev 2**128 - 1 = 340282366920938463463374607431768211455, should be enough.
    uint128 ticketId;
    /// @notice The number of tickets bought in this receipt.
    /// @dev 2**64 - 1 = 18446744073709551616, which should not be reached.
    uint64 count;
}

/// @notice The three possible settlement steps for a lottery pool.
enum PoolSettlementStep {
    Idle,
    Initiated,
    Settled
}

/// @notice Register information relative to a lottery pool.
struct Pool {
    /// @notice The pool expiry timestamp.
    /// @dev 2**64 - 1 = 18446744073709551615, human race will have died when it's reached.
    uint64 expiry;
    /// @notice The pool ticket price in wei.
    /// @dev 2**64 - 1 = 18446744073709551615 ~= 18.4 ETH.
    uint64 ticketPrice;
    /// @notice The pool starting jackpot in wei.
    /// @dev 2**96 - 1 = 79228162514264337593543950335 ~= 79B ETH.
    uint96 startingJackpot;
    /// @notice The non-winner percent in 2 basis points (10000 = 100.00%, 100 = 1.00%, 1 = 0.01%).
    /// @dev 2**16 - 1 = 65535 ~= 655%.
    uint16 noWinnerPercent;
    /// @notice The fee percent in 2 basis points (10000 = 100.00%, 100 = 1.00%, 1 = 0.01%).
    /// @dev 2**16 - 1 = 65535 ~= 655%.
    uint16 feePercent;
    /// @notice The pool deposited amount in wei.
    /// @dev 2**96 - 1 = 79228162514264337593543950335 ~= 79B ETH.
    uint96 depositedAmount;
    /// @notice The winning ticket id when the pool is settled.
    /// @dev 2**128 - 1 = 340282366920938463463374607431768211455, should be enough.
    uint128 winningTicketId;
    /// @notice The pool settlement state.
    PoolSettlementStep settlementStep;
}

contract Lottery is Ownable, VRFV2WrapperConsumerBase {
    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                             STORAGE                                            //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice The next available pool id.
    uint256 public nextPoolId;

    /// @notice The collection of lottery pools.
    mapping(uint256 poolId => Pool pool) public pools;

    /// @notice The next available receipt id.
    uint256 public nextReceiptId;

    /// @notice The collection of receipts.
    mapping(uint256 receiptId => Receipt receipt) public receipts;

    /// @notice The available amount that can be reinvested in next lottery pools.
    uint256 public availableAmount;

    /// @notice The available fee reserve.
    uint256 public availableFee;

    /// @notice The gas limit for Chainlink VRFV2 callbacks.
    uint256 public vrfCallbackGasLimit;

    /// @notice The request confirmations used by Chainlink VRFV2.
    uint256 public vrfRequestConfirmations;

    /// @notice Link Chainlink VRFV2 request id to their associated lottery pool id.
    mapping(uint256 vrfRequestId => uint256 poolId) public vrfRequestToPoolId;

    constructor(
        address link,
        address vrfV2Wrapper,
        uint32 _vrfCallbackGasLimit,
        uint16 _vrfRequestConfirmations
    ) VRFV2WrapperConsumerBase(link, vrfV2Wrapper) {
        vrfCallbackGasLimit = _vrfCallbackGasLimit;
        vrfRequestConfirmations = _vrfRequestConfirmations;
        emit VrfCallbackGasLimitUpdated(_vrfCallbackGasLimit);
        emit VrfRequestConfirmationsUpdated(_vrfRequestConfirmations);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                              EVENTS                                            //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when the callback gas limit for Chainlink VRF2 has been updated.
    /// @param gasLimit The gas limit.
    event VrfCallbackGasLimitUpdated(uint32 gasLimit);

    /// @notice Emitted when the number of confirmation used by Chainlink VRF2 has been updated.
    /// @param requestConfirmations The request confirmations.
    event VrfRequestConfirmationsUpdated(uint16 requestConfirmations);

    /// @notice Emitted when a new pool is created.
    /// @param poolId The pool id.
    /// @param expiry The pool expiry.
    /// @param ticketPrice The pool ticket price.
    /// @param startingJackpot The starting amount from previous pools that settled without winners.
    /// @param noWinnerPercent The pool no winner percent.
    /// @param feePercent The pool fee percent.
    event PoolCreated(
        uint256 poolId,
        uint256 expiry,
        uint256 ticketPrice,
        uint256 startingJackpot,
        uint256 noWinnerPercent,
        uint256 feePercent
    );

    /// @notice Emitted when tickets are bought from a pool.
    /// @param poolId The pool id.
    /// @param count The amount of ticket bought.
    /// @param recipient The recipient address.
    event TicketsReceiptd(uint256 poolId, uint256 count, address recipient);

    /// @notice Emitted when a pool is settled and a winning ticket is picked.
    /// @param poolId The pool id.
    /// @param winningTicketId The winning ticket id (only valid if hasWinner is true).
    /// @param hasWinner Wether the settlement found a winner ticket or not.
    event PoolSettled(uint256 poolId, uint256 winningTicketId, bool hasWinner);

    /// @notice Emitted when a winner is claiming its jackpot.
    /// @param poolId The pool id.
    /// @param winner The winner address.
    /// @param receiptId The winning receipt id.
    /// @param jackpot The collected jackpot.
    event JackpotClaimed(
        uint256 poolId,
        address winner,
        uint256 receiptId,
        uint256 jackpot
    );

    /// @notice Emitted when fees are withdrawn.
    /// @param recipient The recipient address.
    /// @param amount The withdrawn fee amount.
    event FeeWithdrawn(address recipient, uint256 amount);

    /// @notice Emitted when links are withdrawn.
    /// @param recipient The recipient address.
    /// @param amount The withdrawn link amount.
    event LinkWithdrawn(address recipient, uint256 amount);

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                              ERRORS                                            //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Reverted when creating a pool with an invalid ticket price.
    /// @param price The ticket price.
    error InvalidTicketPrice(uint256 price);

    /// @notice Reverted when creating a pool with an invalid non-winner percent.
    /// @param percent The non-winner percent.
    error InvalidNoWinnerPercent(uint256 percent);

    /// @notice Reverted when creating a pool with an invalid fee percent.
    /// @param percent The fee percent.
    error InvalidFeePercent(uint256 percent);

    /// @notice Reverted when creating a pool with an invalid expiry.
    /// @param expiry The expiry.
    error InvalidExpiry(uint256 expiry);

    /// @notice Reverted when trying to receipt tickets with an incorrect price.
    /// @param poolId The pool id.
    /// @param price The requested price.
    /// @param given The given funds.
    error IncorrectPrice(uint256 poolId, uint256 price, uint256 given);

    /// @notice Reverted when trying to receipt tickets on a pool which reached the cutoff period.
    /// @param poolId The pool id.
    /// @param remainingTime The remaining time before settlement.
    error CutoffPeriodReached(uint256 poolId, uint256 remainingTime);

    /// @notice Reverted when trying settle a pool that did not expired yet.
    /// @param poolId The pool id.
    /// @param expiry The pool expiry.
    /// @param timestamp The current timestamp.
    error ExpiryNotReached(uint256 poolId, uint256 expiry, uint256 timestamp);

    /// @notice Reverted when trying settle a pool has already been settled.
    /// @param poolId The pool id.
    error AlreadySettled(uint256 poolId);

    /// @notice Reverted when trying check if a receipt is a winner on a pool that did not settled.
    /// @param poolId The pool id.
    error NotSettled(uint256 poolId);

    /// @notice Reverted when trying claim the jackpot with a loosing receipt.
    /// @param receiptId The receipt id.
    error NotWinner(uint256 receiptId);

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                         VIEW FUNCTIONS                                         //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Check if a given receipt id is a winner.
    /// @param receiptId The puirchase id to check.
    function isWinner(uint256 receiptId) external view returns (bool) {
        return _isWinner(receipts[receiptId]);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                         ADMIN FUNCTIONS                                        //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Set the Chainlink VRFV2 callback gas limit.
    /// @dev Only callable by the owner of the contract.
    /// @param gasLimit The gas limit to set.
    function setVrfCallbackGasLimit(uint32 gasLimit) external onlyOwner {
        vrfCallbackGasLimit = gasLimit;
        emit VrfCallbackGasLimitUpdated(gasLimit);
    }

    /// @notice Set the Chainlink VRFV2 request confirmations.
    /// @dev Only callable by the owner of the contract.
    /// @param requestConfirmations The request confirmations to set.
    function setVrfCallbackGasLimit(
        uint16 requestConfirmations
    ) external onlyOwner {
        vrfRequestConfirmations = requestConfirmations;
        emit VrfRequestConfirmationsUpdated(requestConfirmations);
    }

    /// @notice Create a new lottery pool.
    /// @dev Only callable by the owner of the contract.
    /// @dev Reverts if the non-winner or fee percent are invalid.
    /// @param expiry The pool expiry.
    /// @param ticketPrice The pool ticket price.
    /// @param startingJackpot The starting amount from previous pools that settled without winners.
    /// @param noWinnerPercent The no winner percent.
    /// @param feePercent The pool fee percent.
    function createPool(
        uint64 expiry,
        uint64 ticketPrice,
        uint96 startingJackpot,
        uint16 noWinnerPercent,
        uint16 feePercent
    ) external onlyOwner {
        // Ensure the ticket price is at least 0.0001 ETH to avoid spaming.
        if (ticketPrice < 1e14) {
            revert InvalidTicketPrice(ticketPrice);
        }

        // Ensure the non-winner percent can't be equal or more than 100%.
        if (noWinnerPercent >= 1e4) {
            revert InvalidNoWinnerPercent(noWinnerPercent);
        }

        // Ensure the fee percent can't be equal or more than 100%.
        if (feePercent >= 1e4) {
            revert InvalidFeePercent(feePercent);
        }

        // Ensure the expiry is at least in 1 day.
        if (expiry - block.timestamp < 1 days) {
            revert InvalidExpiry(expiry);
        }

        uint256 poolId = nextPoolId;
        nextPoolId += 1;

        // Decrease the available amount by the amount that is reinvested.
        availableAmount -= startingJackpot;

        Pool storage pool = pools[poolId];
        pool.expiry = expiry;
        pool.ticketPrice = ticketPrice;
        pool.startingJackpot = startingJackpot;
        pool.noWinnerPercent = noWinnerPercent;
        pool.feePercent = feePercent;

        emit PoolCreated({
            poolId: poolId,
            expiry: expiry,
            ticketPrice: ticketPrice,
            startingJackpot: startingJackpot,
            noWinnerPercent: noWinnerPercent,
            feePercent: feePercent
        });
    }

    /// @notice Withdraw fees and send them to the recipient.
    /// @dev Only callable by the owner of the contract.
    /// @param recipient The recipient address.
    /// @param amount The fee amount to withdraw.
    function withdrawFee(address recipient, uint256 amount) external onlyOwner {
        // Update the remaioning fee reserve.
        availableFee -= amount;

        // Send the fee to the recipient.
        recipient.call{value: amount}("");

        emit FeeWithdrawn(recipient, amount);
    }

    /// @notice Withdraw some amount of link tokens and send them to the recipient.
    /// @dev Only callable by the owner of the contract.
    /// @param recipient The recipient address.
    /// @param amount The link amount to withdraw.
    function withdrawLink(
        address recipient,
        uint256 amount
    ) external onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(LINK);
        link.transfer(recipient, amount);

        emit LinkWithdrawn(recipient, amount);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                        PUBLIC FUNCTIONS                                        //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Buy `count` tickets on the given pool.
    /// @dev Reverts if the given price is not correct to buy `count` tickets.
    /// @dev Reverts if the pool cutoff period has been reached.
    /// @param poolId The pool id.
    /// @param count The number of tickets to buy.
    /// @param recipient The recipient address.
    function buyTicketsForPool(
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
            revert IncorrectPrice({
                poolId: poolId,
                price: price,
                given: msg.value
            });
        }

        // Ensure the pool is not in cut off period (and the pool exists).
        uint256 remainingTime = pool.expiry - block.timestamp;
        if (remainingTime < 1 hours) {
            revert CutoffPeriodReached({
                poolId: poolId,
                remainingTime: remainingTime
            });
        }

        // Create the receipt.
        uint256 receiptId = nextReceiptId;
        nextReceiptId += 1;

        receipts[receiptId] = Receipt({
            owner: recipient,
            // UNSAFE: Casting to uint64 is safe because pool ids are only incremented by one.
            poolId: uint64(poolId),
            // NOTE: Compute the ticket id from the deposited amount and ticket price.
            // UNSAFE: Casting to uint128 is safe because depositedAmount / ticketPrice should
            // never be that large.
            ticketId: uint128(pool.depositedAmount / ticketPrice),
            // UNSAFE: Casting to uint64 is safe because ticket price would force the user
            // to post an enormous amount of ETH to overflow.
            count: uint64(count)
        });

        // Update the lottery pool.
        // UNSAFE: Casting to uint96 is safe because in order for it to overflow the user should have
        // given more than 79B ETH as msg.value
        pool.depositedAmount += uint96(price);

        emit TicketsReceiptd({
            poolId: poolId,
            count: count,
            recipient: recipient
        });
    }

    /// @notice Initiate a pool settlement by querying a random number using Chainlink VRFV2.
    /// @dev Reverts if the expiry has not been reached or if the pool has already been settled.
    function intiatePoolSettlement(uint256 poolId) external {
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
        if (pool.settlementStep != PoolSettlementStep.Idle) {
            revert AlreadySettled(poolId);
        }

        // Trigger a Chainlink request to get a random number.
        uint256 requestId = _requestRandomNumber();

        // Link the request id with the pool id and update the pool settlement step.
        vrfRequestToPoolId[requestId] = poolId;
        pool.settlementStep = PoolSettlementStep.Initiated;
    }

    /// @notice Claim the jackpot associated with a winning receipt.
    /// @dev Reverts if the pool has not been settled of if the receipt is not the winning one.
    /// @param receiptId The winning receipt id.
    function claimProfit(uint256 receiptId) external {
        Receipt memory receipt = receipts[receiptId];

        // Ensure it is a winner ticket.
        if (_isWinner(receipt) == false) {
            revert NotWinner({receiptId: receiptId});
        }

        Pool storage pool = pools[receipt.poolId];

        // Compute the jackpot to send to the winner.
        uint256 jackpot = pool.startingJackpot + pool.depositedAmount;
        jackpot -= _feeAmount({feePercent: pool.feePercent, jackpot: jackpot});

        // Delete the pool to prevent replays.
        delete pools[receipt.poolId];

        // Send the jackpot to the user.
        receipt.owner.call{value: jackpot}("");

        emit JackpotClaimed({
            poolId: receipt.poolId,
            winner: receipt.owner,
            receiptId: receiptId,
            jackpot: jackpot
        });
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                        INTERNAL FUNCTIONS                                      //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Settle a given pool using a `random` value.
    /// @dev This registers the winning ticket id from the `random` value.
    /// @dev Only called by the Chainlink VRFV2 callback so the safety checks have already been done.
    /// @param poolId The pool id.
    /// @param random The random value provided by chainlink VRFV2 used to settle.
    function _settlePool(uint256 poolId, uint256 random) internal {
        Pool storage pool = pools[poolId];

        // Avoid multiple SLOADs.
        uint256 depositedAmount = pool.depositedAmount;

        // Compute the number of tickets bought.
        uint256 ticketsCount = depositedAmount / pool.ticketPrice;

        // Inflate the total number of tickets to match with the non-winner percent of the pool.
        uint256 inflatedTicketsCount = ticketsCount *
            (1e4 / (1e4 - pool.noWinnerPercent));

        // Compute the winning ticket id.
        uint256 winningTicketId = random % inflatedTicketsCount;

        // Compute the fee and increase the available fee reserve.
        uint256 fee = _feeAmount({
            feePercent: pool.feePercent,
            jackpot: pool.startingJackpot + depositedAmount
        });
        availableFee += fee;

        // If the winning ticket id exists, register it.
        if (winningTicketId < ticketsCount) {
            // UNSAFE: Casting is safe because there is no chance "inflatedTicketsCount" is above
            // type(uint128).max.
            pool.winningTicketId = uint128(winningTicketId);
        }
        // Else there is no winner so increase the available amount.
        else {
            availableAmount += depositedAmount - fee;
        }

        pool.settlementStep = PoolSettlementStep.Settled;

        emit PoolSettled({
            poolId: poolId,
            winningTicketId: winningTicketId,
            hasWinner: winningTicketId < ticketsCount
        });
    }

    /// @notice Check if the given receipt is winner.
    /// @dev Reverts if the pool has not been settled.
    /// @param receipt The receipt struct.
    function _isWinner(Receipt memory receipt) internal view returns (bool) {
        Pool storage pool = pools[receipt.poolId];

        // Ensure the pool has been settled.
        if (pool.settlementStep != PoolSettlementStep.Settled) {
            revert NotSettled({poolId: receipt.poolId});
        }

        // Avoid multiple SLOADs.
        uint256 winningTicketId = pool.winningTicketId;

        uint256 firstTicketId = receipt.ticketId;
        uint256 lastTicketId = firstTicketId + receipt.count;

        return
            winningTicketId >= firstTicketId && winningTicketId < lastTicketId;
    }

    /// @notice Compute the fee amount associated with a lottery pool.
    /// @param feePercent The fee percent.
    /// @param jackpot The pool jackpot.
    function _feeAmount(
        uint256 feePercent,
        uint256 jackpot
    ) internal pure returns (uint256 feeAmount) {
        feeAmount = (jackpot * feePercent) / 1e4;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                         	 VRFV2 FUNCTIONS                                      //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Request a random number from Chainlink VRFV2.
    /// @return requestId The request id.
    function _requestRandomNumber() internal returns (uint256 requestId) {
        requestId = requestRandomness({
            // UNSAFE: Casting to uint32 is safe because it is never set to an higher value.
            _callbackGasLimit: uint32(vrfCallbackGasLimit),
            // UNSAFE: Casting to uint16 is safe because it is never set to an higher value.
            _requestConfirmations: uint16(vrfRequestConfirmations),
            _numWords: 1
        });
    }

    /// @notice Chainlink VRFV2 callback.
    /// @param requestId The request id.
    /// @param randomWords The generated random numbers.
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        _settlePool({
            poolId: vrfRequestToPoolId[requestId],
            random: randomWords[0]
        });
    }
}
