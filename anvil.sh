#!/bin/sh
. ./.env
anvil --fork-url $FORK_RPC --mnemonic "$PASSPHRASE"