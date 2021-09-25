// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "./ProductToken.sol";
import "./interface/IVNFT.sol";

/// @title ProductTokenV0
/// @notice This is version 0 of the product token implementation.
/// @dev This contract builds on top of version 0 by including transaction logics, such as buy and sell transfers
///    and exchange rate computation by including a price oracle.
contract ProductTokenV0 is ProductToken {
	using SafeMathUpgradeable for uint256;

    struct supplierInfo {
        uint256 amount;
        address wallet;
    }
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 pendingReward;
        uint256[] records;
    }
    struct PoolInfo {
        uint256 amount; // record the entire pool vaule
        uint256 accRewardPerShare; // Accumulated reward per share
        uint256 tokenReward; //total reward
    }
    struct voucherInfo {
        address addr;
        uint256 tokenId;
    }

    supplierInfo public supplier;
    PoolInfo public poolInfo;
    voucherInfo public voucher;
    mapping (address => UserInfo) public userInfo;

    function _updatePool(uint256 fee_) internal virtual{
        uint256 supply = poolInfo.amount;
        if (supply == 0) {
            poolInfo.accRewardPerShare = 0;
            return;
        }
        poolInfo.accRewardPerShare = poolInfo.accRewardPerShare.add(fee_.mul(1e12).div(supply));
    }

    // function _updateSellStaking(uint32 amount_, uint256 tokenId_) internal virtual {
    //     UserInfo storage user = userInfo[msg.sender];
    //     require(user.amount > 0, "invalid amount");
    //     if(balanceOf(msg.sender) <= user.records.length) {
    //         uint max = uint256(amount_);
    //         if(max > user.records.length) {
    //             max = user.records.length;
    //         }
    //         uint256 value = 0;
    //         for(uint i = 0; i < max; i++) {
    //             value = value.add(user.records[user.records.length.sub(1)]);
    //             user.records.pop();
    //         }
    //         PoolInfo storage pool = poolInfo;
    //         user.pendingReward = 0;
    //         uint256 reward = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt).add(user.pendingReward);
    //         poolInfo.amount = poolInfo.amount.sub(value);
    //         if(reward > 0) {
    //             IVNFT(voucher.addr).transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, reward);
    //             poolInfo.tokenReward = poolInfo.tokenReward.sub(reward);
    //         }
    //         user.amount = user.amount.sub(value);
    //         user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(1e12);
    //     }
    // }

    // function _updateTranferStaking(address sender_, address recipient_, uint256 amount_) internal virtual {
    //     UserInfo storage sender = userInfo[sender_];
    //     UserInfo storage recipient = userInfo[recipient_];

    //     // 1. transfer, tranferFrom 可以同時轉很多個
    //         // 1. 整數問題：
    //             // sender.amount = sender.amount - amount;
    //             // integer = amount_.div(1 ether);
    //             // percentage = (amount_.mod(1 ether).mul(1e12)).div(1 ether);
    //         // 2. 可以同時轉多個，FILO

    //     uint max = amount_.div(1 ether);;
    //     if(max > sender.records.length) {
    //         max = sender.records.length;
    //     }
    //     uint256 value = 0;
    //     uint256 temp;
    //     for(uint i = 0; i < max; i++) {
    //         temp = sender.records[sender.records.length.sub(1)];
    //         sender.records.pop();
    //         recipient.records.push(temp);
    //         value = value.add(temp);
    //     }
    //     uint percent = (amount_.mod(1 ether));
    //     temp = sender.records[sender.records.length.sub(1)].mul(percent).div(1 ether);
    // }

    function _updateUserInfo(uint256 price_ ) internal virtual {
        UserInfo storage user = userInfo[msg.sender];
        user.amount = user.amount.add(price_);
        user.records.push(price_);
        user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(1e12);
    }

    function setupVoucher(address addr_, uint256 tokenId_) external virtual onlyOwner{
        require(addr_ != address(0), 'invalid address');
        voucher.addr = addr_;
        voucher.tokenId = tokenId_;
    }

    function claimVoucher(uint256 tokenId_) external virtual onlyOwner{
        require(tokenId_ != 0, 'invalid id');

        uint256 amount = IVNFT(voucher.addr).unitsInToken(voucher.tokenId);
        IVNFT(voucher.addr).transferFrom(address(this), owner(), voucher.tokenId , tokenId_, amount);
    }

    function buyByVoucher(uint256 tokenId_, uint256 maxPrice_) external virtual onlyIfTradable{
        require(tokenId_ >= 0, "Invalid id");
        require(maxPrice_ > 0, "invalid max price");
        IVNFT instance = IVNFT(voucher.addr);
        instance.transferFrom(msg.sender, address(this), tokenId_, voucher.tokenId, maxPrice_);

        (uint256 amount,uint256 change, uint price, uint256 fee)  = _buy(maxPrice_);
        if (amount > 0) {
            if(change > 0) {
                instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, change);
            }
            _updateSupplierFee(fee.mul(1e12).div(8e12));
            // uint256 reward = fee.mul(6e12).div(8e12);
            // _updatePool(reward);
            // poolInfo.tokenReward = poolInfo.tokenReward.add(reward);
            // UserInfo storage user = userInfo[msg.sender];
            // PoolInfo storage pool = poolInfo;
            // user.pendingReward = 0;
            // uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt).add(user.pendingReward);
            // if(pending > 0) {
            //     user.pendingReward= pending;
            //     instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, pending);
            //     poolInfo.tokenReward = poolInfo.tokenReward.sub(pending);
            // }
            // poolInfo.amount = poolInfo.amount.add(price);
            // _updateUserInfo(price);
        } else {
            instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, maxPrice_);
        }
    }

    function sellByVoucher(uint256 tokenId_, uint32 amount_) external virtual onlyIfTradable{
        (uint256 price, uint256 fee )= _sellForAmount(amount_);

        // _updateSellStaking(amount_, tokenId_);

        IVNFT(voucher.addr).transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, price);
        _updateSupplierFee(fee.mul(1e12).div(2e12));
    }

    function tradeinVoucher(uint256 tokenId_, uint32 amount_) external virtual onlyIfTradable {
        require(amount_ > 0, "Amount must be non-zero.");
        require(balanceOf(msg.sender) >= amount_, "Insufficient tokens to burn.");

        (uint256 reimburseAmount, uint fee) = _sellReturn(amount_);
        uint256 tradinReturn = calculateTradinReturn(amount_);
        _updateSupplierFee(fee.mul(1e12).div(2e12).add(tradinReturn));
        _addEscrow(amount_,  reimburseAmount.sub(fee));
        _burn(msg.sender, amount_);
        tradeinCount = tradeinCount + amount_;
        tradeinReserveBalance = tradeinReserveBalance.add(tradinReturn);

        // _updateSellStaking(amount_, tokenId_);

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
            IVNFT(voucher.addr).transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, amount_);
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

    // function transfer(address recipient_, uint256 amount_) public virtual override returns (bool) {
    //     // require(amount_.mod(1 ether) == 0, 'only support integer');
    //     super.transfer(recipient_, amount_);
    //     //deal with staking
    //     // cleanup Sell staking
    //     // _updateSellStaking(msg.sender, uint32(amount_), 0, true);
    //     //add staking to new owner
    // }

    // function transferFrom(
    //     address sender_,
    //     address recipient_,
    //     uint256 amount_
    // ) public virtual override returns (bool) {
    //     // require(amount_.mod(1 ether) == 0, 'only support integer');
    //     super.transfer(recipient_, amount_);
    //     //deal with staking
    //     // _updateSellStaking(sender_,  uint32(amount_), 0, true);
    // }

}
