// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.8;

// ============ Imports ============

import { ReserveAuctionV3 } from "../reserve-auction-v3/ReserveAuctionV3.sol";
import { SafeMath } from "../node_modules/@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

// ============ Interface declarations ============

// Wrapped Ether
interface IWETH {
  function balanceOf(address src) external view returns (uint256);
  function transferFrom(address src, address dst, uint256 wad) external returns (bool);
}

// ERC721
interface IERC721 {
  function ownerOf(uint256 tokenId) external view returns (address);
}

// @dev: Must use wETH for all outgoing transactions, since returned capital from contract will
//       always be wETH (due to hard 30,000 imposed gas limitation at ETH transfer layer).
contract PartyBid {
  // Use OpenZeppelin library for SafeMath
  using SafeMath for uint256;

  // ============ Immutable storage ============

  // Address of the Reserve Auction contract to place bid on
  address public immutable ReserveAuctionV3Address;
  // Address of the wETH contract
  address public immutable wETHAddress;
  // Address of the NFT contract
  address public immutable NFTAddress;

  // ============ Mutable storage ============

  // ReserveAuctionV3 auctionID to bid on
  uint256 public auctionID;
  // Amount that DAO will bid for on ReserveAuctionV3 item
  uint256 public bidAmount;
  // Current amount raised to bid on ReserveAuctionV3 item
  uint256 public currentRaisedAmount;
  // Maximum time to wait for dao members to fill contract before enabling exit
  uint256 public exitTimeout; 
  // Toggled when DAO places bid to purchase a ReserveAuctionV3 item
  bool public bidPlaced;
  // Stakes of individual dao members
  mapping (address => uint256) public daoStakes;
  // List of NFT auction proposals
  NFTListingProposition[] public NFTListingProposals;

  // ============ Structs ============

  struct NFTListingProposition {
    address proposer;
    uint256 reservePrice;
    uint256 duration;
    uint256 numSupport;
    mapping (address => bool) supporter;
  }

  // ============ Modifiers ============
  
  // Reverts if the DAO has not won the NFT
  modifier onlyIfAuctionWon() {
    // Ensure that owner of NFT(auctionId) is contract address
    require(IERC721(NFTAddress).ownerOf(auctionID) == address(this), "PartyBid: DAO has not won auction.");
    _;
  }

  // ============ Events ============

  // Address of a new DAO member and their entry share
  event PartyJoined(address indexed, uint256 value);
  // Value of newly placed bid on ReserveAuctionV3 item
  event PartyBidPlaced(uint256 auctionID, uint256 value);
  // Address and exit share of DAO member, along with reason for exit
  event PartyMemberExited(address indexed, uint256 value, bool postFailure);

  // ============ Constructor ============

  constructor(
    address _ReserveAuctionV3Address,
    uint256 _auctionID,
    uint256 _bidAmount,
    uint256 _exitTimeout
  ) public {
    // Initialize immutable memory
    ReserveAuctionV3Address = _ReserveAuctionV3Address;
    wETHAddress = ReserveAuctionV3(_ReserveAuctionV3Address).wethAddress();
    NFTAddress = ReserveAuctionV3(_ReserveAuctionV3Address).nftContract();

    // Initialize mutable memory
    auctionID = _auctionID;
    bidAmount = _bidAmount;
    currentRaisedAmount = 0;
    exitTimeout = _exitTimeout;
    bidPlaced = false;
  }

  // ============ Join the DAO ============

  /**
   * Join the DAO by sending ETH
   * Requires bidding to be enabled, forced matching of deposit value to sent eth, and there to be capacity in DAO
   */
  function join(uint256 _value) external payable {
    // Dont allow joining once the bid has already been placed
    require(bidPlaced == false, "PartyBid: Cannot join since bid has been placed.");
    // Ensure matching of deposited value to ETH sent to contract
    require(msg.value == _value, "PartyBid: Deposit amount does not match spent ETH.");
    // Ensure sum(eth sent, current raised) <= required bid amount
    require(_value.add(currentRaisedAmount) <= bidAmount, "PartyBid: DAO does not have capacity.");

    currentRaisedAmount = currentRaisedAmount.add(_value); // Increment raised amount
    daoStakes[msg.sender] = daoStakes[msg.sender].add(_value); // Track DAO member contribution

    emit PartyJoined(msg.sender, _value); // Emit new DAO member
  }

  // ============ Place a bid from DAO ============

  /**
   * Execute bid placement, as DAO member, so long as required conditions are met
   */
  function placeBid() external {
    // Dont allow placing a bid if already placed
    require(bidPlaced == false, "PartyBid: Bid has already been placed.");
    // Ensure that required bidAmount is matched with currently raised amount
    require(bidAmount == currentRaisedAmount, "PartyBid: Insufficient raised capital to place bid.");
    // Ensure that caller is a DAO member
    require(daoStakes[msg.sender] > 0, "PartyBid: Must be DAO member to initiate placing bid.");

    // Setup auction contract, place bid, toggle bidding status
    ReserveAuctionV3 auction_contract = ReserveAuctionV3(ReserveAuctionV3Address);
    auction_contract.createBid{value: bidAmount}(auctionID, bidAmount);
    bidPlaced = true;

    emit PartyBidPlaced(auctionID, bidAmount); // Emit bid placed
  }

  // ============ ReserveAuctionV3 NFT re-auctioning ============

  /**
   * Returns boolean status of if DAO has won NFT
   */
  function NFTWon() public view returns (bool) {
    // Check if owner of NFT(auctionID) is contract address
    return IERC721(NFTAddress).ownerOf(auctionID) == address(this);
  }
  
  function NFTProposeAuctionListing(uint256 _reservePrice, uint256 duration) external onlyIfAuctionWon() returns (uint256) {
    // Ensure that caller is a DAO member
    require(daoStakes[msg.sender] > 0, "PartyBid: Must be a DAO member to propose NFT auction listing.");

    // Collect proposalId based on num(proposals)
    uint256 proposalId = NFTListingProposals.length;

    // Append new proposal and begin with min. voting weight of proposer
    NFTListingProposals[proposalId].push(
      msg.sender,
      _reservePrice,
      duration,
      daoStakes[msg.sender]
    );

    // Toggle support of proposal
    NFTListingProposals[proposalId].supporter[msg.sender] = true;

    return proposalId; // Return proposalId
  }

  function NFTVoteForProposedAuctionListing(uint256 _proposalId) external onlyIfAuctionWon() {
    // Ensure that caller is a DAO member
    require(daoStakes[msg.sender] > 0, "PartyBid: Must be a DAO member to propose NFT auction listing.");
    // Ensure that DAO member has not already voted in favor of proposal
    require(NFTListingProposals[_proposalId].supporter[msg.sender] != true, "PartyBid: You have already supported this proposal.");

    NFTListingProposals[_proposalId].numSupport = NFTListingProposals[_proposalId].numSupport.add(daoStakes[msg.sender]);
    NFTListingProposals[_proposalId].supporter[msg.sender] = true;
  }

  function NFTListForAuction(uint256 _proposalId) external onlyIfAuctionWon() {
    // Ensure that caller is a DAO member
    require(daoStakes[msg.sender] > 0, "PartyBid: Must be a DAO member to propose NFT auction listing.");
    // Ensure that majority have voted in favor of proposal
    require(NFTListingProposals[_proposalId].numSupport > bidAmount.div(2), "PartyBid: Missing majority to execute auction proposal.");

    // TODO: list NFT
    // TODO: nullify proposals
  }

  // ============ Exit the DAO ============
  
  /**
   * Exit DAO if bid was beaten
   * @dev Capital returned in form of wETH due to 30,000 gas transfer limit imposed by ReserveAuctionV3
   */
  function _exitIfBidFailed() internal {
    // Dont allow exiting via this function if bid hasn't been placed
    require(bidPlaced == true, "PartyBid: Bid must be placed to exit via failure.");
    // Ensure that contract wETH balance is > 0 (implying that either funds have been returned or wETH airdropped)
    require(IWETH(wETHAddress).balanceOf(address(this)) > 0, "PartyBid: DAO bid has not been beaten or refunded yet.");

    // Transfer wETH from contract to DAO member and emit event
    IWETH(wETHAddress).transferFrom(address(this), msg.sender, daoStakes[msg.sender]);
    emit PartyMemberExited(msg.sender, daoStakes[msg.sender], true);

    // Nullify member DAO share
    daoStakes[msg.sender] = 0;
  }

  /**
   * Exit DAO if deposit timeout has passed
   */
  function _exitIfTimeoutPassed() internal {
    // Dont allow exiting via this function if bid has been placed
    require(bidPlaced == false, "PartyBid: Bid must be pending to exit via timeout.");
    // Ensure that current time > deposit timeout
    require(block.timestamp >= exitTimeout, "PartyBid: Exit timeout not met.");

    // Transfer ETH from contract to DAO member and emit event
    payable(msg.sender).transfer(daoStakes[msg.sender]);
    emit PartyMemberExited(msg.sender, daoStakes[msg.sender], false);

    // Nullify member DAO share
    daoStakes[msg.sender] = 0;
  }

  /**
   * Public utility function to call internal exit functions based on bid state
   */
   // TODO: Add exit functionality post-won-NFT sale
  function exit() external payable {
    // Ensure that caller is a DAO member
    require(daoStakes[msg.sender] > 0, "PartyBid: Must first be a DAO member to exit DAO.");

    if (bidPlaced) {
      // If bid has been placed, allow exit on bid failure
      _exitIfBidFailed();
    } else {
      // Else, allow exit when exit timeout window has passed
      _exitIfTimeoutPassed();
    }
  }
}