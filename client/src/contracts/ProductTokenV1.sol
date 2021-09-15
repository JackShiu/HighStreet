pragma solidity ^0.8.3;

import {AggregatorV3Interface as AggregatorV3Interface_v08 } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "./ProductToken.sol";
import "./interface/IVNFT.sol";
import "./interface/ITokenUtils.sol";

/// @title ProductTokenV1
/// @notice This is version 1 of the product token implementation.
/// @dev This contract builds on top of version 0 by including transaction logics, such as buy and sell transfers
///    and exchange rate computation by including a price oracle.
contract ProductTokenV1 is ProductToken {
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
        uint256 rewardPending;
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

    function setupTokenUtils(address addr_) external onlyOwner {
        require(addr_ != address(0));
        _tokenUtils = ITokenUtils(addr_);
    }

    function buyETH() external virtual payable onlyIfTradable {
        require(_tokenUtils.isSupportIds(INDEX_ETH), 'not support');
        require(msg.value > 0, "invalid value");

        uint256 accValue = _tokenUtils.toAccValue(msg.value, INDEX_ETH);

        (uint256 amount,uint256 change,,uint256 fee) = _buy(accValue);

        if (amount > 0) {
            if(change > 0) {
                change = _tokenUtils.toOrigValue(change, INDEX_ETH);
                payable(msg.sender).transfer(change);
            }
            _updateSupplierFee(fee.mul(1e12).div(8e12));
            fee = _tokenUtils.toOrigValue(fee, INDEX_HIGH);
            poolInfo.tokenReward = poolInfo.tokenReward.add(fee.mul(6e12).div(8e12));
        }else {
            payable(msg.sender).transfer(msg.value);
        }
    }

    function buyERC20(uint256 ids_, uint256 maxPrice_) external virtual onlyIfTradable {
        require(_tokenUtils.isSupportIds(ids_), 'not support');
        require(maxPrice_ > 0, "invalid max price");

        IERC20 instance =  IERC20(_tokenUtils.getAddressByIds(ids_));
        bool success = instance.transferFrom(msg.sender, address(this), maxPrice_);
        require(success, "Purchase failed.");

        uint256 accValue = _tokenUtils.toAccValue(maxPrice_, ids_);

        (uint256 amount,uint256 change, uint price, uint256 fee)  = _buy(accValue);
        if (amount > 0) {
            if(change > 0) {
                change = _tokenUtils.toOrigValue(change, ids_);
                instance.transfer(msg.sender, change);
            }
            _updateSupplierFee(fee.mul(1e12).div(8e12));
            fee = _tokenUtils.toOrigValue(fee, INDEX_HIGH);
            poolInfo.tokenReward = poolInfo.tokenReward.add(fee.mul(6e12).div(8e12));
            if(ids_ == INDEX_HIGH) {
                price = _tokenUtils.toOrigValue(price, INDEX_HIGH);
                //清算之前的給用戶
                UserInfo storage user = userInfo[msg.sender];
                PoolInfo storage pool = poolInfo;
                uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
                if(pending > 0) {
                    instance.transfer(msg.sender, pending);
                }
                // 從新計算
                poolInfo.amount = poolInfo.amount.add(price);
                updatePool();
                _updateUserInfo(price);
            }
        }else { // If token transaction failed
            instance.transfer(msg.sender, maxPrice_);
        }
    }

    function sell(uint32 amount_, bool isHarvest_) external virtual onlyIfTradable {
        require(_tokenUtils.isSupportIds(INDEX_HIGH), 'not support');
        require(balanceOf(msg.sender) >= amount_ || amount_ > 0, 'invalid amount');

        address highAddress = _tokenUtils.getAddressByIds(INDEX_HIGH);

        (uint256 price, uint256 fee )= _sellForAmount(amount_);

        _updateSellStaking(amount_, isHarvest_, false, 0);

        uint256 accValue = _tokenUtils.toOrigValue(price, INDEX_HIGH);
        bool success = IERC20(highAddress).transfer(msg.sender, accValue);
        _updateSupplierFee(fee.mul(1e12).div(2e12));
        require(success, "selling token failed");
    }

    /**
    * @dev When user wants to trade in their token for retail product
    *
    * @param amount_                   amount of tokens that user wants to trade in.
    */
    function tradein(uint32 amount_, bool isHarvest_) external virtual onlyIfTradable {
        require(_tokenUtils.isSupportIds(INDEX_HIGH), 'not support');
        require(amount_ > 0, "Amount must be non-zero.");
        require(balanceOf(msg.sender) >= amount_, "Insufficient tokens to burn.");

        (uint256 reimburseAmount, uint fee) = _sellReturn(amount_);

        //99% for supplier
        _updateSupplierFee(reimburseAmount.mul(0.99e12).div(1e12));
        reimburseAmount = reimburseAmount.sub(fee);
        _addEscrow(amount_,  _tokenUtils.toOrigValue(reimburseAmount, INDEX_HIGH));
        _burn(msg.sender, amount_);
        tradeinCount = tradeinCount + amount_;

        _updateSellStaking(amount_, isHarvest_, false, 0);

        emit Tradein(msg.sender, amount_);
    }

    function updatePool() public virtual{
        uint256 supply = poolInfo.amount;
        if (supply == 0) {
            poolInfo.accRewardPerShare = 0;
            return;
        }
        poolInfo.accRewardPerShare = poolInfo.accRewardPerShare.add(poolInfo.tokenReward.mul(1e12).div(supply));
    }

    function _updateSellStaking(uint32 amount_, bool isHarvest_, bool isVoucher_, uint256 tokenId_) internal virtual {
        if(userInfo[msg.sender].amount > 0) {
            address highAddress = _tokenUtils.getAddressByIds(INDEX_HIGH);
            UserInfo storage user = userInfo[msg.sender];
            if(isHarvest_ || balanceOf(msg.sender) <= user.records.length) {
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
                    if(isVoucher_) {
                        voucher.instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, pending);
                    } else {
                        IERC20(highAddress).transfer(msg.sender, pending);
                    }

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

    function setupVoucher(address addr_, uint256 tokenId_, bool enable_) external onlyOwner{
        require(addr_ != address(0), 'invalid address');
        voucher.addr = addr_;
        voucher.instance = IVNFT(addr_);
        voucher.tokenId = tokenId_;
        voucher.isEnable = enable_;
    }

    function pauseVoucher(bool enable_) external onlyOwner {
        voucher.isEnable = enable_;
    }

    function claimVoucher(uint256 tokenId_) external onlyOwner{
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
            poolInfo.tokenReward = poolInfo.tokenReward.add(fee.mul(6e12).div(8e12));
            UserInfo storage user = userInfo[msg.sender];
            PoolInfo storage pool = poolInfo;
            uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, pending);
            }
            poolInfo.amount = poolInfo.amount.add(price);
            updatePool();
            _updateUserInfo(price);
        } else {
            instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, maxPrice_);
        }
    }

    function sellByVoucher(uint256 tokenId_, uint32 amount_) external virtual onlyIfTradable{
        require(voucher.isEnable, 'unable to use voucher');
        (uint256 price, uint256 fee )= _sellForAmount(amount_);

        _updateSellStaking(amount_, true, true, tokenId_);

        voucher.instance.transferFrom(address(this), msg.sender, voucher.tokenId, tokenId_, price);
        _updateSupplierFee(fee.mul(1e12).div(2e12));
    }

    function tradeinVoucher(uint256 tokenId_, uint32 amount_) external virtual onlyIfTradable {
        require(amount_ > 0, "Amount must be non-zero.");
        require(balanceOf(msg.sender) >= amount_, "Insufficient tokens to burn.");

        (uint256 reimburseAmount, uint fee) = _sellReturn(amount_);

        //99% for supplier
        _updateSupplierFee(reimburseAmount.mul(0.99e12).div(1e12));
        _addEscrow(amount_,  reimburseAmount.sub(fee));
        _burn(msg.sender, amount_);
        tradeinCount = tradeinCount + amount_;

        _updateSellStaking(amount_, true, true, 0);

        emit Tradein(msg.sender, amount_);
    }


    function getCurrentPriceByIds(uint256 ids_) external view virtual returns (uint256) {
        require(_tokenUtils.isSupportIds(ids_), 'not support');
        return _tokenUtils.toOrigValue(getCurrentPrice(), ids_);
    }

    function updateSupplierInfo( address wallet_) external onlyOwner {
        require(wallet_!=address(0), "Address is invalid");
        supplier.wallet = wallet_;
    }

    function claimSupplier(uint256 amount_) external {
        require(supplier.wallet!=address(0), "wallet is invalid");
        require(msg.sender == supplier.wallet, "The address is not allowed");
        address highAddress = _tokenUtils.getAddressByIds(INDEX_HIGH);
        IERC20 high = IERC20(highAddress);
        if (amount_ <= supplier.amount){
            bool success = high.transfer(msg.sender, amount_);
            if (success) {
                supplier.amount = supplier.amount.sub(amount_);
            }
        }
    }

    function _updateSupplierFee(uint256 fee) internal {
        if( fee > 0 ) {
            uint256 charge = _tokenUtils.toOrigValue(fee, INDEX_HIGH);
            supplier.amount = supplier.amount.add(charge);
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
    function _refund(address buyer_, uint256 value_) internal override {
        address highAddress = _tokenUtils.getAddressByIds(INDEX_HIGH);

        bool success = IERC20(highAddress).transfer(buyer_, value_);
        require(success, "refund token failed");
    }

    /**
    * @dev A method allow us to withdraw liquidity (eth) from the contract
    * Since eth is not used as a return currency, we need to withdraw eth from the system.
    *
    * @param value_       the value of ether
    *
    */
    function withdrawEther(uint256 value_) payable external virtual onlyOwner {
        require(address(this).balance > 0, "no enough ether");
        payable(msg.sender).transfer(value_);
    }

    function withdrawERC20(uint256 ids_, uint256 amount_, address to_) external virtual onlyOwner{
        require(_tokenUtils.isValidIds(ids_), 'not invalid id');
        require(to_ != address(0), "invalid address");
        address highAddress = _tokenUtils.getAddressByIds(ids_);
        IERC20 instance = IERC20(highAddress);
        require(amount_ <= instance.balanceOf(address(this)), 'invalid amount');
        instance.transfer(to_, amount_);
    }

    function getUserInfo(address addr_) external view returns( UserInfo memory) {
        require(addr_ != address(0), 'invalid address');
        return userInfo[addr_];
    }

    function getPoolInfo() external view returns( PoolInfo memory) {
        return poolInfo;
    }
}
