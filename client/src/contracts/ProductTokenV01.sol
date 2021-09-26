// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "./ProductToken.sol";
import "./interface/IVNFT.sol";

/// @title ProductTokenV01
/// @notice This is version 01 of the product token implementation.
/// @dev This contract builds on top of version 0 by including transaction logics, such as buy and sell transfers
///    and exchange rate computation by including a price oracle.
contract ProductTokenV01 is ProductToken {
	using SafeMathUpgradeable for uint256;

    struct supplierInfo {
        uint256 amount;
        address wallet;
    }
    struct UserInfo {
        uint256 totalValue;
        uint256 rewardDebt;
        uint256 amount;
    }
    struct PoolInfo {
        uint256 value; // record the entire pool value
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
    mapping (address => uint256 []) public userRecords;

    function _updateSellStaking(uint32 sellAmount_, uint256 tokenId_) internal virtual {
        UserInfo memory user = userInfo[msg.sender];
        PoolInfo memory pool = poolInfo;

        // 1. user.totalValue > 0
        // 2. User balance
        // 3. User amount;

        // 使用者有足夠的餘額 跟 有足夠的紀錄
        if(user.totalValue < 0 || user.amount < 0) {
            return;
        }

        // 如果使用者想賣的數量 > 實際的紀錄，只算紀錄的部分
        uint256 amount = sellAmount_;
        if(sellAmount_ > user.amount ) {
            amount = user.amount;
        }

        uint256 liquidationValue = 0;
        uint256 [] memory records = userRecords[msg.sender];
        uint256 remainingAmount = user.amount.sub(amount);
        for(uint i = remainingAmount ; i < amount; i++) {
            liquidationValue = liquidationValue.add(records[i]);
        }
        user.amount = remainingAmount;

        uint256 reward = user.totalValue.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
        pool.value = pool.value.sub(liquidationValue);
        if(reward > 0 && pool.tokenReward > reward) {
            IVNFT(voucher.addr).transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, reward);
            pool.tokenReward = pool.tokenReward.sub(reward);
        }
        user.totalValue = user.totalValue.sub(liquidationValue);
        user.rewardDebt = user.totalValue.mul(pool.accRewardPerShare).div(1e12);
        poolInfo = pool; //須確認是否要這步驟 cp memory to storage
        userInfo[msg.sender] = user; //須確認是否要這步驟 cp memory to storage
    }

    function _updateBuyStaking(uint256 reward_, uint256 price_, uint256 tokenId_) internal virtual {
        UserInfo memory user = userInfo[msg.sender];
        PoolInfo memory pool = poolInfo;

        if (pool.value == 0 || pool.tokenReward == 0) {
            poolInfo.accRewardPerShare = 0;
            return;
        }
        pool.accRewardPerShare = pool.accRewardPerShare.add(reward_.mul(1e12).div(pool.value));
        pool.tokenReward = pool.tokenReward.add(reward_);

        uint256 userReward = user.totalValue.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
        if(userReward > 0 && pool.tokenReward > userReward) {
            IVNFT instance = IVNFT(voucher.addr);
            instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, userReward);
            pool.tokenReward = pool.tokenReward.sub(userReward);
        }
        pool.value = pool.value.add(price_);
        user.totalValue = user.totalValue.add(price_);
        user.rewardDebt = user.totalValue.mul(pool.accRewardPerShare).div(1e12);

        uint256 userAvail = balanceOf(msg.sender);
        uint256 index = user.amount;
        // 如果使用者場外賣掉了，則直接忽視掉該次的staking數量
        if(userAvail < index){
            index= userAvail;
        }
        user.amount = index.add(1); //不管怎樣，這次都是有買一個，所以還是要+1
        // 最後把所有資料塞回去storage
        uint256 [] storage records = userRecords[msg.sender];
        if(records.length < user.amount) {
            records.push(price_);
        } else {
            records[index] = price_;
        }
        poolInfo = pool; //須確認是否要這步驟 cp memory to storage
        userInfo[msg.sender] = user; //須確認是否要這步驟 cp memory to storage
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
            uint256 reward = fee.mul(6e12).div(8e12);
            _updateBuyStaking(reward, price, tokenId_);
        } else {
            instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, maxPrice_);
        }
    }

    function sellByVoucher(uint256 tokenId_, uint32 amount_) external virtual onlyIfTradable{
        (uint256 price, uint256 fee )= _sellForAmount(amount_);

        _updateSellStaking(amount_, tokenId_);

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
            UserInfo memory user = userInfo[addr_];
            PoolInfo memory pool = poolInfo;
            uint256 userReward = user.totalValue.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if(userReward > 0 && pool.tokenReward > userReward) {
                return userReward;
            }
        }
        return 0;
    }
}
