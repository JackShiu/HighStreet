// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "./ProductToken.sol";
import "./interface/IVNFT.sol";
import "./interface/ITokenUtils.sol";

/// @title ProductTokenV0
/// @notice This is version 0 of the product token implementation.
/// @dev This contract builds on top of version 0 by including transaction logics, such as buy and sell transfers
///    and exchange rate computation by including a price oracle.
contract ProductTokenV0 is ProductToken {
	using SafeMathUpgradeable for uint256;

    event Update(address daiAddress, address chainlinkAddress);
    event UpdateHsToken(address daiAddress, address chainlinkAddress);

    struct supplierInfo {
        uint256 amount;
        address wallet;
    }
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastReward;
        uint256[] records;
    }
    struct PoolInfo {
        uint256 amount; // record the entire pool vaule
        uint256 accRewardPerShare; // Accumulated reward per share
        uint256 tokenReward; //total reward
    }
    struct voucherInfo {
        address addr;
        IVNFT instance;
        uint256 tokenId;
        bool isEnable;
    }

    uint256 constant public  INDEX_ETH  = 0;
    uint256 constant public  INDEX_HIGH = 1;
    uint256 constant public  INDEX_DAI  = 2;

    supplierInfo public supplier;
    PoolInfo public poolInfo;
    voucherInfo public voucher;
    mapping (address => UserInfo) public userInfo;
    ITokenUtils private _tokenUtils;

    function setupTokenUtils(address addr_) external virtual onlyOwner {
        require(addr_ != address(0));
        _tokenUtils = ITokenUtils(addr_);
    }

    function _updatePool(uint256 fee_) internal virtual{
        uint256 supply = poolInfo.amount;
        if (supply == 0) {
            poolInfo.accRewardPerShare = 0;
            return;
        }
        poolInfo.accRewardPerShare = poolInfo.accRewardPerShare.add(fee_.mul(1e12).div(supply));
    }

    function _updateSellStaking(uint32 amount_, uint256 tokenId_) internal virtual {
        if(userInfo[msg.sender].amount > 0) {
            UserInfo storage user = userInfo[msg.sender];
            if(balanceOf(msg.sender) <= user.records.length) {
                uint max = uint256(amount_);
                if(max > user.records.length) {
                    max = user.records.length;
                }
                uint256 value = 0;
                for(uint i = 0; i < max; i++) {
                    value = value.add(user.records[user.records.length.sub(1)]);
                    user.records.pop();
                }
                PoolInfo storage pool = poolInfo;
                uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);

                poolInfo.amount = poolInfo.amount.sub(value);
                if(pending > 0) {
                    user.lastReward= pending;
                    voucher.instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, pending);
                    poolInfo.tokenReward = poolInfo.tokenReward.sub(pending);
                }
                user.amount = user.amount.sub(value);
                user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(1e12);
            }
        }
    }

    function _updateUserInfo(uint256 price_ ) internal virtual {
        UserInfo storage user = userInfo[msg.sender];
        user.amount = user.amount.add(price_);
        user.records.push(price_);
        user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(1e12);
    }

    function setupVoucher(address addr_, uint256 tokenId_, bool enable_) external virtual onlyOwner{
        require(addr_ != address(0), 'invalid address');
        voucher.addr = addr_;
        voucher.instance = IVNFT(addr_);
        voucher.tokenId = tokenId_;
        voucher.isEnable = enable_;
    }

    function pauseVoucher(bool enable_) external virtual onlyOwner {
        voucher.isEnable = enable_;
    }

    function claimVoucher(uint256 tokenId_) external virtual onlyOwner{
        require(tokenId_ != 0, 'invalid id');
        uint256 amount = voucher.instance.unitsInToken(voucher.tokenId);
        voucher.instance.transferFrom(address(this), owner(), voucher.tokenId , tokenId_, amount);
    }

    function buyByVoucher(uint256 tokenId_, uint256 maxPrice_) external virtual onlyIfTradable{
        require(voucher.isEnable, 'unable to use voucher');
        require(tokenId_ >= 0, "Invalid id");
        require(maxPrice_ > 0, "invalid max price");
        IVNFT instance = voucher.instance;
        instance.transferFrom(msg.sender, address(this), tokenId_, voucher.tokenId, maxPrice_);

        (uint256 amount,uint256 change, uint price, uint256 fee)  = _buy(maxPrice_);
        if (amount > 0) {
            if(change > 0) {
                instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, change);
            }
            _updateSupplierFee(fee.mul(1e12).div(8e12));
            uint256 reward = fee.mul(6e12).div(8e12);
            _updatePool(reward);
            poolInfo.tokenReward = poolInfo.tokenReward.add(reward);
            UserInfo storage user = userInfo[msg.sender];
            PoolInfo storage pool = poolInfo;
            uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                user.lastReward= pending;
                instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, pending);
                poolInfo.tokenReward = poolInfo.tokenReward.sub(pending);
            }
            poolInfo.amount = poolInfo.amount.add(price);
            _updateUserInfo(price);
        } else {
            instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, maxPrice_);
        }
    }

    function sellByVoucher(uint256 tokenId_, uint32 amount_) external virtual onlyIfTradable{
        require(voucher.isEnable, 'unable to use voucher');
        (uint256 price, uint256 fee )= _sellForAmount(amount_);

        _updateSellStaking(amount_, tokenId_);

        voucher.instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, price);
        _updateSupplierFee(fee.mul(1e12).div(2e12));
    }

    function tradeinVoucher(uint256 tokenId_, uint32 amount_) external virtual onlyIfTradable {
        require(voucher.isEnable, 'unable to use voucher');
        require(amount_ > 0, "Amount must be non-zero.");
        require(balanceOf(msg.sender) >= amount_, "Insufficient tokens to burn.");

        (uint256 reimburseAmount, uint fee) = _sellReturn(amount_);
        uint256 tradinReturn = calculateTradinReturn(amount_);
        _updateSupplierFee(fee.mul(1e12).div(2e12).add(tradinReturn));
        _addEscrow(amount_,  reimburseAmount.sub(fee));
        _burn(msg.sender, amount_);
        tradeinCount = tradeinCount + amount_;
        tradeinReserveBalance = tradeinReserveBalance.add(tradinReturn);

        _updateSellStaking(amount_, tokenId_);

        emit Tradein(msg.sender, amount_);
    }

    function setSupplier( address wallet_) external virtual onlyOwner {
        require(wallet_!=address(0), "Address is invalid");
        supplier.wallet = wallet_;
    }

    function claimSupplier(uint256 tokenId_, uint256 amount_) external virtual{
        require(supplier.wallet!=address(0), "wallet is invalid");
        require(msg.sender == supplier.wallet, "The address is not allowed");
        if (amount_ <= supplier.amount){
            voucher.instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, amount_);
            supplier.amount = supplier.amount.sub(amount_);
        }
    }

    function _updateSupplierFee(uint256 fee) virtual internal {
        if( fee > 0 ) {
            supplier.amount = supplier.amount.add(fee);
        }
    }

    /**
    * @dev this function returns the amount of reserve balance that the supplier can withdraw from the dapp.
    */
    function getSupplierBalance() public view virtual returns (uint256) {
        return supplier.amount;
    }

    /**
    * @dev A method that refunds the value of a product to a buyer/customer.
    *
    * @param buyer_       The wallet address of the owner whose product token is under the redemption process
    * @param value_       The market value of the token being redeemed
    *
    */
    function _refund(address buyer_, uint256 value_) internal virtual override {
        address highAddress = _tokenUtils.getAddressByIds(INDEX_HIGH);

        bool success = IERC20(highAddress).transfer(buyer_, value_);
        require(success, "refund token failed");
    }

    function getUserReward(address addr_) external view virtual returns (uint256) {
        if(userInfo[addr_].amount > 0) {
            UserInfo storage user = userInfo[addr_];
            PoolInfo storage pool = poolInfo;
            return user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
        }
        return 0;
    }

    function getUserInfo(address addr_) external view virtual returns( UserInfo memory) {
        require(addr_ != address(0), 'invalid address');
        return userInfo[addr_];
    }

    function getPoolInfo() external view virtual returns( PoolInfo memory) {
        return poolInfo;
    }

    function getSupplierInfo() external view virtual returns( supplierInfo memory) {
        return supplier;
    }

}
