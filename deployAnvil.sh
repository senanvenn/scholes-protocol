#!/bin/zsh

# Run anvil.sh in another shell before running this

# To load the variables in the .env file
source .env

# To deploy and verify our contract
forge script script/DeployAnvil.s.sol:Deploy --rpc-url "http://127.0.0.1:8545/" --sender $SENDER --private-key $PRIVATE_KEY --broadcast -v

source push_artifacts.sh "DeployAnvil.s.sol/421613"

# cd web
# npm run build