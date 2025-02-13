// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract JedaiForce is Initializable, ERC20CappedUpgradeable, OwnableUpgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    uint8 public constant DECIMALS = 18;
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** DECIMALS;
    uint256 private _claimableSupply;
    bytes32 private _merkleRoot;
    mapping(address => uint256) private _claimedAmount;
    uint256 private _totalBurned;
    address public stakingContractAddress;

    event TokensClaimed(address indexed user, uint256 amount);
    event TokensClaimedAndStaked(address indexed user, uint256 amount);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        string memory tokenName,
        string memory tokenSymbol,
        uint256 initialMintAmount
    ) initializer public {
        __ERC20_init(tokenName, tokenSymbol);
        __ERC20Capped_init(MAX_SUPPLY);
        __Ownable_init(initialOwner);
        __ERC20Permit_init(tokenName);
        __UUPSUpgradeable_init();
        _mint(msg.sender, initialMintAmount * 10 ** decimals());
    }

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal virtual override(ERC20CappedUpgradeable, ERC20Upgradeable) {
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}

    /// @notice Returns the current claimable supply
    function getClaimableSupply() public view returns (uint256) {
        return _claimableSupply;
    }

    /// @notice Sets the claimable supply - only callable by owner
    /// @param amount The new claimable supply amount
    function setClaimableSupply(uint256 amount) public onlyOwner {
        require(totalSupply() + amount <= cap(), "Claimable supply exceeds cap");
        _claimableSupply = amount;
    }

    /// @notice Sets the merkle root - only callable by owner
    /// @param merkleRoot The new merkle root
    function setMerkleRoot(bytes32 merkleRoot) external onlyOwner {
        _merkleRoot = merkleRoot;
    }

    /// @notice Allows users to claim their tokens if they are in the merkle tree
    /// @param amount The total amount of tokens allocated
    /// @param amountToClaim The amount of tokens to claim in this transaction
    /// @param merkleProof An array of bytes32 hashes as proof
    function claim(uint256 amount, uint256 amountToClaim, bytes32[] calldata merkleProof) public {
        require(amountToClaim > 0, "Cannot claim 0 tokens");
        require(amountToClaim <= amount, "Cannot claim more than allocated");
        
        uint256 alreadyClaimed = _claimedAmount[msg.sender];
        require(alreadyClaimed < amount, "Already claimed full allocation");
        require(alreadyClaimed + amountToClaim <= amount, "Claim amount exceeds allocation");
        require(amountToClaim <= _claimableSupply, "Insufficient claimable supply");
        
        // Create leaf node with total allocation amount
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        
        // Verify merkle proof
        require(
            MerkleProof.verify(merkleProof, _merkleRoot, leaf),
            "Invalid merkle proof"
        );
        _claimedAmount[msg.sender] += amountToClaim;
        _claimableSupply -= amountToClaim;
        _mint(msg.sender, amountToClaim);
        emit TokensClaimed(msg.sender, amountToClaim);
    }


    function claimFor(uint256 amount, uint256 amountToClaim, bytes32[] calldata merkleProof, address receiver) external {
        require(
            stakingContractAddress != address(0),
            "Staking contract not set"
        );
        require(
            msg.sender == stakingContractAddress,
            "Invalid staking contract address"
        );
        
        // Create leaf node with total allocation amount using the receiver's address
        bytes32 leaf = keccak256(abi.encodePacked(receiver, amount));
        
        // Verify merkle proof
        require(
            MerkleProof.verify(merkleProof, _merkleRoot, leaf),
            "Invalid merkle proof"
        );
        
        // Track claims against the user's address but send tokens to the staking contract
        uint256 alreadyClaimed = _claimedAmount[receiver];
        require(alreadyClaimed < amount, "Already claimed full allocation");
        require(alreadyClaimed + amountToClaim <= amount, "Claim amount exceeds allocation");
        require(amountToClaim <= _claimableSupply, "Insufficient claimable supply");
        
        _claimedAmount[receiver] += amountToClaim;
        _claimableSupply -= amountToClaim;
        // Mint tokens to the staking contract
        _mint(stakingContractAddress, amountToClaim);
        emit TokensClaimedAndStaked(receiver, amountToClaim);
    }

    /// @notice Returns the amount of tokens claimed by an address
    /// @param account The address to check
    /// @return uint256 Amount of tokens claimed so far
    function claimedAmount(address account) external view returns (uint256) {
        return _claimedAmount[account];
    }

    function cap() public view virtual override returns (uint256) {
        return MAX_SUPPLY - _totalBurned;
    }

    function burn(uint256 amount) public virtual {
        _burn(_msgSender(), amount);
        _totalBurned += amount;
    }

    function burnFrom(address account, uint256 amount) public virtual {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
        _totalBurned += amount;
    }

    function totalBurned() public view returns (uint256) {
        return _totalBurned;
    }

    function setStakingContractAddress(address _stakingContractAddress) external onlyOwner {
        require(_stakingContractAddress != address(0), "Invalid staking contract address");
        stakingContractAddress = _stakingContractAddress;
    }
}