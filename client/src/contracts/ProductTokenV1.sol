pragma solidity ^0.8.3;

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
                UserInfo storage user = userInfo[msg.sender];
                PoolInfo storage pool = poolInfo;
                uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
                if(pending > 0) {
                    instance.transfer(msg.sender, pending);
                }
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

        _updateSellStaking(amount_, isHarvest_);

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

        uint256 tradinReturn = calculateTradinReturn(amount_);
        _updateSupplierFee(fee.mul(1e13).div(2e13).add(tradinReturn));
        reimburseAmount = reimburseAmount.sub(fee);
        _addEscrow(amount_,  _tokenUtils.toOrigValue(reimburseAmount, INDEX_HIGH));
        _burn(msg.sender, amount_);
        tradeinCount = tradeinCount + amount_;
        tradeinReserveBalance = tradeinReserveBalance.add(tradinReturn);

        _updateSellStaking(amount_, isHarvest_);

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

    function _updateSellStaking(uint32 amount_, bool isHarvest_) internal virtual {
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
                    IERC20(highAddress).transfer(msg.sender, pending);

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

    function getCurrentPriceByIds(uint256 ids_) external view virtual returns (uint256) {
        require(_tokenUtils.isSupportIds(ids_), 'not support');
        return _tokenUtils.toOrigValue(getCurrentPrice(), ids_);
    }

    function updateSupplierInfo( address wallet_) external onlyOwner {
        require(wallet_!=address(0), "Address is invalid");
        supplier.wallet = wallet_;
    }

    function claimSupplier(uint256 amount_) external virtual {
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

    function _updateSupplierFee(uint256 fee) internal virtual {
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
    function _refund(address buyer_, uint256 value_) internal virtual override {
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

    function getUserReward(address addr_) external virtual returns (uint256) {
        if(userInfo[addr_].amount > 0) {
            UserInfo storage user = userInfo[msg.sender];
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
