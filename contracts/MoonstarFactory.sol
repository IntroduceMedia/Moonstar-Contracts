// Moonstar NFT Factory
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
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

interface IWETH {
    function deposit() external payable;
    function withdraw(uint wad) external;

    function transfer(address to, uint256 value) external returns (bool);
}

contract MoonstarFactory is UUPSUpgradeable, ERC721HolderUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 constant public PERCENTS_DIVIDER = 1000;
	uint256 constant public FEE_MAX_PERCENT = 300;

    EnumerableSet.AddressSet private _supportedTokens; //payment token (ERC20), MST
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
		address currency;
		uint256 royalties;
		bool bValid;
	}

    address[] public collections;
	// collection address => creator address
	mapping(address => address) public collectionCreators;
	// token id => Item mapping
    mapping(bytes32 => Item) public items;

    event CollectionCreated(address collection_address, address owner, string name, string symbol);
    event Listed(bytes32 key, address collection, uint256 token_id, uint256 price, address currency, address creator, address owner, uint256 royalties);
    event Purchase(address indexed previousOwner, address indexed newOwner, bytes32 key, address collection, uint256 token_id);
    event PriceUpdate(address indexed owner, uint256 oldPrice, uint256 newPrice, address currency, bytes32 key, address collection, uint256 token_id);
    event Delisted(address indexed owner, uint256 token_id, address collection, bytes32 key);
   
    function initialize(address _paymenToken, address _feeAddress) public initializer {
		__Ownable_init();
	
        _supportedTokens.add(address(0x0)); // BNB Support
        _supportedTokens.add(_paymenToken);

        feeAddress = _feeAddress;
        WBNBAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

        tradingFee = 25;
        
		createCollection("MoonstarNFT", "MOONNFT");
    }

	function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    

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

    function list(address _collection, address owner, uint256 _token_id, address _currency,  uint256 _price) public {
        require(_price > 0, "invalid price");
        require(isSupportedToken(_currency), "unsupported currency");
		
        bytes32 key = itemKeyFromId(_collection, _token_id);
        require(!items[key].bValid, "already exist");

        IMoonstarNFT(_collection).safeTransferFrom(owner, address(this), _token_id, "List");

        address creator = IMoonstarNFT(_collection).creatorOf(_token_id);
        uint256 royalties = IMoonstarNFT(_collection).royalties(_token_id);

        items[key].collection = _collection;
        items[key].token_id = _token_id;
        items[key].creator = creator;
        items[key].owner = owner;
        items[key].price = _price;
        items[key].currency = _currency;
        items[key].royalties = royalties;
        items[key].bValid = true;

        emit Listed(key, _collection, _token_id, _price, _currency, creator, owner, royalties);
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

    function buy(address _collection, uint256 _token_id) external payable nonReentrant {
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

        if (item.currency == address(0x0)) {
            _safeTransferBNB(_previousOwner, _sellerValue);
            if(_commissionValue > 0) _safeTransferBNB(feeAddress, _commissionValue);
            if(_royalties > 0) _safeTransferBNB(_creator, _royalties);
        } else {
            require(IBEP20(item.currency).transferFrom(_newOwner, _previousOwner, _sellerValue));
            if(_commissionValue > 0) require(IBEP20(item.currency).transferFrom(_newOwner, feeAddress, _commissionValue));
            if(_royalties > 0) require(IBEP20(item.currency).transferFrom(_newOwner, _creator, _royalties));
        }

        IMoonstarNFT(item.collection).safeTransferFrom(address(this), _newOwner, item.token_id, "Purchase Item");
        
        item.bValid = false;

        emit Purchase(_previousOwner, _newOwner, _key, item.collection, item.token_id);
    }
    
    function updatePrice(address _collection, uint256 _token_id, address _currency, uint256 _price) public returns (bool) {
        bytes32 _key = itemKeyFromId(_collection, _token_id);
        Item storage item = items[_key];

        require(item.bValid, "invalid Item");
        require(isSupportedToken(_currency), "unsupported currency");
        require(msg.sender == item.owner, "Error, you are not the owner");

        uint256 oldPrice = item.price;
        item.price = _price;
        item.currency = _currency;

        emit PriceUpdate(msg.sender, oldPrice, _price, _currency, _key, _collection, _token_id);
        return true;
    }

    function itemKeyFromId(address _collection, uint256 _token_id) public pure returns (bytes32) {
        return keccak256(abi.encode(_collection, _token_id));
    }


    function _safeTransferBNB(address to, uint256 value) internal returns(bool) {
		(bool success, ) = to.call{value: value}(new bytes(0));
		if(!success) {
			IWETH(WBNBAddress).deposit{value: value}();
			return IWETH(WBNBAddress).transfer(to, value);
		}
		return success;
        
    }

    receive() external payable {}
}