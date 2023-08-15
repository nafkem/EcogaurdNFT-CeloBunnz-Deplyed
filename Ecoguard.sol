// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./libraries/ReentrancyGuard.sol";
import "./libraries/Pausable.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";

contract Ecoguard is ReentrancyGuard, Pausable {
    uint256 id = 0;

    address private ecoguardWallet;
    address public cusdAddress;
    address public owner;
    uint256 private constant PLATFORM_FEE_PERCENT = 5; // Updated to 5%

    struct NFT {
        uint256 listingId;
        uint256 tokenId;
        address creator;
        address assetAddress;
        address seller;
        uint256 price;
        uint256 listingEndTime;
        address highestBidder;
        uint256 highestBid;
        bool available;
        string tokenURI;
        address conservationProject;

    }

    mapping(uint256 => NFT) public nfts;
    mapping(uint256 => mapping(address => bool)) listed;

    event NFTPurchased(uint256 tokenId, address indexed buyer, address indexed seller, uint256 price);
    event AuctionStarted(uint256 tokenId, uint256 startingPrice, uint256 auctionEndTime);
    event ListingSuccessfull(uint256 tokenId, uint256 startingPrice, uint256 listingEndTime);
    event BidPlaced(uint256 tokenId, address indexed bidder, uint256 bidAmount);
    event AuctionFinalized(uint256 tokenId, address indexed winner, uint256 winningBid);
    event ConservationDonation(uint256 tokenId, address indexed donor, uint256 donationAmount);

    constructor(address _ecoguardWallet, address paymentAddress) {
        ecoguardWallet = _ecoguardWallet;
        cusdAddress = paymentAddress;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    function createListing(
        uint256 tokenId,
        address _assetAddress,
        uint256 price,
        uint256 auctionDuration, 
        address conservationProject
    ) external {
        NFT storage nft = nfts[id];
        require(listed[tokenId][_assetAddress] == false, "NFT already listed");
        require(nft.available == false, "NFT Listed Already");
        require(auctionDuration > 0 && price > 0, "invalid end time");
        IERC721(_assetAddress).transferFrom(msg.sender, address(this), tokenId);
        nft.tokenId = tokenId;
        nft.available = true;
        nft.price = price * (10**18);
        nft.listingEndTime = block.timestamp + auctionDuration;
        nft.conservationProject = conservationProject;
        nft.seller = msg.sender;
        nft.assetAddress = _assetAddress;
        nft.listingId = id;

        id++;
        listed[tokenId][_assetAddress] = true;

        emit ListingSuccessfull(tokenId, price, nft.listingEndTime);
    }

    function purchaseNFT(uint256 _listingId, uint256 amount) external payable nonReentrant {
        NFT storage nft = nfts[_listingId];
        require(nft.available == true, "NFT is not available for purchase");
        require(IERC20(cusdAddress).balanceOf(msg.sender) >= nft.price, "Insufficient payment");
        nft.available = false;

        uint256 platformFee = (amount * PLATFORM_FEE_PERCENT) / 100;
        uint256 amountAfterPlatformFee = amount -platformFee;

        IERC20(cusdAddress).transferFrom(msg.sender, address(this), nft.price);

        IERC20(cusdAddress).transfer(nft.seller, amountAfterPlatformFee);

        IERC721(nft.assetAddress).transferFrom(address(this), msg.sender, nft.tokenId);

        emit NFTPurchased(_listingId, msg.sender, nft.seller, nft.price);
    }



    function setPrice(uint256 _listingId, uint256 newPrice) external {
        NFT storage nft = nfts[_listingId];
        require(nft.available == true || nft.highestBid == 0, "NFT is not available");
        require(msg.sender == nft.creator, "Not authorized");
        require(newPrice > 0, "Price must be greater than zero");

        nft.price = newPrice;
    }

    function startAuction(uint256 tokenId, uint256 _buyOutPrice, uint256 auctionDuration, address _assetAddress) external {
        require(listed[tokenId][_assetAddress] == false, "NFT already listed");
        NFT storage nft = nfts[id];
        uint256 buyoutPrice = _buyOutPrice * (10**18);
        require(nft.available != true, "NFT already auction");

        IERC721(_assetAddress).transferFrom(msg.sender, address(this), tokenId);
        nft.tokenId = tokenId;
        nft.creator = msg.sender;
        nft.price = buyoutPrice;
        nft.listingEndTime = block.timestamp + auctionDuration;
        nft.available = true;
        nft.listingId = id;
        nft.assetAddress = _assetAddress;

        id++;
        
        listed[tokenId][_assetAddress] = true;

        emit AuctionStarted(tokenId, buyoutPrice, nft.listingEndTime);
    }

    function placeBid(uint256 _listingId, uint256 amount) external payable nonReentrant {
        NFT storage nft = nfts[_listingId];
        uint256 bidAmount = amount *(10**18);
        address previousBidder = nft.highestBidder;
        require(nft.available == true, "NFT not in auction");
        require(block.timestamp < nft.listingEndTime, "Auction has ended");
        require(IERC20(cusdAddress).balanceOf(msg.sender) > nft.highestBid, "Bid must be higher than the current highest bid");

        if(previousBidder != address(0)){
            IERC20(cusdAddress).transfer(previousBidder, nft.highestBid);
        }

        if(bidAmount >= nft.price){
            IERC20(cusdAddress).transferFrom(msg.sender, address(this), bidAmount);
            nft.available = false;
            nft.highestBidder = msg.sender;
            nft.highestBid = bidAmount;
        } else{
            IERC20(cusdAddress).transferFrom(msg.sender, address(this), bidAmount);
            nft.highestBidder = msg.sender;
            nft.highestBid = bidAmount;
        }

        emit BidPlaced(_listingId, msg.sender, msg.value);
    }

    function finalizeAuction(uint256 _listingId) external nonReentrant {
        NFT storage nft = nfts[_listingId];
        require(!nft.available || block.timestamp >= nft.listingEndTime, "Auction Active");

        require(msg.sender == nft.highestBidder || msg.sender == nft.creator, "Not authorized");

        address winner = nft.highestBidder;
        uint256 winningBid = nft.highestBid;

        uint256 platformFee = (winningBid * PLATFORM_FEE_PERCENT) / 100;
        uint256 amountAfterPlatformFee = winningBid - platformFee;

        IERC20(cusdAddress).transfer(nft.creator, amountAfterPlatformFee);
        IERC721(nft.assetAddress).transferFrom(address(this), winner, nft.tokenId);

        nft.available = false;

        emit AuctionFinalized(_listingId, winner, winningBid);
    }

    function withdrawNFT(uint256 _listingId) external {
        NFT storage nft = nfts[_listingId];
        require(msg.sender == nft.creator, "not authorized");
        require(nft.highestBid == 0, "bid exist");
        //require(nft.listingEndTime < block.timestamp, "nft is still active");

        IERC721(nft.assetAddress).transferFrom(address(this), nft.creator, nft.tokenId);

        nft.available = false;

    }

    function setPlatformWallet(address newWallet) external onlyOwner {
        ecoguardWallet = newWallet;
    }

    function setConservationProject(uint256 _listingId, address newConservationProject) external{
        require(msg.sender == nfts[_listingId].creator, "Not authorized");
        require(newConservationProject != address(0), "Conservation project address cannot be 0");
        nfts[_listingId].conservationProject = newConservationProject;
    }

    function donateToProject(uint256 _listingId, uint256 amount) external payable nonReentrant whenNotPaused {
        NFT storage nft = nfts[_listingId];
        uint256 donatedAmount = amount *10E18;
        require(donatedAmount > 0, "Donation amount must be greater than zero");
        require(nft.conservationProject != address(0), "No conservation project set");

        IERC20(cusdAddress).transferFrom(msg.sender, nft.conservationProject , donatedAmount);

        emit ConservationDonation(_listingId, msg.sender, amount);
    }

    function pauseContract() external onlyOwner {
        _pause();
    }

    function unpauseContract() external onlyOwner {
        _unpause();
    }

    function withdrawPlatformFee() external onlyOwner{
        uint256 balance = IERC20(cusdAddress).balanceOf(address(this));

        IERC20(cusdAddress).transferFrom(address(this), ecoguardWallet, balance);

    }

}
