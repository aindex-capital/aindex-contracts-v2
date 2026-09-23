// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {MintSplit} from "./FixedFeeRegistry.sol";

/// @notice Creation, funding and fee policy shared by every index this protocol launches.
///
/// @dev    Atomically funds and initializes an immutable implementation clone. The caller
///         receives all initial shares and admin authority; this contract retains neither assets
///         nor roles.
///
///         ## WHY THIS IS A BASE AND NOT THE ENTRY POINT
///
///         `create` here produces an index with **no mandate and no market**: the creator holds
///         admin directly and nothing rebalances. That is the right shape for a base class and
///         the wrong shape for a product, so it is `internal` machinery plus a bare `create` kept
///         for tests. `IndexFactory.createManaged` is the production path and it binds a
///         `MonthlyMandate` before returning.
contract IndexFactoryBase is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable implementation;
    address public immutable feeRegistry;
    mapping(address => bool) public isIndex;
    error InvalidConfiguration();
    error UnsupportedTransfer(address token);
    event IndexCreated(address indexed index, address indexed creator, string engineVersion);

    constructor(address implementation_, address feeRegistry_) {
        if (implementation_.code.length == 0 || feeRegistry_.code.length == 0) revert InvalidConfiguration();
        implementation = implementation_;
        feeRegistry = feeRegistry_;
    }

    function create(IFolio.FolioBasicDetails calldata seed) external virtual nonReentrant returns (Folio index) {
        index = _create(seed);
        index.grantRole(bytes32(0), msg.sender);
        index.renounceRole(bytes32(0), address(this));
    }

    function _create(IFolio.FolioBasicDetails calldata seed) internal returns (Folio index) {
        return _createFor(seed, msg.sender, msg.sender);
    }

    /**
     * @dev Create with the initial shares going somewhere other than the creator.
     *
     *      `shareRecipient` exists so a seeded launch can hold the shares long enough to open the
     *      market with them, and pass on what is left. `creator` stays the fee recipient and the
     *      admin either way: who paid for the basket and who happens to custody the shares for
     *      one transaction are different questions, and conflating them would hand the factory a
     *      cut of every mint.
     */
    function _createFor(IFolio.FolioBasicDetails calldata seed, address shareRecipient, address creator)
        internal
        returns (Folio index)
    {
        uint256 n = seed.assets.length;
        if (n == 0 || n > 16 || n != seed.amounts.length || seed.initialShares < 1e18) {
            revert InvalidConfiguration();
        }
        index = Folio(Clones.clone(implementation));
        for (uint256 i; i < n; ++i) {
            if (seed.assets[i].code.length == 0 || seed.amounts[i] == 0) revert InvalidConfiguration();
            for (uint256 j; j < i; ++j) {
                if (seed.assets[i] == seed.assets[j]) revert InvalidConfiguration();
            }
            IERC20 token = IERC20(seed.assets[i]);
            uint256 beforeBalance = token.balanceOf(address(index));
            token.safeTransferFrom(msg.sender, address(index), seed.amounts[i]);
            if (token.balanceOf(address(index)) != beforeBalance + seed.amounts[i]) {
                revert UnsupportedTransfer(seed.assets[i]);
            }
        }
        IFolio.FeeRecipient[] memory recipients = new IFolio.FeeRecipient[](1);
        recipients[0] = IFolio.FeeRecipient(creator, 1e18);
        index.initialize(
            seed,
            IFolio.FolioAdditionalDetails({
                maxAuctionLength: 1 hours,
                feeRecipients: recipients,
                immutableFeeRecipients: new IFolio.FeeRecipient[](0),
                /*
                 * No yearly fee, and 0.50% on a mint: 20 bps to the protocol, 15 to holders and
                 * 15 to the creator. `MintSplit` has the arithmetic.
                 *
                 * **No yearly fee is the holder guarantee.** Holding costs nothing, and trading and
                 * minting both pay holders, so a holder is ahead at any volume above zero. A yearly
                 * fee paid by holders would need volume many times the index's size to recover.
                 * The registry's floor must be zero too, or Folio raises this back to the floor.
                 *
                 * **The mint fee is the tracking band.** A share can trade up to about 0.50% plus
                 * the pool's 0.40% above net asset value before minting to sell into the premium
                 * is worth anyone's while. It was 1.35%, three to four times what comparable
                 * indexes charge, which let buyers pay a premium the basket did not justify. There
                 * is no redeem fee to match it: Folio has none, and `redeem` is directly callable
                 * so a wrapper would be bypassable.
                 *
                 * The holders' part is Folio's own `folioFeeForSelf`: those shares are handed out
                 * to backing over a ten-minute window each day at a capped rate, so buying just
                 * before a mint to catch it gains nothing.
                 */
                tvlFee: 0,
                mintFee: MintSplit.MINT_FEE,
                folioFeeForSelf: MintSplit.HOLDER_PORTION,
                mandate: "LOCAL PROTOTYPE: direct creator admin; no enforced investment mandate"
            }),
            IFolio.FolioRegistryIndex(feeRegistry, address(0)),
            IFolio.FolioFlags({
                trustedFillerEnabled: false,
                rebalanceControl: IFolio.RebalanceControl(false, IFolio.PriceControl.NONE),
                bidsEnabled: true
            }),
            shareRecipient
        );
        isIndex[address(index)] = true;
        emit IndexCreated(address(index), creator, index.version());
    }
}
