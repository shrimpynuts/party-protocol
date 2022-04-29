// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

// Implements arbitrary call proposals.
contract ListOnZoraProposal {
    enum ZoraStep {
        None,
        ListedOnZora
    }

    // ABI-encoded `proposalData` passed into execute.
    struct ZoraProposalData {
        uint256 listPrice;
        uint40 durationInSeconds;
    }

    // ABI-encoded `progressData` passed into execute in the `ListedOnZora` step.
    struct ZoraProgressData {
        // Acution ID.
        uint256 auctionId;
        // Expiration timestamp of the auction, if no one bids.
        uint40 minExpiry;
    }

    error ZoraListingNotExpired(uint256 auctionId, uint40 expiry);

    IGlobals private immutable GLOBALS;

    constructor(IGblobals globals) {
        GLOBALS = globals;
    }

    // Try to create a listing (ultimately) on OpenSea.
    // Creates a listing on Zora AH for list price first. When that ends,
    // calling this function again will list in on OpenSea. When that ends,
    // calling this function again will cancel the listing.
    function _executeListOnZora(ExecuteProposalParams memory params)
        internal
        returns (bytes memory nextProgressData)
    {
        (ZoraProposalData memory data) = abi.decode(params.proposalData, (ZoraProposalData));
        (ZoraStep step) = abi.decode(params.progressData, (ZoraStep));
        if (step == ZoraStep.None) {
            // Proposal hasn't executed yet.
            (uint256 auctionId, uint40 minExpiry) = _createZoraAuction(
                data.listPrice,
                params.preciousToken,
                params.preciousTokenId
            );
            return abi.encode(ZoraStep.ListedOnZora, ZoraProgressData({
                auctionId: auctionId,
                minExpiry: minExpiry
            }));
        }
        assert(step == ZoraStep.ListOnZora);
        (ZoraProgressData memory pd) =
            abi.decode(params.progressData, (ZoraProgressData));
        if (pd.minExpiry < uint40(block.timstamp)) {
            revert ZoraListingNotExpired(pd.auctionId, pd.minExpiry);
        }
        _settleZoraAuction(pd.auctionId);
        // Nothing left to do.
        return "";
    }

    function _createZoraAuction(uint256 listPrice, IERC721 token, uint256 tokenId)
        internal
        returns (uint256 auctionId, uint40 minExpiry)
    {
        // TODO: Should this be passed in/per party?
        uint256 duration = GLOBALS.getUint256(LibGlobals.GLOBAL_OS_ZORA_AUCTION_DURATION);
        minExpiry = uint40(block.timestamp) + uint40(duration);
        token.approve(zora, tokenId);
        auctionId = zora.createAuction(
            tokenId,
            token,
            duration,
            listPrice,
            address(0),
            0,
            IERC20(address(0)) // Indicates ETH sale
        );
    }

    function _settleZoraAuction(uint256 auctionId, IERC721 token, uint256 tokenId)
        internal
        returns (bool sold)
    {
        // Getting the state of an auction is super expensive so it seems
        // cheaper to just let `endAuction` fail and react to the error.
        try zora.endAuction(auctionId) {
        } catch (bytes memory errData) {
            bytes32 errHash = keccak256(errData);
            if (errHash == keccak256("Auction hasn't begun")) {
                // No bids placed. Just cancel it.
                zora.cancelAuction(auctionId);
                return false;
            } else if (errHash != keccak256("Auction doesn't exist")) {
                errData.rawRevert();
            }
            // Already settled by someone else. Nothing to do.
        }
        return token.ownerOf(tokenId) != address(this);
    }
}
