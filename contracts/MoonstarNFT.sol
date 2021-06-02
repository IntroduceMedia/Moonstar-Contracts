// Moonstar NFT token
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./IBEP20.sol";

contract Whitelist is Ownable {
    // Mapping of address to boolean indicating whBNBer the address is whitelisted
    mapping(address => bool) private whitelistMap;

    // flag controlling whBNBer whitelist is enabled.
    bool private whitelistEnabled = true;

    event AddToWhitelist(address indexed _newAddress);
    event RemoveFromWhitelist(address indexed _removedAddress);

    /**
   * @dev Enable or disable the whitelist
   * @param _enabled bool of whBNBer to enable the whitelist.
   */
    function enableWhitelist(bool _enabled) public onlyOwner {
        whitelistEnabled = _enabled;
    }

    /**
   * @dev Adds the provided address to the whitelist
   * @param _newAddress address to be added to the whitelist
   */
    function addToWhitelist(address _newAddress) public onlyOwner {
        _whitelist(_newAddress);
        emit AddToWhitelist(_newAddress);
    }

    /**
   * @dev Removes the provided address to the whitelist
   * @param _removedAddress address to be removed from the whitelist
   */
    function removeFromWhitelist(address _removedAddress) public onlyOwner {
        _unWhitelist(_removedAddress);
        emit RemoveFromWhitelist(_removedAddress);
    }

    /**
   * @dev Returns whBNBer the address is whitelisted
   * @param _address address to check
   * @return bool
   */
    function isWhitelisted(address _address) public view returns (bool) {
        if (whitelistEnabled) {
            return whitelistMap[_address];
        } else {
            return true;
        }
    }

    /**
   * @dev Internal function for removing an address from the whitelist
   * @param _removedAddress address to unwhitelisted
   */
    function _unWhitelist(address _removedAddress) internal {
        whitelistMap[_removedAddress] = false;
    }

    /**
   * @dev Internal function for adding the provided address to the whitelist
   * @param _newAddress address to be added to the whitelist
   */
    function _whitelist(address _newAddress) internal {
        whitelistMap[_newAddress] = true;
    }
}

interface IWBNB {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IFactory {
    function list(address creator, address owner, uint256 tokenId, bool currency,  uint256 price) external;
}

contract MoonstarNFT is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable, Whitelist {
    using SafeMath for uint256;

    uint256 constant public PERCENTS_DIVIDER = 1000;
	uint256 constant public FEE_MAX_PERCENT = 300;

    address public factory;

    mapping(uint256 => uint256) private _royalties;
    mapping(uint256 => address) private _creators;


    event Minted(address indexed minter, bool currency, uint256 price, uint nftID, string uri, bool status, uint256 royalties);
    event Burned(uint nftID);
     
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_)  {
        factory = msg.sender;
        _whitelist(factory);
    }

    /**
		Initialize from factory
	 */
	function initialize(address creator) external {
		require(msg.sender == factory, 'Only for factory');

        _whitelist(creator);
        _whitelist(msg.sender);

        transferOwnership(creator);
	}

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

      /**
     * @dev Whitelists a bunch of addresses.
     * @param _whitelistees address[] of addresses to whitelist.
     */
    function initWhitelist(address[] memory _whitelistees) public onlyOwner {
      // Add all whitelistees.
      for (uint256 i = 0; i < _whitelistees.length; i++) {
        address creator = _whitelistees[i];
        if (!isWhitelisted(creator)) {
          _whitelist(creator);
        }
      }
    }

    
    function mint(string memory _tokenURI, address _toAddress, bool _currency,  uint256 _price, bool _isListOnMarketplace, uint256 _royaltiesPercent) public returns (uint) {
        require(isWhitelisted(msg.sender), "must be whitelisted to create tokens");
        require(_royaltiesPercent < FEE_MAX_PERCENT, "too big royalties");
        
        uint _tokenId = totalSupply() + 1;
        
        _safeMint(_toAddress, _tokenId);
        _setTokenURI(_tokenId, _tokenURI);

        _creators[_tokenId] = msg.sender;
        _royalties[_tokenId] = _royaltiesPercent;
         
        if(_isListOnMarketplace) {
            IFactory(factory).list(msg.sender, _toAddress, _tokenId, _currency, _price);
        }

        emit Minted(_toAddress, _currency,  _price, _tokenId, _tokenURI, _isListOnMarketplace, _royaltiesPercent);

        return _tokenId;
    }

    function burn(uint _tokenId) external onlyOwner returns (bool)  {
        require(_exists(_tokenId), "Token ID is invalid");
        _burn(_tokenId);
        emit Burned(_tokenId);
        return true;
    }

    function creatorOf(uint256 _tokenId) public view returns (address) {
        return _creators[_tokenId];
	}

	function royalties(uint256 _tokenId) public view returns (uint256) {
        return _royalties[_tokenId];
	}

    receive() external payable {}

    function _burn(uint256 tokenId) internal virtual override (ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view virtual override (ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual override(ERC721, ERC721Enumerable) { 
        super._beforeTokenTransfer(from, to, tokenId);
    }
}