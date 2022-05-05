// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

// Base contract for PartyBid/PartyBuy.
// Holds post-win/loss logic. E.g., burning contribution NFTs and creating a
// party after winning.
abstract contract PartyCrowdfund is PartyCrowdfundNFT {
    using LibRawResult for bytes;

    enum CrowdfundLifecycle {
        Invalid,
        Active,
        Lost,
        Won
    }

    struct CrowdfundInitOptions {
        string name;
        string symbol;
        bytes32 partyOptionsHash;
        address payable splitRecipient;
        uint16 splitBps;
        address initialDelegate;
    }

    struct Contribution {
        uint128 previousTotalContribution;
        uint128 contribution;
    }

    error WrongLifecycleError(CrowdfundLifecycle current);

    event DaoClaimed(address recipient, uint256 amount);
    event Burned(address contributor, uint256 ethUsed, uint256 votingPower);

    IGlobals private immutable _GLOBALS;

    // When this crowdfund expires.
    uint40 expiry;
    // The party instance created by `_createParty()`, if any.
    Party public party;
    // Hash of PartyOptions passed into initialize().
    // The PartyOptions passed into `_createParty()` must match.
    bytes32 public partyOptionsHash;
    // Who will receive a reserved portion of governance power.
    address payable public splitRecipient;
    // How much governance power to reserve for `splitRecipient`,
    // in bps, where 1000 = 100%.
    uint16 public splitBps;
    // Who a contributor last delegated to.
    mapping (address => address) private _delegationsByContributor;
    // Array of contributions by a contributor.
    // One is created for every contribution made.
    mapping (address => Contribution[]) private _contributionsByContributor;

    constructor(IGlobals globals) PartyCrowdfundNFT(globals) {
        _GLOBALS = globals;
    }

    // Must be called once by freshly deployed PartyCrowdfundProxy instances.
    function initialize(CrowdfundInitOptions memory opts)
        public
        override
    {
        PartyCrowdfundNFT.initialize(opts.name, opts.symbol);
        partyOptionsHash = opts.partyOptionsHash;
        splitRecipient = opts.splitRecipient;
        splitBps = opts.splitBps;
        // If the deployer passed in some ETH during deployment, credit them.
        uint128 initialBalance = uint128(address(this).balance);
        if (initialBalance > 0) {
            _addContribution(msg.sender, initialBalance, opts.initialDelegate, 0);
        }
    }

    // Burns CF tokens owned by `owner` AFTER the CF has ended.
    // If the party has won, someone needs to call `_createParty()` first. After
    // which, `burn()` will refund unused ETH and mint governance tokens for the
    // given `contributor`.
    // If the party has lost, this will only refund unused ETH (all of it) for
    // the given `contributor`.
    function burn(address contributor)
        public
    {
        return _burn(contributor, getCrowdfundLifecycle(), party);
    }

    // `burn()` in batch form.
    function batchBurn(address[] calldata contributors)
        external
    {
        ethRefunded = new uint256[](contributors.length);
        Party party_ = party;
        CrowdfundLifecycle lc = getCrowdfundLifecycle();
        for (uint256 i = 0; i < contributors.length; ++i) {
            _burn(contributors[i], lc, party_);
        }
    }

    // Contribute and/or delegate.
    // TODO: Should contributor not be a param?
    function contribute(address contributor, address delegate)
        public
        virtual
        payable
    {
        _addContribution(
            contributor,
            msg.value,
            delegate,
            address(this).balance - msg.value
        );
    }

    // Contribute, reusing the last delegate of the sender or
    // the sender itself if not set.
    receive() external payable {
        // If the sender already delegated before then use that delegate.
        // Otherwise delegate to the sender.
        address delegate = delegationsByContributor[msg.sender];
        delegate = delegate == address(0) ? msg.sender : delegate;
        _addContribution(
            contributor,
            msg.value,
            delegate,
            address(this).balance - msg.value
        );
    }

    function getCrowdfundLifecycle() public abstract view returns (CrowdfundLifecycle);

    // Transfer the bought asset(s) to a recipient.
    function _transferSharedAssetsTo(address recipient) internal abstract;
    // Get the final sale price (not including party fees, splits, etc) of the
    // bought assets.
    function _getFinalPrice() internal abstract view returns (uint256);

    // Can be called after a party has won.
    // Deploys and initializes a a `Party` instance via the `PartyFactory`
    // and transfers the bought NFT to it.
    // After calling this, anyone can burn CF tokens on a contributor's behalf
    // with the `burn()` function.
    function _createParty(Party.PartyOptions opts) internal returns (Party party_) {
        require(party == Party(address(0)));
        require(_hashPartyOptions(opts) == partyOptionsHash);
        party = party_ =
            PartyFactory(_GLOBALS.getAddress(LibGlobals.GLOBAL_PARTY_FACTORY))
                ._createParty(address(this), opts);
        _transferSharedAssetsTo(address(party_));
        emit PartyCreated(party_);
    }


    function _hashPartyOptions(PartyOptions memory partyOptions)
        private
        view
        returns (bytes32 h)
    {
        // Do EIP1271 hash here...
    }

    function _getParty() internal view returns (Party) {
        return party;
    }

    function _getFinalContribution(address contributor)
        internal
        view
        returns (uint256 ethUsed, uint256 ethOwed, uint256 votingPower)
    {
        uint256 totalEthUsed = _getFinalPrice();
        {
            Contribution[] storage contributions = _contributionsByContributor[contributor];
            uint256 numContributions = contributions.length;
            for (uint256 i = 0; i < numContributions; ++i) {
                Contribution memory c = contributions[i];
                if (c.previousTotalContribution >= totalEthUsed) {
                    break;
                }
                if (c.previousTotalContribution + c.amount <= totalEthUsed) {
                    ethUsed += c.amount;
                } else {
                    ethUsed = totalEthUsed - c.previousTotalContribution;
                    ethOwed = c.amount - ethUsed;
                }
            }
        }
        uint256 splitBps_ = uint256(splitBps);
        votingPower = (1e4 - splitBps_) * totalEthUsed / 1e4;
        if (splitRecipient == contributor) {
            // Split recipient is also the contributor so just add the split
            // voting power.
             votingPower += splitBps_ * totalEthUsed / 1e4;
        }
    }

    function _addContribution(
        address contributor,
        uint128 amount,
        address delegate,
        uint128 previousTotalContributions
    )
        internal
    {
        require(delegate != address(0), 'INVALID_DELEGATE');
        // Update delegate.
        _delegationsByContributor[contributor] = delegate;
        emit Contributed(contributor, amount, delegate);

        if (amount != 0) {
            // Only allow contributions while the crowdfund is active.
            {
                CrowdfundLifecycle lc = getCrowdfundLifecycle();
                if (lc != CrowdfundLifecycle.Active) {
                    revert WrongLifecycleError(lc);
                }
            }
            // Create contributions entry for this contributor.
            Contribution[] storage contributions = _contributionsByContributor[contributor];
            uint256 numContributions = contributions.length;
            if (numContributions >= 1) {
                lastContribution = contributions[numContributions - 1];
                if (lastContribution.previousTotalContribution == previousTotalContribution) {
                    // No one else has contributed since so just reuse the last entry.
                    lastContribution.contribution += amount;
                    contributions[numContributions - 1] = lastContribution;
                    return;
                }
            }
            // Add a new contribution entry.
            contributions.push(Contribution({
                previousTotalContribution: previousTotalContribution,
                amount: amount
            }));
            if (numContributions == 0) {
                // Mint a participation NFT.
                _mint(contributor);
            }
        }
    }

    // Burn the participation NFT for `contributor`, potentially
    // minting voting power and/or refunding unused ETH.
    // `contributor` may also be the split recipient, regardless
    // of whether they are also a contributor or not.
    function _burn(address payable contributor, CrowdfundLifecycle lc, Party party_)
        private
    {
        // If the CF has won, a party must have been created prior.
        if (lc == CrowdfundLifecycle.Won) {
            require(party_ != Party(address(0)), "MUST_CREATE_PARTY");
        } else {
            // Otherwise it must have lost.
            require(lc == CrowdfundLifecycle.Lost, "CROWDFUND_NOT_OVER");
        }
        if (splitRecipient != contributor || _doesTokenExistFor(contributor)) {
            // Will revert if already burned.
            PartyCrowdfundNFT._burn(contributor);
        }
        (uint256 ethUsed, uint256 ethOwed, uint256 votingPower) =
            _getFinalContribution(contributor);
        if (party_ && votingPower > 0) {
            party_.mint(
                party_,
                contributor,
                votingPower,
                delegationsByContributor[contributor] // TODO: Might be 0 for split recipient
            );
        }
        _transferEth(contributor, ethOwed);
        emit Burned(contributor, ethUsed, votingPower);
    }

    // Transfer ETH with full gas stipend.
    function _transferEth(address payable to, uint256 amount)
        private
    {
        (bool s, bytes memory r) = to.call{ value: amount }(amount);
        if (!s) {
            r.rawRevert();
        }
    }
}
