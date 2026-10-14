// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721C} from "@limitbreak/creator-token-standards/erc721c/ERC721C.sol";
import {ERC721OpenZeppelin} from "@limitbreak/creator-token-standards/token/erc721/ERC721OpenZeppelin.sol";
import {OwnableBasic} from "@limitbreak/creator-token-standards/access/OwnableBasic.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20Burnable, IVeteransClaimPool, IVeteransRenderer, IVeteransStaking} from "./interfaces/IVeterans.sol";

/// @title VETERANS — proof-of-work mined ERC721C collection with wallet-age tracking.
/// @notice 3,333 NFTs mined by submitting a nonce whose wallet-bound keccak hash is below the epoch target.
///         Every mint costs a fixed 0.069 IMD which is split 65% staking rewards / 20% claim pool /
///         10% treasury / 5% burn. Secondary royalties (6.9%) are enforced through Limit Break's ERC721C
///         transfer validator and paid to the claim pool, which forwards the treasury's 0.9% share.
/// @dev    The economics (price, split, supply, epoch size, difficulty schedule, royalty) are constants.
///         The owner can only: configure the IMD token and sibling contracts once, manage the ERC721C
///         transfer validator, and swap the metadata renderer until it is frozen.
contract VeteransNFT is OwnableBasic, ERC721C, ERC2981, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────── Economics (final, immutable) ─────────────────────────────

    uint256 public constant MAX_SUPPLY = 3333;
    uint256 public constant EPOCH_SIZE = 333;
    uint256 public constant EPOCH_COUNT = 10;
    uint256 public constant MINT_PRICE = 0.069 ether; // 0.069 IMD (IMD has 18 decimals)

    uint256 public constant STAKING_SHARE_BPS = 6500; // 65% → staking rewards
    uint256 public constant POOL_SHARE_BPS = 2000; // 20% → claim pool
    uint256 public constant TREASURY_SHARE_BPS = 1000; // 10% → treasury
    uint256 public constant BURN_SHARE_BPS = 500; // 5%  → burned
    uint256 public constant BPS = 10_000;

    uint96 public constant ROYALTY_BPS = 690; // 6.9% total, paid to the claim pool which forwards 0.9% to treasury

    address public constant TREASURY_WALLET = 0xEab8865F6Af3a866FEf97a9A776c58aBcB711ab5;
    /// @dev Sink used only when the IMD token does not expose `burn(uint256)`.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Difficulty schedule: epoch 0 needs a hash with `START_BITS` leading zero bits (2^20 expected
    ///      attempts) and every later epoch adds `BITS_PER_EPOCH` (epoch 9 = 29 bits).
    uint256 public constant START_BITS = 20;
    uint256 public constant BITS_PER_EPOCH = 1;

    // ───────────────────────────────────────── State ─────────────────────────────────────────

    /// @notice IMD token the mint price is paid in. Set once by the owner after launch.
    IERC20 public imd;
    /// @notice Staking contract that receives the 65% share and tracks wallet weights.
    address public staking;
    /// @notice ETH/IMD claim pool that receives the 20% share and all royalties.
    address public claimPool;
    /// @notice Metadata renderer; swappable by the owner until `metadataFrozen`.
    IVeteransRenderer public renderer;
    bool public metadataFrozen;

    uint256 public totalMinted;
    /// @notice Timestamp a wallet was first seen (first mint or first stake); drives the age multiplier.
    mapping(address wallet => uint64) public firstSeen;
    /// @notice Winning proof-of-work hash of each token; it controls the visual traits only.
    mapping(uint256 tokenId => bytes32) public seedOf;
    /// @dev A winning nonce can be redeemed once per wallet.
    mapping(address wallet => mapping(uint256 nonce => bool)) public nonceUsed;

    // ───────────────────────────────────────── Events ─────────────────────────────────────────

    event Configured(address indexed imd, address indexed staking, address indexed claimPool);
    event RendererUpdated(address indexed renderer);
    event MetadataFrozen();
    event FirstSeen(address indexed wallet, uint64 timestamp);
    event Mined(address indexed miner, uint256 indexed tokenId, uint256 indexed epoch, uint256 nonce, bytes32 hash);
    event FeesSplit(uint256 staking, uint256 pool, uint256 treasury, uint256 burned);

    // ───────────────────────────────────────── Errors ─────────────────────────────────────────

    error ZeroAddress();
    error NotConfigured();
    error AlreadyConfigured();
    error InvalidSibling();
    error SoldOut();
    error HashAboveTarget(bytes32 hash, uint256 target);
    error NonceAlreadyUsed();
    error NotStakingContract();
    error MetadataIsFrozen();
    error TokenDoesNotExist();

    // ─────────────────────────────────────── Constructor ───────────────────────────────────────

    /// @param owner_    Collection owner (transfer-validator admin, one-time configurator). Never the factory.
    /// @param renderer_ Metadata renderer contract (deployed before this one; not called here).
    constructor(address owner_, address renderer_) ERC721OpenZeppelin("VETERANS", "VETERANS") {
        if (owner_ == address(0) || renderer_ == address(0)) revert ZeroAddress();
        _transferOwnership(owner_);
        renderer = IVeteransRenderer(renderer_);
        emit RendererUpdated(renderer_);
    }

    // ────────────────────────────────── One-time configuration ─────────────────────────────────

    /// @notice Wires the IMD token, staking contract and claim pool. Callable once, by the owner.
    /// @dev    The siblings must point back at this collection; the pool must point at the staking contract.
    function configure(address imd_, address staking_, address claimPool_) external {
        _requireCallerIsContractOwner();
        if (address(imd) != address(0)) revert AlreadyConfigured();
        if (imd_ == address(0) || staking_ == address(0) || claimPool_ == address(0)) revert ZeroAddress();
        if (imd_.code.length == 0) revert InvalidSibling();
        if (IVeteransStaking(staking_).nft() != address(this)) revert InvalidSibling();
        if (IVeteransClaimPool(claimPool_).nft() != address(this)) revert InvalidSibling();
        if (IVeteransClaimPool(claimPool_).staking() != staking_) revert InvalidSibling();

        imd = IERC20(imd_);
        staking = staking_;
        claimPool = claimPool_;
        _setDefaultRoyalty(claimPool_, ROYALTY_BPS);
        emit Configured(imd_, staking_, claimPool_);
    }

    /// @notice Replaces the metadata renderer. Disabled forever once `freezeMetadata()` is called.
    function setRenderer(address renderer_) external {
        _requireCallerIsContractOwner();
        if (metadataFrozen) revert MetadataIsFrozen();
        if (renderer_ == address(0)) revert ZeroAddress();
        renderer = IVeteransRenderer(renderer_);
        emit RendererUpdated(renderer_);
    }

    /// @notice Permanently locks the renderer.
    function freezeMetadata() external {
        _requireCallerIsContractOwner();
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    // ───────────────────────────────────── Proof of work ─────────────────────────────────────

    /// @notice Mines one VETERAN. `nonce` must satisfy `hashFor(msg.sender, nonce) < target()`.
    /// @dev    Charges exactly MINT_PRICE IMD (caller must have approved it) and splits it immediately.
    function mint(uint256 nonce) external nonReentrant returns (uint256 tokenId) {
        if (address(imd) == address(0)) revert NotConfigured();
        uint256 minted = totalMinted;
        if (minted >= MAX_SUPPLY) revert SoldOut();
        if (nonceUsed[msg.sender][nonce]) revert NonceAlreadyUsed();

        bytes32 hash = hashFor(msg.sender, nonce);
        uint256 epoch = _epochAt(minted);
        uint256 epochTarget = targetFor(epoch);
        if (uint256(hash) >= epochTarget) revert HashAboveTarget(hash, epochTarget);

        // Effects.
        nonceUsed[msg.sender][nonce] = true;
        tokenId = minted + 1;
        totalMinted = tokenId;
        seedOf[tokenId] = hash;
        _recordFirstSeen(msg.sender);
        emit Mined(msg.sender, tokenId, epoch, nonce, hash);

        // Interactions: collect the price, then split it.
        imd.safeTransferFrom(msg.sender, address(this), MINT_PRICE);
        _splitFee();
        _safeMint(msg.sender, tokenId);
    }

    function _splitFee() private {
        uint256 toStaking = MINT_PRICE * STAKING_SHARE_BPS / BPS;
        uint256 toPool = MINT_PRICE * POOL_SHARE_BPS / BPS;
        uint256 toTreasury = MINT_PRICE * TREASURY_SHARE_BPS / BPS;
        uint256 toBurn = MINT_PRICE - toStaking - toPool - toTreasury;

        imd.safeTransfer(staking, toStaking);
        IVeteransStaking(staking).notifyReward(toStaking);

        imd.safeTransfer(claimPool, toPool);
        IVeteransClaimPool(claimPool).notifyImd(toPool);

        imd.safeTransfer(TREASURY_WALLET, toTreasury);
        _burnImd(toBurn);

        emit FeesSplit(toStaking, toPool, toTreasury, toBurn);
    }

    /// @dev Burns through `burn(uint256)` when the token supports it, else sends to the dead address.
    function _burnImd(uint256 amount) private {
        uint256 before = imd.balanceOf(address(this));
        try IERC20Burnable(address(imd)).burn(amount) {} catch {}
        if (imd.balanceOf(address(this)) + amount > before) {
            // burn() was unavailable or did nothing: fall back to an unrecoverable sink.
            imd.safeTransfer(BURN_ADDRESS, amount);
        }
    }

    function _recordFirstSeen(address wallet) private {
        if (firstSeen[wallet] == 0) {
            firstSeen[wallet] = uint64(block.timestamp);
            emit FirstSeen(wallet, uint64(block.timestamp));
        }
    }

    /// @notice Lets the staking contract stamp `firstSeen` for wallets that bought on secondary.
    function recordFirstSeen(address wallet) external {
        if (msg.sender != staking || staking == address(0)) revert NotStakingContract();
        _recordFirstSeen(wallet);
    }

    // ───────────────────────────────────────── Views ─────────────────────────────────────────

    /// @notice Wallet-bound proof-of-work hash: keccak256(chainid ‖ this ‖ miner ‖ nonce).
    function hashFor(address miner, uint256 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, address(this), miner, nonce));
    }

    /// @notice Current epoch, 0-based (0..9). Epochs 0–8 hold 333 mints; the last one runs to the supply cap
    ///         (336 mints), because 10 × 333 = 3,330 and the brief fixes both 3,333 and "exactly 10 epochs".
    function currentEpoch() public view returns (uint256) {
        return _epochAt(totalMinted);
    }

    function _epochAt(uint256 minted) private pure returns (uint256) {
        uint256 epoch = minted / EPOCH_SIZE;
        return epoch >= EPOCH_COUNT ? EPOCH_COUNT - 1 : epoch;
    }

    /// @notice Leading zero bits a hash needs in `epoch`. Virtual so a test double can lower it.
    function difficultyBits(uint256 epoch) public pure virtual returns (uint256) {
        return START_BITS + epoch * BITS_PER_EPOCH;
    }

    /// @notice Hash target for `epoch`: hashes strictly below it win.
    function targetFor(uint256 epoch) public view returns (uint256) {
        uint256 bits = difficultyBits(epoch);
        return bits >= 256 ? 1 : (type(uint256).max >> bits);
    }

    /// @notice Current difficulty expressed in leading zero bits.
    function difficulty() external view returns (uint256) {
        return difficultyBits(currentEpoch());
    }

    /// @notice Current hash target.
    function target() external view returns (uint256) {
        return targetFor(currentEpoch());
    }

    /// @notice Mints left before the next epoch starts (the last epoch counts down to the supply cap).
    function mintsRemainingInEpoch() external view returns (uint256) {
        uint256 minted = totalMinted;
        if (_epochAt(minted) == EPOCH_COUNT - 1) return MAX_SUPPLY - minted;
        return EPOCH_SIZE - (minted % EPOCH_SIZE);
    }

    /// @notice Mints left in the whole collection.
    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalMinted;
    }

    /// @notice Mint price in IMD wei; it never changes.
    function mintPrice() external pure returns (uint256) {
        return MINT_PRICE;
    }

    function isConfigured() external view returns (bool) {
        return address(imd) != address(0);
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        return renderer.tokenURI(tokenId, seedOf[tokenId]);
    }

    // ───────────────────────────────── ERC721C / ERC2981 glue ─────────────────────────────────

    /// @dev Moving a token into or out of the staking contract never changes its beneficial owner, so it
    ///      bypasses the royalty-enforcing validator. Every other transfer is validated by ERC721C.
    function _preValidateTransfer(address caller, address from, address to, uint256 tokenId, uint256 value)
        internal
        override
    {
        address staking_ = staking;
        if (staking_ != address(0) && (from == staking_ || to == staking_)) return;
        super._preValidateTransfer(caller, from, to, tokenId, value);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721C, ERC2981) returns (bool) {
        return ERC721C.supportsInterface(interfaceId) || ERC2981.supportsInterface(interfaceId);
    }
}
