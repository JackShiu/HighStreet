const { deployProxy } = require('@openzeppelin/truffle-upgrades');
const { BN, expectRevert, expectEvent } = require('@openzeppelin/test-helpers');
const { expect, assert } = require('chai');

const ERC1967Proxy = artifacts.require('ERC1967Proxy');
const TokenFactory = artifacts.require('TokenFactory');
const ProductToken = artifacts.require('ProductToken');
const ProductTokenV1 = artifacts.require('ProductTokenV1');
const DaiMock = artifacts.require('DaiMock');
const BondingCurve = artifacts.require('BancorBondingCurve');
const UpgradeableBeacon = artifacts.require('ProductUpgradeableBeacon');
const ChainLinkMock = artifacts.require('ChainLinkMock');
const TokenUtils = artifacts.require('TokenUtils');

require('chai')
	.use(require('chai-as-promised'))
	.use(require('chai-bn')(BN))
	.should()

contract('productTokenV1 flow check', function (accounts) {
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
    // const DaiEtherRatio = numberToBigNumber(0.0003223554);
    const DaiEtherRatio = numberToBigNumber(1);
    // const HsTokenEtherRatio = numberToBigNumber(0.5);
    const HsTokenEtherRatio = numberToBigNumber(1);

    before('deploy implementation', async function () {
        this.owner = accounts[0];
        this.user1 = accounts[1];
        this.user2 = accounts[2];
        this.supplier = accounts[3];
        this.factoryImpl = await TokenFactory.new({from: this.owner});
        this.implementationV0 = await ProductToken.new();
        this.implementationV1 = await ProductTokenV1.new();
        this.bondingCurveImpl = await BondingCurve.new();
        this.daiMock = await DaiMock.new();
        this.DaiEtherMock = await ChainLinkMock.new(DaiEtherRatio, {from: this.owner});
        this.HighMock = await DaiMock.new();
        this.HsTokenEtherMock = await ChainLinkMock.new(HsTokenEtherRatio, {from: this.owner});
        this.tokenUtils = await TokenUtils.new();
    });

    beforeEach(async function () {
        // initial tokenfactory
        const beacon = await UpgradeableBeacon.new(this.implementationV1.address, {from: this.owner});
        const data = await this.factoryImpl.contract.methods.initialize(beacon.address).encodeABI();
        const { address } = await ERC1967Proxy.new(this.factoryImpl.address, data, {from: this.owner});
        this.tokenFactory = await TokenFactory.at(address);
        this.tokenFactory.UpdateBeacon(beacon.address, {from: this.owner});

        // create HighGO token
        const data1 = this.implementationV1.contract
                .methods.initialize('HighGO', 'HG', this.bondingCurveImpl.address, exp, max, offset, baseReserve).encodeABI();
        await this.tokenFactory.createToken(
        "HighGO", data1, {from: this.owner}
        );

        // get HighGO token address
        const highGoAddress = await this.tokenFactory.retrieveToken.call("HighGO");
        this.highGo = new ProductTokenV1(highGoAddress);
        await this.highGo.setupTokenUtils(this.tokenUtils.address)
        // await this.highGo.setupHsToken(this.HighMock.address, this.HsTokenEtherMock.address);

    });

    it('should unable to trade if product have not launch', async function (){

        let { highGo, daiMock, HighMock, user1, owner, tokenUtils } =this;

        await daiMock.faucet(user1, numberToBigNumber(10000));
        await HighMock.faucet(user1, numberToBigNumber(10000));
        await HighMock.faucet(highGo.address, numberToBigNumber(10000));

        let zeroAddress = "0x0000000000000000000000000000000000000000";
        await tokenUtils.updateCurrency(0, 'ETH', zeroAddress, this.DaiEtherMock.address, zeroAddress, true );
        await tokenUtils.updateCurrency(1, 'HIGH', HighMock.address, this.DaiEtherMock.address, this.HsTokenEtherMock.address, true );
        await tokenUtils.updateCurrency(2, 'DAI', daiMock.address, zeroAddress, zeroAddress, true );
        // await highGo.addCurrency('ETH', zeroAddress, this.DaiEtherMock.address, zeroAddress, true );
        // await highGo.addCurrency('HIGH', HighMock.address, this.DaiEtherMock.address, this.HsTokenEtherMock.address, true );
        // await highGo.addCurrency('DAI', daiMock.address, zeroAddress, zeroAddress, true );
        // console.log(await highGo.getCurrencyList());

        highGo.launch({from: owner});

        let price = await highGo.getCurrentPrice();
        console.log('price', bigNumberToNumber(price));

        // ETH BUY
        price = await highGo.getCurrentPriceByIds(0); //0 is ether
        console.log('price', bigNumberToNumber(price));
        // add 0.1% for prevent Exchange loss
        price = (new BN(price)).mul(new BN(1001000)).div(new BN(1000000));
        await highGo.buyETH({from: user1, value: price})
        console.log(await highGo.balanceOf(user1));

        // HIGH BUY
        price = await highGo.getCurrentPriceByIds(1); //1 is high
        // add 0.1% for prevent Exchange loss
        price = (new BN(price)).mul(new BN(1001000)).div(new BN(1000000));
        console.log('price', bigNumberToNumber(price));
        await HighMock.approve(highGo.address, price, {from: user1});
        await highGo.buyERC20(1, price, {from: user1});
        console.log(await highGo.balanceOf(user1));

        // HIGH BUY
        price = await highGo.getCurrentPriceByIds(1); //1 is high
        // add 0.1% for prevent Exchange loss
        price = (new BN(price)).mul(new BN(1001000)).div(new BN(1000000));
        console.log('price', bigNumberToNumber(price));
        await HighMock.approve(highGo.address, price, {from: user1});
        await highGo.buyERC20(1, price, {from: user1});
        console.log(await highGo.balanceOf(user1));

        // HIGH BUY
        price = await highGo.getCurrentPriceByIds(1); //1 is high
        // add 0.1% for prevent Exchange loss
        price = (new BN(price)).mul(new BN(1001000)).div(new BN(1000000));
        console.log('price', bigNumberToNumber(price));
        await HighMock.approve(highGo.address, price, {from: user1});
        await highGo.buyERC20(1, price, {from: user1});
        console.log(await highGo.balanceOf(user1));

        // DAI BUY
        price = await highGo.getCurrentPriceByIds(2); //2 is dai
        // add 0.1% for prevent Exchange loss
        price = (new BN(price)).mul(new BN(1001000)).div(new BN(1000000));
        console.log('price', bigNumberToNumber(price));
        await daiMock.approve(highGo.address, price, {from: user1});
        await highGo.buyERC20(2, price, {from: user1}); //2 is dai
        console.log((await highGo.balanceOf(user1)).toString());

        const showUserInfo = async (info) => {
            console.log("User:amount       :",bigNumberToNumber(info.amount));
            console.log("User:rewardDebt   :",bigNumberToNumber(info.rewardDebt));
            console.log("User:rewardPending:",bigNumberToNumber(info.rewardPending));
            info.records.forEach((v,i)=> console.log("User:records:",i ,bigNumberToNumber(v)))
        }
        const showPoolInfo = async (info) => {
            console.log("Pool:amount===========:");
            console.log("Pool:amount           :",bigNumberToNumber(info.amount));
            console.log("Pool:accRewardPerShare:",bigNumberToNumber(info.accRewardPerShare));
            console.log("Pool:tokenReward      :",bigNumberToNumber(info.tokenReward));
        }

        //USER INFO
        await showUserInfo(await highGo.getUserInfo(user1))
        await showPoolInfo(await highGo.getPoolInfo())

        //SELL
        await highGo.sell(1, false, {from: user1});
        console.log(await highGo.balanceOf(user1));

        //USER INFO
        await showUserInfo(await highGo.getUserInfo(user1))
        await showPoolInfo(await highGo.getPoolInfo())

        //SELL
        await highGo.sell(1, true, {from: user1});
        console.log(await highGo.balanceOf(user1));

        //USER INFO
        console.log("CHECK++++");
        await showUserInfo(await highGo.getUserInfo(user1))
        await showPoolInfo(await highGo.getPoolInfo())

        // TRDEIN
        await highGo.tradein(1, false, {from: user1});
        console.log((await highGo.balanceOf(user1)).toString());
        // let list = await highGo.getEscrowHistory(user1);
        // console.log(list);

        //dai/high for one
        //sell with harvest or not harvest
    });

})