const hre = require('hardhat')

const sleep = (delay) => new Promise((resolve) => setTimeout(resolve, delay * 1000));

async function main () {
  const ethers = hre.ethers
  const upgrades = hre.upgrades;

  console.log('network:', await ethers.provider.getNetwork())

  const signer = (await ethers.getSigners())[0]
  console.log('signer:', await signer.getAddress())


  let MoonstarAddress = '0x4AD910956D7E08cC9b2BB0e991c9998ee86DDB8d';
  let MoonstarNFTAddress = '';
  let MoonstarFactoryAddress = '';
  let AdminAddress = '0xc2A79DdAF7e95C141C20aa1B10F3411540562FF7';
  /**
   *  Deploy Moonstar Token
   */
  if(0) {
    const Moonstar = await ethers.getContractFactory('Moonstar', {
      signer: (await ethers.getSigners())[0]
    })
  
    const MoonstarContract = await Moonstar.deploy();
    await MoonstarContract.deployed()
  
    MoonstarAddress = MoonstarContract.address;
    console.log('MoonstarContract deployed to:', MoonstarContract.address)
    
    await sleep(60);
    await hre.run("verify:verify", {
      address: MoonstarContract.address,
      contract: "contracts/Moonstar.sol:Moonstar",
      constructorArguments: [],
    })
  
    console.log('MoonstarContract verified')
  }

  /**
 *  Deploy Moonstar NFT Token
 */
  if(0) {
    const MoonstarNFT = await ethers.getContractFactory('MoonstarNFT', {
      signer: (await ethers.getSigners())[0]
    })
  
    const MoonstarNFTContract = await MoonstarNFT.deploy();
    await MoonstarNFTContract.deployed()
  
    MoonstarNFTAddress = MoonstarNFTContract.address;
    console.log('MoonstarNFTContract deployed to:', MoonstarNFTContract.address)
    
    await sleep(60);
    await hre.run("verify:verify", {
      address: MoonstarNFTContract.address,
      contract: "contracts/MoonstarNFT.sol:MoonstarNFT",
      constructorArguments: [],
    })
  
    console.log('MoonstarNFTContract verified')
  }
  

  /**
   *  Deploy Moonstar Factory Proxy
   */
  if(1) {
    const MoonstarFactory = await ethers.getContractFactory('MoonstarFactory', {
      signer: (await ethers.getSigners())[0]
    })
  
    const MoonstarFactoryContract = await upgrades.deployProxy(MoonstarFactory, 
      [MoonstarAddress, AdminAddress],
      {initializer: 'initialize',kind: 'uups'});
    await MoonstarFactoryContract.deployed()
  
    console.log('Moonstar Factory  deployed to:', MoonstarFactoryContract.address)
    MoonstarFactoryAddress = MoonstarFactoryContract.address;
  }

  if(0) {
    const MoonstarFactoryV2 = await ethers.getContractFactory('MoonstarFactory', {
      signer: (await ethers.getSigners())[0]
    })
  
    await upgrades.upgradeProxy(MoonstarFactoryAddress, MoonstarFactoryV2);

    console.log('MoonstarFactory V2 upgraded')
  }

  /**
   *  Deploy Moonstar Reserve Auction1
   */
  if(0) {
    const ReserveAuction = await ethers.getContractFactory('ReserveAuction', {
      signer: (await ethers.getSigners())[0]
    })
  
    const ReserveAuctionContract = await ReserveAuction.deploy(MoonstarNFTAddress, MoonstarAddress, AdminAddress);
    await ReserveAuctionContract.deployed()
  
    console.log('ReserveAuctionContract deployed to:', ReserveAuctionContract.address)
    
    await sleep(60);
    await hre.run("verify:verify", {
      address: ReserveAuctionContract.address,
      contract: "contracts/ReserveAuction.sol:ReserveAuction",
      constructorArguments: [MoonstarNFTAddress, MoonstarAddress, AdminAddress],
    })
  
    console.log('ReserveAuctionContract verified')
  
    /**
     *  Deploy Moonstar Reserve Auction3
     */
     const ReserveAuctionV3 = await ethers.getContractFactory('ReserveAuctionV3', {
      signer: (await ethers.getSigners())[0]
    })
  
    const ReserveAuctionV3Contract = await ReserveAuctionV3.deploy(MoonstarNFTAddress, MoonstarAddress, AdminAddress);
    await ReserveAuctionV3Contract.deployed()
  
    console.log('ReserveAuctionV3Contract deployed to:', ReserveAuctionV3Contract.address)
    
    await sleep(60);
    await hre.run("verify:verify", {
      address: ReserveAuctionV3Contract.address,
      contract: "contracts/ReserveAuctionV3.sol:ReserveAuctionV3",
      constructorArguments: [MoonstarNFTAddress, MoonstarAddress, AdminAddress],
    })
  
    console.log('ReserveAuctionV3Contract verified')
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error)
    process.exit(1)
  })
