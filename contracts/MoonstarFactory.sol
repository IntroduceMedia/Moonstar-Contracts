// Moonstar NFT Factory
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./MoonstarNFT.sol";
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


contract MoonstarFactory is UUPSUpgradeable, ERC721HolderUpgradeable, OwnableUpgradeable {
    using SafeMath for uint256;

    uint256 constant public PERCENTS_DIVIDER = 1000;
	uint256 constant public FEE_MAX_PERCENT = 300;

    address public  paymentTokenAddress; //payment token (ERC20), MST
    // The address of the WBNB contract, so that BNB can be transferred via
    // WBNB if native BNB transfers fail.
    address public WBNBAddress;

    uint256 public tradingFee;  // swap fee as percent - percent divider = 1000
	address public feeAddress; 


     /* Pairs to swap NFT _id => price */
	struct Item {
		address collection;
		uint256 token_id;
		address creator;
		address owner;
		uint256 price;
		bool currency;
		uint256 royalties;
		bool bValid;
	}

    address[] public collections;
	// collection address => creator address
	mapping(address => address) public collectionCreators;
	// token id => Item mapping
    mapping(bytes32 => Item) public items;

    event CollectionCreated(address collection_address, address owner, string name, string symbol);
    event Listed(bytes32 key, address collection, uint256 token_id, uint256 price, bool currency, address creator, address owner, uint256 royalties);
    event Purchase(address indexed previousOwner, address indexed newOwner, bytes32 key, address collection, uint256 token_id);
    event PriceUpdate(address indexed owner, uint256 oldPrice, uint256 newPrice, bytes32 key, address collection, uint256 token_id);
    event Delisted(address indexed owner, uint256 token_id, address collection, bytes32 key);
   
    function initialize(address _paymenToken, address _feeAddress) public initializer {
		__Ownable_init();
	
        paymentTokenAddress = _paymenToken;
        feeAddress = _feeAddress;
        WBNBAddress = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

        tradingFee = 25;
        
		createCollection("MoonstarNFT", "MOONNFT");
    }

	function _authorizeUpgrade(address newImplementation) internal override {}
    

    function setPaymentToken(address _address) external onlyOwner {
        require(_address != address(0x0), "invalid address");
		paymentTokenAddress = _address;
    }

    function setFeeAddress(address _address) external onlyOwner {
		require(_address != address(0x0), "invalid address");
        feeAddress = _address;
    }

	function setTradingFeePercent(uint256 _percent) external onlyOwner {
		require(_percent < FEE_MAX_PERCENT, "too big trading fee");
		tradingFee = _percent;
	}

    function createCollection(string memory _name, string memory _symbol) public returns(address collection) {
		bytes memory creationCode = type(MoonstarNFT).creationCode;
        bytes memory byteCode = abi.encodePacked(creationCode, abi.encode(_name, _symbol));

        bytes32 salt = keccak256(abi.encodePacked(_name, _symbol, block.timestamp));
        assembly {
            collection := create2(0, add(byteCode, 32), mload(byteCode), salt)
        }
        IMoonstarNFT(collection).initialize(msg.sender);
		collections.push(collection);
		collectionCreators[collection] = msg.sender;

		emit CollectionCreated(collection, msg.sender, _name, _symbol);
	}

    function list(address _collection, uint256 _token_id, bool _currency,  uint256 _price) public {
        require(_price > 0, "invalid price");
		
        bytes32 key = itemKeyFromId(_collection, _token_id);
        require(!items[key].bValid, "already exist");

        IMoonstarNFT(_collection).safeTransferFrom(msg.sender, address(this), _token_id, "List");

        address creator = IMoonstarNFT(_collection).creatorOf(_token_id);
        uint256 royalties = IMoonstarNFT(_collection).royalties(_token_id);

        items[key].collection = _collection;
        items[key].token_id = _token_id;
        items[key].creator = creator;
        items[key].owner = msg.sender;
        items[key].price = _price;
        items[key].currency = _currency;
        items[key].royalties = royalties;
        items[key].bValid = true;

        emit Listed(key, _collection, _token_id, _price, _currency, creator, msg.sender, royalties);
    }

    function delist(address _collection, uint256 _token_id) public returns (bool) {
        bytes32 key = itemKeyFromId(_collection, _token_id);
        require(items[key].bValid, "not exist");

        require(msg.sender == items[key].owner || msg.sender == owner(), "Error, you are not the owner");

        IMoonstarNFT(_collection).safeTransferFrom(address(this), msg.sender, _token_id, "DeList");
        
        items[key].bValid = false;

        emit Delisted(items[key].owner, _token_id, _collection, key);
        return true;
    }

    function buy(address _collection, uint256 _token_id) external payable {
        bytes32 _key = itemKeyFromId(_collection, _token_id);
        require(items[_key].bValid, "invalid pair");

        Item storage item = items[_key];
        address _previousOwner = item.owner;
        address _creator = item.creator;
        address _newOwner = msg.sender;

        // % commission cut
        uint256 _commissionValue = item.price.mul(tradingFee).div(PERCENTS_DIVIDER);
        uint256 _royalties = (item.price.sub(_commissionValue)).mul(item.royalties).div(PERCENTS_DIVIDER);
        uint256 _sellerValue = item.price.sub(_commissionValue).sub(_royalties);

        if (item.currency) {
            transferBNBOrWBNB(_previousOwner, _sellerValue);
            if(_commissionValue > 0) transferBNBOrWBNB(feeAddress, _commissionValue);
            if(_royalties > 0) transferBNBOrWBNB(_creator, _royalties);
        } else {
            require(IBEP20(paymentTokenAddress).transferFrom(_newOwner, _previousOwner, _sellerValue));
            if(_commissionValue > 0) require(IBEP20(paymentTokenAddress).transferFrom(_newOwner, feeAddress, _commissionValue));
            if(_royalties > 0) require(IBEP20(paymentTokenAddress).transferFrom(_newOwner, _creator, _royalties));
        }

        IMoonstarNFT(item.collection).safeTransferFrom(_previousOwner, _newOwner, item.token_id, "Purchase Item");
        
        item.bValid = false;

        emit Purchase(_previousOwner, _newOwner, _key, item.collection, item.token_id);
    }
    
    function updatePrice(address _collection, uint256 _token_id, uint256 _price) public returns (bool) {
        bytes32 _key = itemKeyFromId(_collection, _token_id);
        Item storage item = items[_key];

        require(item.bValid, "invalid Item");
        require(msg.sender == item.owner, "Error, you are not the owner");

        uint256 oldPrice = item.price;
        item.price = _price;

        emit PriceUpdate(msg.sender, oldPrice, _price, _key, _collection, _token_id);
        return true;
    }

    function itemKeyFromId(address _collection, uint256 _token_id) public pure returns (bytes32) {
        return keccak256(abi.encode(_collection, _token_id));
    }

    // Will attempt to transfer BNB, but will transfer WBNB instead if it fails.
    function transferBNBOrWBNB(address to, uint256 value) private {
        // Try to transfer BNB to the given recipient.
        if (!attemptBNBTransfer(to, value)) {
            // If the transfer fails, wrap and send as WBNB, so that
            // the auction is not impeded and the recipient still
            // can claim BNB via the WBNB contract (similar to escrow).
            IWBNB(WBNBAddress).deposit{value: value}();
            IWBNB(WBNBAddress).transfer(to, value);
            // At this point, the recipient can unwrap WBNB.
        }
    }

    // Sending BNB is not guaranteed complete, and the mBNBod used here will return false if
    // it fails. For example, a contract can block BNB transfer, or might use
    // an excessive amount of gas, thereby griefing a new bidder.
    // We should limit the gas used in transfers, and handle failure cases.
    function attemptBNBTransfer(address to, uint256 value)
        private
        returns (bool)
    {
        // Here increase the gas limit a reasonable amount above the default, and try
        // to send BNB to the recipient.
        // NOTE: This might allow the recipient to attempt a limited reentrancy attack.
        (bool success, ) = to.call{value: value, gas: 30000}("");
        return success;
    }
    receive() external payable {}
}