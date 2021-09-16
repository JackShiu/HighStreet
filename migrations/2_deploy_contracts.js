
/* HIGH */
const HSToken = artifacts.require("HSToken");

/* PRODUCT TOKEN */
const TokenV0 = artifacts.require("ProductTokenV0");
const TokenV1 = artifacts.require("ProductTokenV1");
const Factory = artifacts.require("TokenFactory");
const ERC1967Proxy = artifacts.require('ERC1967Proxy');
const BancorBondingCurve = artifacts.require('BancorBondingCurve');
const UpgradeableBeacon = artifacts.require('UpgradeableBeacon');
const TokenUtils = artifacts.require('TokenUtils');

let zeroAddress = "0x0000000000000000000000000000000000000000";

module.exports = async function (deployer, network, accounts ) {
	let owner = accounts[0];

	let isDeployHigh = false;
	if(isDeployHigh) {
		await deployer.deploy(HSToken, owner, {from:owner, overwrite: false});
	}

	let isDeployProductToken = true;
	if(isDeployProductToken){

		await deployer.deploy(BancorBondingCurve, {from:owner, overwrite: false});
		const BancorBondingCurveImpl = await BancorBondingCurve.deployed();
		const BondingCurveAddress = BancorBondingCurveImpl.address;

		await deployer.deploy(TokenV0, {from:owner, overwrite: false});
		const tokenImplV0 = await TokenV0.deployed();

		await deployer.deploy(UpgradeableBeacon, tokenImplV0.address, {from:owner, overwrite: false});
		const beacon = await UpgradeableBeacon.deployed();

		await deployer.deploy(Factory, {from:owner, overwrite: false});
		const factoyImpl = await Factory.deployed();

		await deployer.deploy(TokenUtils, {from:owner, overwrite: false});
		const tokenUtils = await TokenUtils.deployed();

		// TEST +++++
		//1. upgradeable contract
		// const data = factoyImpl.contract.methods.initialize(beacon.address).encodeABI();
		// await deployer.deploy(ERC1967Proxy,factoyImpl.address, data);
		// const factoyProxy = await ERC1967Proxy.deployed();
		// const factoryInstance = await Factory.at(factoyProxy.address);
		// TEST ==========
		//2.  factory isn't upgradeable
		const factoryInstance = factoyImpl;
		factoyImpl.initialize(beacon.address);
		// TEST -------

		let isUpgradeToV1 =false;
		if(isUpgradeToV1) {
			await deployer.deploy(TokenV1, {from:owner, overwrite: false});
			const tokenImplV1 = await TokenV1.deployed();
			await beacon.upgradeTo(tokenImplV1.address);
		}

		let isDeployProduct = true;
		if(isDeployProduct) {
			const name = "HighGO";
			const exp = '330000';
			const max = '500';
			const offset = '10';
			const baseReserve = web3.utils.toWei('0.33', 'ether');
			const val = tokenImplV1
							.contract
							.methods
							.initialize('HighGO', 'HG', BondingCurveAddress, exp, max, offset, baseReserve).encodeABI();
			await factoryInstance.createToken(
				name, val
			);
			const highGOAddress = await factoryInstance.retrieveToken("HighGO");
			const highGOToken = await TokenV1.at(highGOAddress);
			highGOToken.setupTokenUtils(tokenUtils.address);

			//default launch token directly
			await highGOToken.launch();
		}

		let isSetupVoucher = false;
		let tokenId;
		if(isSetupVoucher) {
			let voucherAddress;
			if(network == 'rinkeby') {
				voucherAddress =  "0x84285280fC626b50C4aC1e0Ca555AaBc0aED9DbC";
				tokenId = 10;
			} else if(network == 'mainnet') {
				voucherAddress = "0x0000000000000000000000000000000000000000";
				tokenId = 0;
			}
			console.log('voucher address:', voucherAddress);
			await highGOToken.setupVoucher(voucherAddress ,10, true);
		}

		// 如果最後需要提款的話，才呼叫這個
		let isClaimVoucher =false;
		if(isClaimVoucher) {
			const highGOAddress = await factoryInstance.retrieveToken("HighGO");
			const highGOToken = await TokenV1.at(highGOAddress);
			await highGOToken.claimVoucher(TokenId);
		}
	}
};
