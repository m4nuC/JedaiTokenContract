// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/JedaiForce.sol";
import "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ERC20CappedUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract JedaiForceTest is Test {
    JedaiForce jedaiForce;
    address proxy;
    address owner;
    address newOwner;

    // Test helpers for merkle tree
    bytes32[] public merkleProof;
    bytes32 public merkleRoot;
    uint256 public CLAIM_AMOUNT;

    // Add claimer addresses
    address public claimer1;
    address public claimer2;

    // Set up the test environment before running tests
    function setUp() public {
        // Define the owner address
        owner = vm.addr(1);
        claimer1 = vm.addr(2);
        claimer2 = vm.addr(3);
        
        // Deploy the proxy using the contract name
        proxy = Upgrades.deployUUPSProxy(
            "JedaiForce.sol:JedaiForce",  // Use contract name instead of implementation address
            abi.encodeCall(JedaiForce.initialize, (owner))
        );
        
        // Attach the JedaiForce interface to the deployed proxy
        jedaiForce = JedaiForce(proxy);
        // Define a new owner address for upgrade tests
        newOwner = address(1);
        // Emit the owner address for debugging purposes
        emit log_address(owner);

        // Initialize CLAIM_AMOUNT
        CLAIM_AMOUNT = 1000 * 10**jedaiForce.decimals();

        // Create merkle tree with two addresses
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(claimer1, CLAIM_AMOUNT));
        leaves[1] = keccak256(abi.encodePacked(claimer2, CLAIM_AMOUNT * 2)); // claimer2 gets double allocation

        // Sort leaves for consistent merkle tree
        if (uint256(leaves[0]) > uint256(leaves[1])) {
            bytes32 temp = leaves[0];
            leaves[0] = leaves[1];
            leaves[1] = temp;
        }

        // Calculate merkle root
        merkleRoot = keccak256(abi.encodePacked(leaves[0], leaves[1]));

        // Generate proof for claimer1
        merkleProof = new bytes32[](1);
        merkleProof[0] = leaves[1];  // If claimer1's leaf is leaves[0]
        
        // Set merkle root and claimable supply
        vm.prank(owner);
        jedaiForce.setMerkleRoot(merkleRoot);
        
        vm.prank(owner);
        jedaiForce.setClaimableSupply(CLAIM_AMOUNT * 3); // Total supply for both claimers
    }

    // Test the basic ERC20 functionality of the MyToken contract
    function testERC20Functionality() public {
        // Impersonate the owner to call mint function
        vm.prank(owner);
        // Mint tokens to address(2) and assert the balance
        jedaiForce.mint(address(2), 1000);
        assertEq(jedaiForce.balanceOf(address(2)), 1000);
    }

    // Test the upgradeability of the MyToken contract
    function testUpgradeability() public {
        // Get the current implementation address
        address currentImpl = Upgrades.getImplementationAddress(proxy);
        
        // Create options and skip storage check since we're testing with the same contract
        Options memory opts;
        opts.unsafeSkipStorageCheck = true;
        
        // Upgrade the proxy to the new implementation
        // Use the tryCaller parameter to specify the owner address
        Upgrades.upgradeProxy(
            proxy,
            "JedaiForce.sol:JedaiForce",
            "",  // Empty bytes since we don't need to call any function during upgrade
            opts,
            owner  // Pass the owner address as the tryCaller
        );
        
        // Verify the implementation was updated
        address newImpl = Upgrades.getImplementationAddress(proxy);
        assertTrue(currentImpl != newImpl);
    }

    function testMaxSupply() public {
        uint256 initialSupply = jedaiForce.totalSupply();
        uint256 maxSupply = jedaiForce.cap();
        uint256 remainingSupply = maxSupply - initialSupply;
        
        // Impersonate owner
        vm.prank(owner);
        // Mint the remaining supply (should succeed)
        jedaiForce.mint(address(2), remainingSupply);
        
        // Verify total supply equals cap
        assertEq(jedaiForce.totalSupply(), maxSupply);
        
        // Try to mint 1 more token (should fail)
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20CappedUpgradeable.ERC20ExceededCap.selector,
                maxSupply + 1,
                maxSupply
            )
        );
        jedaiForce.mint(address(2), 1);
    }

    function testMintExceedingMaxSupply() public {
        uint256 maxSupply = jedaiForce.cap();
        uint256 initialSupply = jedaiForce.totalSupply();
        
        // Impersonate owner
        vm.prank(owner);
        
        // Try to mint more than cap in one transaction
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20CappedUpgradeable.ERC20ExceededCap.selector,
                initialSupply + maxSupply,
                maxSupply
            )
        );
        jedaiForce.mint(address(2), maxSupply);
    }

    function testSupplyWithDecimals() public {
        // Check decimals
        assertEq(jedaiForce.decimals(), 18);
        
        // Initial supply should be 1,000,000 tokens
        uint256 expectedInitialSupply = 1_000_000 * 10**jedaiForce.decimals();
        assertEq(jedaiForce.totalSupply(), expectedInitialSupply);
        
        // Max supply should be 1 billion tokens
        uint256 expectedMaxSupply = 1_000_000_000 * 10**jedaiForce.decimals();
        assertEq(jedaiForce.cap(), expectedMaxSupply);
        
        // Verify remaining supply
        uint256 remainingSupply = jedaiForce.cap() - jedaiForce.totalSupply();
        assertEq(remainingSupply, 999_000_000 * 10**jedaiForce.decimals()); // 999 million tokens remaining
    }

    function testGetClaimableSupply() public {
        uint256 expectedSupply = 1000 * 10**jedaiForce.decimals();
        
        vm.prank(owner);
        jedaiForce.setClaimableSupply(expectedSupply);
        
        assertEq(jedaiForce.getClaimableSupply(), expectedSupply);
    }

    function testSetClaimableSupply() public {
        uint256 newSupply = 1000 * 10**jedaiForce.decimals();
        
        // Should revert when non-owner tries to set claimable supply
        vm.prank(address(2));
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                address(2)
            )
        );
        jedaiForce.setClaimableSupply(newSupply);

        // Should succeed when owner sets claimable supply
        vm.prank(owner);
        jedaiForce.setClaimableSupply(newSupply);
        
        // Verify the new claimable supply
        assertEq(jedaiForce.getClaimableSupply(), newSupply);
    }

    function testClaimSuccessClaimer1() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(abi.encodePacked(claimer2, CLAIM_AMOUNT * 2));

        vm.prank(claimer1);
        jedaiForce.claim(CLAIM_AMOUNT, CLAIM_AMOUNT, proof);
        
        assertEq(jedaiForce.balanceOf(claimer1), CLAIM_AMOUNT);
        assertEq(jedaiForce.claimedAmount(claimer1), CLAIM_AMOUNT);
        assertEq(jedaiForce.getClaimableSupply(), CLAIM_AMOUNT * 2); // Remaining for claimer2
    }

    function testClaimSuccessClaimer2() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(abi.encodePacked(claimer1, CLAIM_AMOUNT));

        vm.prank(claimer2);
        jedaiForce.claim(CLAIM_AMOUNT * 2, CLAIM_AMOUNT * 2, proof);
        
        assertEq(jedaiForce.balanceOf(claimer2), CLAIM_AMOUNT * 2);
        assertEq(jedaiForce.claimedAmount(claimer2), CLAIM_AMOUNT * 2);
        assertEq(jedaiForce.getClaimableSupply(), CLAIM_AMOUNT); // Remaining for claimer1
    }

    function testPartialClaimClaimer2() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(abi.encodePacked(claimer1, CLAIM_AMOUNT));

        // First claim - half of allocation
        vm.prank(claimer2);
        jedaiForce.claim(CLAIM_AMOUNT * 2, CLAIM_AMOUNT, proof);
        
        assertEq(jedaiForce.balanceOf(claimer2), CLAIM_AMOUNT);
        assertEq(jedaiForce.claimedAmount(claimer2), CLAIM_AMOUNT);
        
        // Second claim - remaining allocation
        vm.prank(claimer2);
        jedaiForce.claim(CLAIM_AMOUNT * 2, CLAIM_AMOUNT, proof);
        
        assertEq(jedaiForce.balanceOf(claimer2), CLAIM_AMOUNT * 2);
        assertEq(jedaiForce.claimedAmount(claimer2), CLAIM_AMOUNT * 2);
    }

    function testClaimFailuresWithProperMerkle() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(abi.encodePacked(claimer2, CLAIM_AMOUNT * 2));

        // Try to claim with wrong address
        vm.prank(address(4));
        vm.expectRevert("Invalid merkle proof");
        jedaiForce.claim(CLAIM_AMOUNT, CLAIM_AMOUNT, proof);

        // Try to claim more than allocated for claimer1
        vm.prank(claimer1);
        vm.expectRevert("Cannot claim more than allocated");
        jedaiForce.claim(CLAIM_AMOUNT, CLAIM_AMOUNT * 2, proof);

        // Successful claim for claimer1
        vm.prank(claimer1);
        jedaiForce.claim(CLAIM_AMOUNT, CLAIM_AMOUNT, proof);

        // Try to claim again with claimer1
        vm.prank(claimer1);
        vm.expectRevert("Already claimed full allocation");
        jedaiForce.claim(CLAIM_AMOUNT, 1, proof);
    }

    function testClaimWithInsufficientClaimableSupply() public {
        // Set claimable supply to less than claim amount
        vm.prank(owner);
        jedaiForce.setClaimableSupply(CLAIM_AMOUNT - 1);

        // Try to claim full amount
        vm.prank(address(2));
        vm.expectRevert("Insufficient claimable supply");
        jedaiForce.claim(CLAIM_AMOUNT, CLAIM_AMOUNT, merkleProof);
    }

    function testClaimExceedingRemainingAllocation() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(abi.encodePacked(claimer2, CLAIM_AMOUNT * 2));

        // First claim succeeds
        vm.prank(claimer1);
        jedaiForce.claim(CLAIM_AMOUNT, CLAIM_AMOUNT / 2, proof);
        
        // Second claim fails because it would exceed total allocation
        vm.prank(claimer1);
        vm.expectRevert("Claim amount exceeds allocation");
        jedaiForce.claim(CLAIM_AMOUNT, CLAIM_AMOUNT, proof);
    }
}