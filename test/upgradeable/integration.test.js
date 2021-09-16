const { deployProxy } = require('@openzeppelin/truffle-upgrades');
const { BN, expectRevert, expectEvent } = require('@openzeppelin/test-helpers');
const { expect, assert } = require('chai');

const TokenFactoryProxy = artifacts.require('TokenFactoryProxy');
const TokenFactory = artifacts.require('TokenFactory');
// const ProductToken = artifacts.require('ProductToken');
const ProductTokenV0 = artifacts.require('ProductTokenV0');
const ProductTokenV1 = artifacts.require('ProductTokenV1');
const BondingCurve = artifacts.require('BancorBondingCurve');
const UpgradeableBeacon = artifacts.require('ProductUpgradeableBeacon');
const TokenUtils = artifacts.require('TokenUtils');
/* MOCK */
const VoucherMock = artifacts.require('VoucherMock');
const DaiMock = artifacts.require('DaiMock');
const ChainLinkMock = artifacts.require('ChainLinkMock');
const TokenFactoryV1Mock = artifacts.require('TokenFactoryV1Mock');


require('chai')
	.use(require('chai-as-promised'))
	.use(require('chai-bn')(BN))
	.should()

contract('integration flow check', function (accounts) {
    /*
     * boinding curve basic parameters
    */
	const exp = '330000';
	const max = '500';
	const offset = '10';
	const baseReserve = web3.utils.toWei('0.33', 'ether');

    /* GLOBAL PARAMETERS*/
    const DEG = false;
    const numberToBigNumber = (val) => web3.utils.toWei(val.toString(), 'ether');
    const bigNumberToNumber = (val) => web3.utils.fromWei(val.toString(), 'ether');
    const DaiEtherRatio = numberToBigNumber(0.0003223554);
    const HsTokenEtherRatio = numberToBigNumber(0.5);

    const  INDEX_ETH  = 0;
    const  INDEX_HIGH = 1;
    const  INDEX_DAI  = 2;

    const showUserInfo = async (tag, info) => {
        console.log(tag, "User:amount       :",bigNumberToNumber(info.amount));
        console.log(tag, "User:rewardDebt   :",bigNumberToNumber(info.rewardDebt));
        info.records.forEach((v,i)=> console.log("User:records:",i ,bigNumberToNumber(v)))
    }
    const showPoolInfo = async (info) => {
        console.log("Pool:amount           :",bigNumberToNumber(info.amount));
        console.log("Pool:accRewardPerShare:",bigNumberToNumber(info.accRewardPerShare));
        console.log("Pool:tokenReward      :",bigNumberToNumber(info.tokenReward));
    }

    const printEscrowList = async (list) => await list.reduce( async (_prev, val, index) => {
          const ESCROW_STATE = ['INITIAL', 'AWAITING_PROCESSING', 'COMPLETE_USER_REFUND', 'COMPLETE'];
          const state = ESCROW_STATE[val[0]];
          const amount = val[1];
          const value = val[2];
          console.log('index:', index, 'state:', state, 'amount:', amount, 'value:',  bigNumberToNumber(value));
          return Promise.resolve("DO_NOT_CALL");
        },0);

    before('deploy implementation', async function () {
        this.owner = accounts[0];
        this.user1 = accounts[1];
        this.user2 = accounts[2];
        this.supplier = accounts[3];

        this.factoryImpl = await TokenFactory.new();
        this.implementationV0 = await ProductTokenV0.new();
        this.bondingCurveImpl = await BondingCurve.new();
        this.tokenUtils = await TokenUtils.new();

        /*erc20 mock*/
        this.voucherMock = await VoucherMock.new();
        this.HighMock = await DaiMock.new();

        /*chainlink mock*/
        this.DaiEtherMock = await ChainLinkMock.new(DaiEtherRatio, {from: this.owner});
        this.HsTokenEtherMock = await ChainLinkMock.new(HsTokenEtherRatio, {from: this.owner});
    });

    beforeEach(async function () {
        // initial tokenfactory
        this.beacon = await UpgradeableBeacon.new(this.implementationV0.address, {from: this.owner});

        const data = await this.factoryImpl.contract.methods.initialize(this.beacon.address).encodeABI();
        this.factoryProxyImpl = await TokenFactoryProxy.new(this.factoryImpl.address, data, {from: this.owner});
        this.tokenFactory = await TokenFactory.at(this.factoryProxyImpl.address);

        // create HighGO token
        const data1 = this.implementationV0.contract
                .methods.initialize('HighGO', 'HG', this.bondingCurveImpl.address, exp, max, offset, baseReserve).encodeABI();
        await this.tokenFactory.createToken(
        "HighGO", data1, {from: this.owner}
        );

        // get HighGO token address
        this.highGoAddress = await this.tokenFactory.retrieveToken.call("HighGO");
        this.highGo = new ProductTokenV0(this.highGoAddress);
        await this.highGo.setupTokenUtils(this.tokenUtils.address);
        await this.highGo.setupVoucher(this.voucherMock.address, 10, true);
        await this.highGo.setSupplier(this.supplier, {from: this.owner});
        await this.highGo.launch({from: this.owner});
    });

    it('product token upgrade from V0 To V1', async function () {
        let { highGo,
            voucherMock,
            user1,
            user2,
            owner,
            tokenUtils,
            beacon,
            HighMock,
            DaiEtherMock,
            HsTokenEtherMock,
            highGoAddress } =this;

        await voucherMock.faucet(user1, numberToBigNumber(10000));
        await voucherMock.faucet(user2, numberToBigNumber(10000));
        await voucherMock.faucet(owner, numberToBigNumber(10000));
        await voucherMock.faucet(highGo.address, numberToBigNumber(10000));

        // BUY BY VOUCHER
        let price = await highGo.getCurrentPrice();
        await voucherMock.approve(highGo.address, price, {from: user1});
        await highGo.buyByVoucher(0, price, {from:user1});
        console.log('user buy');
        console.log('balance:', (await highGo.balanceOf(user1)).toString());

        // BUY BY VOUCHER
        price = await highGo.getCurrentPrice();
        await voucherMock.approve(highGo.address, price, {from: user1});
        await highGo.buyByVoucher(0, price, {from:user1});
        console.log('user buy');
        console.log('balance:', (await highGo.balanceOf(user1)).toString());

        // BUY BY VOUCHER
        price = await highGo.getCurrentPrice();
        await voucherMock.approve(highGo.address, price, {from: user1});
        await highGo.buyByVoucher(0, price, {from:user1});
        console.log('user buy');
        console.log('balance:', (await highGo.balanceOf(user1)).toString());

        // BUY BY VOUCHER
        price = await highGo.getCurrentPrice();
        await voucherMock.approve(highGo.address, price, {from: user2});
        await highGo.buyByVoucher(0, price, {from:user2});
        console.log('user buy');
        console.log('balance:', (await highGo.balanceOf(user2)).toString());

        //SELL BY VOUCHER
        await highGo.sellByVoucher(0, 1, {from: user1});
        console.log('user sell');
        console.log('balance:', (await highGo.balanceOf(user1)).toString());

        // REDDEM BY VOUCHER
        await highGo.tradeinVoucher(0, 1, {from: user1});
        console.log('user redeem');
        console.log('balance:', (await highGo.balanceOf(user1)).toString());
        printEscrowList(await highGo.getEscrowHistory(user1));

        console.log('show info before upgrade');
        showPoolInfo(await highGo.getPoolInfo())
        showUserInfo('user1', await highGo.getUserInfo(user1));
        showUserInfo('user2', await highGo.getUserInfo(user2));
        let supplier = await highGo.getSupplierInfo();
        console.log('supplier', supplier);
        console.log('voucher', await highGo.voucher.call());

        //PAUSE BEFORE UPGRADE
        console.log('pause');
        await highGo.pause({from: this.owner});

        //UPGRADE
        console.log('upgrade');
        let implementationV1 = await ProductTokenV1.new();
        beacon.upgradeTo(implementationV1.address, {from: owner});

        highGo = new ProductTokenV1(highGoAddress);

        // CHECK INFO
        console.log('should info after upgrade');
        showPoolInfo(await highGo.getPoolInfo())
        showUserInfo('user1', await highGo.getUserInfo(user1));
        showUserInfo('user2', await highGo.getUserInfo(user2));

        // UPDATE CHAINLINK INFO
        await tokenUtils.updateCurrency(INDEX_HIGH, 'HIGH', HighMock.address, DaiEtherMock.address, HsTokenEtherMock.address, true );

        //SHOULD TRANSFER HIGH TO CONTRACT
        await HighMock.faucet(user1, numberToBigNumber(10000));
        await HighMock.faucet(user2, numberToBigNumber(10000));
        await HighMock.faucet(owner, numberToBigNumber(10000));
        await HighMock.faucet(highGo.address, numberToBigNumber(10000));

        // LAUNCH AFTER UPGRADE
        console.log('launch');
        await this.highGo.launch({from: this.owner});

        // SELL
        console.log('user sell');
        await highGo.sell(1, false, {from: user1});
        console.log('balance:', (await highGo.balanceOf(user1)).toString());

        // SELL
        console.log('user sell');
        await highGo.sell(1, false, {from: user2});
        console.log('balance:', (await highGo.balanceOf(user2)).toString());

        // CHECK INFO
        console.log('check info after user sell all product');
        showPoolInfo(await highGo.getPoolInfo())
        showUserInfo('user1', await highGo.getUserInfo(user1));
        showUserInfo('user2', await highGo.getUserInfo(user2));

        // BUY BY HIGH
        console.log('user buy by high');
        price = await highGo.getCurrentPriceByIds(INDEX_HIGH);
        console.log('price', bigNumberToNumber(price));
        await HighMock.approve(highGo.address, price, {from: user1});
        await highGo.buyERC20(1, price, {from: user1});
        console.log('balance:', (await highGo.balanceOf(user1)).toString());

        // TRDEIN
        console.log('user tradein');
        await highGo.tradein(1, false, {from: user1});
        console.log((await highGo.balanceOf(user1)).toString());
        printEscrowList(await highGo.getEscrowHistory(user1));
    });

    it('token factory upgrade', async function () {
        let {factoryProxyImpl, tokenFactory, implementationV0, bondingCurveImpl} = this;

        // CREATE PRODUCT
        let data = implementationV0.contract
                .methods.initialize('HighWatch', 'HW', bondingCurveImpl.address, exp, max, offset, baseReserve).encodeABI();
        await tokenFactory.createToken(
        "HighWatch", data, {from: this.owner}
        );
        let highWatchAddress = await tokenFactory.retrieveToken("HighWatch");
        console.log("highWatchAddress", highWatchAddress);

        // CREATE PRODUCT
        data = implementationV0.contract
                .methods.initialize('HighDuck', 'HD', bondingCurveImpl.address, exp, max, offset, baseReserve).encodeABI();
        await tokenFactory.createToken(
        "HighDuck", data, {from: this.owner}
        );
        let highDuckAddress = await tokenFactory.retrieveToken("HighDuck");
        console.log("highDuckAddress", highDuckAddress);

        // UPGRADE TO V1
        factoryV1 = await TokenFactoryV1Mock.new();
        tokenFactory.upgradeTo(factoryV1.address);

        tokenFactory = await TokenFactoryV1Mock.at(factoryProxyImpl.address);
        assert.equal(await tokenFactory.getVersion(), "v1 Mock");

        assert.equal(highWatchAddress, await tokenFactory.retrieveToken("HighWatch"));
        assert.equal(highDuckAddress, await tokenFactory.retrieveToken("HighDuck"));


    });
})