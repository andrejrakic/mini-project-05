// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC721} from "./vendor/@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "./vendor/@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "./vendor/@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract EnglishAuction is ReentrancyGuard {
  struct AuctionDetails {
    address creator;
    uint48 deadline;
    uint256 reservePrice;
    uint256 highestBid;
    address highestBidder;
  }

  mapping(bytes32 auctionId => AuctionDetails auctionDetails) public s_auctions;
  mapping(bytes32 auctionId => mapping(address bidder => uint256 totalBidForAnAuction)) internal s_bids;

  error EnglishAuction__DeadlineCantBeInPast();
  error EnglishAuction__AuctionAlreadyExists();
  error EnglishAuction__AuctionIsOver();
  error EnglishAuction__MustBidHigherThan(uint256 highestBid);
  error EnglishAuction__AuctionStillInProgress();
  error EnglishAuction__WinnerCantWithdrawBids();
  error EnglishAuction__OnlyAuctionWinnerCanCall();
  error EnglishAuction__OnlySellerCanCall();
  error EnglishAuction__SellerMustEndAuction();
  error EnglishAuction__SellerCanEndAuctionWinnerMustClaimNft();

  event NewAuction(
    bytes32 indexed auctionId,
    address nftCollection,
    uint256 tokenId,
    uint48 deadline,
    uint256 reservePrice
  );
  event NewBid(bytes32 indexed auctionId, uint256 amount);
  event BidsWithdrawn(bytes32 indexed auctionId, address bidder, uint256 withdrawnAmount);
  event AuctionEndedSuccessfully(bytes32 indexed auctionId);
  event AuctionEndedUnsuccessfully(bytes32 indexed auctionId);

  function deposit(
    address _nftCollection,
    uint256 _tokenId,
    uint48 _deadline,
    uint256 _reservePrice
  ) external nonReentrant returns (bytes32 auctionId) {
    auctionId = keccak256(abi.encodePacked(_nftCollection, _tokenId));

    if (s_auctions[auctionId].creator != address(0)) revert EnglishAuction__AuctionAlreadyExists();
    if (block.timestamp > _deadline) revert EnglishAuction__DeadlineCantBeInPast();

    IERC721(_nftCollection).safeTransferFrom(msg.sender, address(0), _tokenId);

    s_auctions[auctionId].creator = msg.sender;
    s_auctions[auctionId].deadline = _deadline;
    s_auctions[auctionId].reservePrice = _reservePrice;

    emit NewAuction(auctionId, _nftCollection, _tokenId, _deadline, _reservePrice);
  }

  function bid(bytes32 _auctionId) external payable nonReentrant {
    AuctionDetails memory auction = s_auctions[_auctionId];

    if (block.timestamp > auction.deadline) revert EnglishAuction__AuctionIsOver();
    if (msg.value <= auction.highestBid) revert EnglishAuction__MustBidHigherThan(auction.highestBid);

    s_auctions[_auctionId].highestBidder = msg.sender;
    s_auctions[_auctionId].highestBid = msg.value;

    s_bids[_auctionId][msg.sender] += msg.value;

    emit NewBid(_auctionId, msg.value);
  }

  function withdrawBid(bytes32 _auctionId) external nonReentrant {
    AuctionDetails memory auction = s_auctions[_auctionId];

    if (auction.deadline <= block.timestamp) revert EnglishAuction__AuctionStillInProgress();
    if (auction.highestBid >= auction.reservePrice) {
      if (msg.sender == auction.highestBidder) revert EnglishAuction__WinnerCantWithdrawBids();
    }

    uint256 amountToWithdraw = s_bids[_auctionId][msg.sender];
    delete s_bids[_auctionId][msg.sender];

    (bool sent, ) = msg.sender.call{value: amountToWithdraw}("");
    require(sent, "Failed to withdraw Ether");

    emit BidsWithdrawn(_auctionId, msg.sender, amountToWithdraw);
  }

  function claimNft(address _nftCollection, uint256 _tokenId) external payable nonReentrant {
    bytes32 auctionId = keccak256(abi.encodePacked(_nftCollection, _tokenId));
    AuctionDetails memory auction = s_auctions[auctionId];

    if (auction.deadline <= block.timestamp) revert EnglishAuction__AuctionStillInProgress();
    if (auction.highestBid < auction.reservePrice) revert EnglishAuction__SellerMustEndAuction();
    if (msg.sender != auction.highestBidder) revert EnglishAuction__OnlyAuctionWinnerCanCall();

    uint256 winnerLeftoverBids = s_bids[auctionId][msg.sender] - auction.highestBid;

    delete s_bids[auctionId][msg.sender];

    IERC721(_nftCollection).safeTransferFrom(address(this), msg.sender, _tokenId);

    (bool firstTxSuccess, ) = auction.creator.call{value: auction.highestBid}("");
    require(firstTxSuccess, "First withdraw failed");

    (bool secondTxSuccess, ) = msg.sender.call{value: winnerLeftoverBids}("");
    require(secondTxSuccess, "Second withdraw failed");

    emit AuctionEndedSuccessfully(auctionId);
  }

  function sellerEndAuction(address _nftCollection, uint256 _tokenId) external nonReentrant {
    bytes32 auctionId = keccak256(abi.encodePacked(_nftCollection, _tokenId));
    AuctionDetails memory auction = s_auctions[auctionId];

    if (msg.sender != auction.creator) revert EnglishAuction__OnlySellerCanCall();
    if (auction.deadline <= block.timestamp) revert EnglishAuction__AuctionStillInProgress();
    if (auction.highestBid >= auction.reservePrice) revert EnglishAuction__SellerCanEndAuctionWinnerMustClaimNft();

    delete s_auctions[auctionId];

    IERC721(_nftCollection).safeTransferFrom(msg.sender, address(0), _tokenId);

    emit AuctionEndedUnsuccessfully(auctionId);
  }

  function getAuctionId(
    address _nftCollection,
    uint256 _tokenId
  ) external view returns (bytes32 auctionId, bool isOnAuction) {
    auctionId = keccak256(abi.encodePacked(_nftCollection, _tokenId));
    isOnAuction = s_auctions[auctionId].creator == address(0);
  }

  function onERC721Received(
    address /*operator*/,
    address /*from*/,
    uint256 /*tokenId*/,
    bytes calldata /*data*/
  ) external pure returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }
}
