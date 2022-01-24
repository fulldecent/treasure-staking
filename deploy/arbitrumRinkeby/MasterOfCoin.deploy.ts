import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts } = hre;
    const { deploy, execute, read } = deployments;
    const { deployer } = await getNamedAccounts();

    const magicArbitrum = "0x7693604341fDC5B73c920b8825518Ec9b6bBbb8b";
    const newOwner = "0x3D210e741cDeDeA81efCd9711Ce7ef7FEe45684B";

    await deploy('MasterOfCoin', {
      from: deployer,
      log: true,
      proxy: {
        execute: {
          methodName: "init",
          args: [magicArbitrum]
        }
      }
    })

    const MASTER_OF_COIN_ADMIN_ROLE = await read('MasterOfCoin', 'MASTER_OF_COIN_ADMIN_ROLE');

    if(!(await read('MasterOfCoin', 'hasRole', MASTER_OF_COIN_ADMIN_ROLE, newOwner))) {
      await execute(
        'MasterOfCoin',
        { from: deployer, log: true },
        'grantRole',
        MASTER_OF_COIN_ADMIN_ROLE,
        newOwner
      );
    }
};
export default func;
func.tags = ['MasterOfCoin'];
