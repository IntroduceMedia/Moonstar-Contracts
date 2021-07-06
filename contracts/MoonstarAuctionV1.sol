// Moonstar Auction Contract V1
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./IBEP20.sol";

interface IMoonstarNFT {
	function initialize(address creator) external;
	function safeTransferFrom(address from,
			address to,
			uint256 id,
			bytes calldata data) external;
    function creatorOf(uint256 _tokenId) external view returns (address);
	function royalties(uint256 _tokenId) external view returns (uint256);        
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint wad) external;

    function transfer(address to, uint256 value) external returns (bool);
}

contract MoonstarAuctionV1 is UUPSUpgradeable, ERC721HolderUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 constant public PERCENTS_DIVIDER = 1000;
	uint256 constant public FEE_MAX_PERCENT = 300;
    uint256 constant public MIN_BID_INCREMENT_PERCENT = 100; // 10%

    EnumerableSet.AddressSet private _supportedTokens; //payment token (ERC20), MST
    // The address of the WBNB contract, so that BNB can be transferred via
    // WBNB if native BNB transfers fail.
    address public WBNBAddress;

    uint256 public tradingFee;  // swap fee as percent - percent divider = 1000
	address public feeAddress; 


    // Bid struct to hold bidder and amount
    struct Bid {
        address payable from;
        uint256 amount;
    }

    // Auction struct which holds all the required info
    struct Auction {
        address collectionId;
        uint256 tokenId;
        bool isUnlimitied;
        uint256 endTime;
        uint256 startPrice;
        address currency;
        address owner;
        bool active;
        bool finalized;
    }

    // Array with all auctions
    Auction[] public auctions;
    
    // Mapping from auction index to user bids
    mapping (uint256 => Bid[]) public auctionBids;
    
    // Mapping from owner to a list of owned auctions
    mapping (address => uint[]) public ownedAuctions;
    
    event BidSuccess(address _from, uint _auctionId);

    // AuctionCreated is fired when an auction is created
    event AuctionCreated(address _owner, uint _auctionId);

    // AuctionCanceled is fired when an auction is canceled
    event AuctionCanceled(address _owner, uint _auctionId);

    // AuctionFinalized is fired when an auction is finalized
    event AuctionFinalized(address _owner, uint _auctionId);
   
    function initialize(address _paymenToken, address _feeAddress) public initializer {
		__Ownable_init();
	
        _supportedTokens.add(address(0x0)); // BNB Support
        _supportedTokens.add(_paymenToken);

        feeAddress = _feeAddress;
        WBNBAddress = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    }

	function _authorizeUpgrade(address newImplementation) internal override {}

    function addSupportedToken(address _address) external onlyOwner {
		_supportedTokens.add(_address);
    }

    function isSupportedToken(address _address) public view returns (bool) {
        return _supportedTokens.contains(_address);
    }

    function removeSupportedToken(address _address) external onlyOwner {
        _supportedTokens.remove(_address);
    }

    function supportedTokenAt(uint index) public view returns(address) {
        return _supportedTokens.at(index);
    }

    function supportedTokensLength() public view returns(uint) {
        return _supportedTokens.length();
    }

    function setFeeAddress(address _address) external onlyOwner {
		require(_address != address(0x0), "invalid address");
        feeAddress = _address;
    }

	function setTradingFeePercent(uint256 _percent) external onlyOwner {
		require(_percent < FEE_MAX_PERCENT, "too big trading fee");
		tradingFee = _percent;
	}

    /*
     * @dev Creates an auction with the given informatin
     * @param _tokenRepositoryAddress address of the TokenRepository contract
     * @param _tokenId uint256 of the deed registered in DeedRepository
     * @param _startPrice uint256 starting price of the auction
     * @return bool whether the auction is created
     */
    function createAuction(
        address _collectionId, 
        uint256 _tokenId,
        address _currency, 
        uint256 _startPrice, 
        uint256 _endTime,
        bool _isUnlimited
        ) 
        public onlyTokenOwner(_collectionId, _tokenId) returns(bool) {
        require(isSupportedToken(_currency), "unsupported currency");

        uint auctionId = auctions.length;
        Auction memory newAuction;
        newAuction.collectionId = _collectionId;
        newAuction.tokenId = _tokenId;
        newAuction.startPrice = _startPrice;
        newAuction.currency = _currency;
        newAuction.endTime = _endTime;
        newAuction.isUnlimitied = _isUnlimited;
        newAuction.owner = msg.sender;
        newAuction.active = true;
        newAuction.finalized = false;
        
        auctions.push(newAuction);        
        ownedAuctions[msg.sender].push(auctionId);
        
        emit AuctionCreated(msg.sender, auctionId);
        return true;
    }
    
    function approveAndTransfer(address _from, address _to, address _collectionId, uint256 _tokenId) internal returns(bool) {
        IERC721 token = IERC721(_collectionId);
        token.approve(_to, _tokenId);
        token.transferFrom(_from, _to, _tokenId);
        return true;
    }

    function _safeTransferBNB(address to, uint256 value) internal returns(bool) {
		(bool success, ) = to.call{value: value}(new bytes(0));
		if(!success) {
			IWETH(WBNBAddress).deposit{value: value}();
			return IWETH(WBNBAddress).transfer(to, value);
		}
		return success;
        
    }
    
    /**
     * @dev Cancels an ongoing auction by the owner
     * @dev Deed is transfered back to the auction owner
     * @dev Bidder is refunded with the initial amount
     * @param _auctionId uint ID of the created auction
     */
    function cancelAuction(uint _auctionId) public onlyAuctionOwner(_auctionId) nonReentrant {
        Auction memory myAuction = auctions[_auctionId];
        uint bidsLength = auctionBids[_auctionId].length;

        require(bidsLength == 0, "bid already started");

        // approve and transfer from this contract to auction owner
        if(approveAndTransfer(address(this), myAuction.owner, myAuction.collectionId, myAuction.tokenId)){
            auctions[_auctionId].active = false;
            emit AuctionCanceled(msg.sender, _auctionId);
        }
    }
    
    /**
     * @dev Finalized an ended auction
     * @dev The auction should be ended, and there should be at least one bid
     * @dev On success Deed is transfered to bidder and auction owner gets the amount
     * @param _auctionId uint ID of the created auction
     */
    function finalizeAuction(uint _auctionId) public {
        Auction memory myAuction = auctions[_auctionId];
        uint bidsLength = auctionBids[_auctionId].length;

        // 1. if auction not ended just revert
        require(!myAuction.isUnlimitied && block.timestamp >= myAuction.endTime, "auction is not ended");
        require(msg.sender == myAuction.owner || msg.sender == owner(), "only auction owner can finalize");
        
        // if there are no bids cancel
        if(bidsLength == 0) {
            cancelAuction(_auctionId);
        }else{
            // 2. the money goes to the auction owner
            Bid memory lastBid = auctionBids[_auctionId][bidsLength - 1];
            address _creator = IMoonstarNFT(myAuction.collectionId).creatorOf(myAuction.tokenId);
            uint256 royalties = IMoonstarNFT(myAuction.collectionId).royalties(myAuction.tokenId);
            // % commission cut
            uint256 _commissionValue = lastBid.amount.mul(tradingFee).div(PERCENTS_DIVIDER);
            uint256 _royalties = (lastBid.amount.sub(_commissionValue)).mul(royalties).div(PERCENTS_DIVIDER);
            uint256 _sellerValue = lastBid.amount.sub(_commissionValue).sub(_royalties);
            
            if(isBNBAuction(_auctionId)) {
                require(_safeTransferBNB(myAuction.owner, _sellerValue), "transfer to seller failed");
                if(_commissionValue > 0) _safeTransferBNB(feeAddress, _commissionValue);
                if(_royalties > 0) _safeTransferBNB(_creator, _royalties);
            }
            else {
                require(IERC20(myAuction.currency).transfer(myAuction.owner, _sellerValue), "transfer to seller failed");
                if(_commissionValue > 0) require(IBEP20(myAuction.currency).transfer(feeAddress, _commissionValue));
                if(_royalties > 0) require(IBEP20(myAuction.currency).transfer(_creator, _royalties));
            }

            // approve and transfer from this contract to the bid winner 
            if(approveAndTransfer(address(this), lastBid.from, myAuction.collectionId, myAuction.tokenId)){
                auctions[_auctionId].active = false;
                auctions[_auctionId].finalized = true;
                emit AuctionFinalized(msg.sender, _auctionId);
            }
        }
    }
    
    /**
     * @dev Bidder sends bid on an auction
     * @dev Auction should be active and not ended
     * @dev Refund previous bidder if a new bid is valid and placed.
     * @param _auctionId uint ID of the created auction
     */
    function bidOnAuction(uint256 _auctionId, uint256 amount) public payable {
        // owner can't bid on their auctions
        Auction memory myAuction = auctions[_auctionId];
        require(myAuction.owner != msg.sender, "owner can not bid");

        // if auction is expired
        require(myAuction.isUnlimitied || block.timestamp < myAuction.endTime, "auction is over");

        uint bidsLength = auctionBids[_auctionId].length;
        uint256 tempAmount = myAuction.startPrice;
        Bid memory lastBid;

        // there are previous bids
        if( bidsLength > 0 ) {
            lastBid = auctionBids[_auctionId][bidsLength - 1];
            tempAmount = lastBid.amount;
        }
        tempAmount = tempAmount.mul(PERCENTS_DIVIDER + MIN_BID_INCREMENT_PERCENT).div(PERCENTS_DIVIDER);

        // check if amound is greater than previous amount  
        if(isBNBAuction(_auctionId)) {
            require(msg.value >= tempAmount, "too small amount");
        } else {
            require(amount >= tempAmount, "too small amount");
            require(IERC20(myAuction.currency).transferFrom(msg.sender, address(this), amount), "transfe to contract failed");
        }
        

        // refund the last bidder
        if( bidsLength > 0 ) {
            if(isBNBAuction(_auctionId)) {
                require(_safeTransferBNB(lastBid.from, lastBid.amount), "refund to last bidder failed");
            }
            else {
                require(IERC20(myAuction.currency).transfer(lastBid.from, lastBid.amount), "refund to last bidder failed");
            }
        }

        // insert bid 
        Bid memory newBid;
        newBid.from = payable(msg.sender);
        newBid.amount = isBNBAuction(_auctionId) ? msg.value : amount;
        auctionBids[_auctionId].push(newBid);
        emit BidSuccess(msg.sender, _auctionId);
    }

    /**
     * @dev Gets the length of auctions
     * @return uint representing the auction count
     */
    function getAuctionsLength() public view returns(uint) {
        return auctions.length;
    }
    
    /**
     * @dev Gets the bid counts of a given auction
     * @param _auctionId uint ID of the auction
     */
    function getBidsAmount(uint _auctionId) public view returns(uint) {
        return auctionBids[_auctionId].length;
    } 
    
    /**
     * @dev Gets an array of owned auctions
     * @param _owner address of the auction owner
     */
    function getOwnedAuctions(address _owner) public view returns(uint[] memory) {
        uint[] memory ownedAllAuctions = ownedAuctions[_owner];
        return ownedAllAuctions;
    }
    
    /**
     * @dev Gets an array of owned auctions
     * @param _auctionId uint of the auction owner
     * @return amount uint256, address of last bidder
     */
    function getCurrentBids(uint _auctionId) public view returns(uint256, address) {
        uint bidsLength = auctionBids[_auctionId].length;
        // if there are bids refund the last bid
        if (bidsLength >= 0) {
            Bid memory lastBid = auctionBids[_auctionId][bidsLength - 1];
            return (lastBid.amount, lastBid.from);
        }    
        return (0, address(0));
    }
    
    /**
     * @dev Gets the total number of auctions owned by an address
     * @param _owner address of the owner
     * @return uint total number of auctions
     */
    function getAuctionsAmount(address _owner) public view returns(uint) {
        return ownedAuctions[_owner].length;
    }

    function isBNBAuction(uint _auctionId) public view returns (bool) {
        return auctions[_auctionId].currency == address(0x0);
    }

    receive() external payable {}

    modifier onlyAuctionOwner(uint _auctionId) {
        require(auctions[_auctionId].owner == msg.sender);
        _;
    }

    modifier onlyTokenOwner(address _collectionId, uint256 _tokenId) {
        address tokenOwner = IERC721(_collectionId).ownerOf(_tokenId);
        require(tokenOwner == address(this));
        _;
    }
}