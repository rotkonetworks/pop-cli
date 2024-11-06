#!/bin/bash
# scripts/deploy_registrar.sh
# Deploy registrar using sudo XCM call on development networks
# Author: Your Friendly Neighborhood Dev

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
PARA_ID=1004
CALL_DATA="0x3200001cbd2d43530a44705ad088af313e18f80b53ef16b36177cd4b77b846f2a5f07c"

usage() {
    cat << EOF
Usage:
    $0 <relay_chain_endpoint>

Description:
    Deploys a registrar using sudo XCM call on a development network.
    Uses //Alice as sudo (default for development networks).

Arguments:
    relay_chain_endpoint    WebSocket endpoint of the relay chain
                           e.g., ws://127.0.0.1:9944 or wss://dev.rotko.net/rococo

Example:
    $0 ws://127.0.0.1:9944
    $0 wss://dev.rotko.net/rococo

EOF
    exit 1
}

# Log functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

# Check arguments
if [ $# -ne 1 ]; then
    usage
fi

RELAY_WS=$1

# Validate WebSocket URL format
if [[ ! $RELAY_WS =~ ^(wss?:\/\/).+ ]]; then
    error "Invalid WebSocket URL format. Must start with ws:// or wss://"
    usage
fi

# Check if node and npm are installed
if ! command -v node > /dev/null; then
    error "nodejs is not installed. Please install nodejs first."
    exit 1
fi

if ! command -v npm > /dev/null; then
    error "npm is not installed. Please install npm first."
    exit 1
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

log "Setting up deployment environment..."
log "Using relay chain endpoint: ${RELAY_WS}"
log "Parachain ID: ${PARA_ID}"

# Initialize npm project and install dependencies
npm init -y > /dev/null 2>&1
npm install @polkadot/api@latest @polkadot/util-crypto@latest > /dev/null 2>&1

# Create the deployment script
cat > deploy.js << 'EOL'
const { ApiPromise, WsProvider, Keyring } = require('@polkadot/api');
const { cryptoWaitReady } = require('@polkadot/util-crypto');

const RELAY_WS = process.env.RELAY_WS;
const PARA_ID = parseInt(process.env.PARA_ID);
const CALL_DATA = process.env.CALL_DATA;

async function deployRegistrar() {
    console.log(`Connecting to relay chain at ${RELAY_WS}`);
    const provider = new WsProvider(RELAY_WS);
    const api = await ApiPromise.create({ provider });
    
    await cryptoWaitReady();
    const keyring = new Keyring({ type: 'sr25519' });
    const sudo = keyring.addFromUri('//Alice');
    
    console.log(`Using sudo account (Alice): ${sudo.address}`);

    const destination = {
        V4: {
            parents: 0,
            interior: {
                X1: [{ Parachain: PARA_ID }]
            }
        }
    };

    const message = {
        V4: [{
            UnpaidExecution: {
                weightLimit: 'Unlimited',
                checkOrigin: null
            }
        }, {
            Transact: {
                originKind: 'Superuser',
                requireWeightAtMost: {
                    refTime: 5000000000,
                    proofSize: 50000
                },
                call: {
                    encoded: CALL_DATA
                }
            }
        }]
    };

    console.log('Preparing sudo XCM transaction...');
    
    return new Promise((resolve, reject) => {
        const sudoCall = api.tx.sudo.sudo(
            api.tx.xcmPallet.send(destination, message)
        );

        sudoCall
            .signAndSend(sudo, ({ events = [], status }) => {
                console.log(`Status: ${status.type}`);

                if (status.isFinalized) {
                    console.log(`Finalized at block hash: ${status.asFinalized.toHex()}`);
                    
                    const errors = events.filter(({ event }) => 
                        api.events.system.ExtrinsicFailed.is(event)
                    );

                    if (errors.length > 0) {
                        reject(new Error('Transaction failed'));
                    } else {
                        const success = events.filter(({ event }) =>
                            api.events.system.ExtrinsicSuccess.is(event)
                        );
                        if (success.length > 0) {
                            resolve(status.asFinalized.toHex());
                        }
                    }
                }
            })
            .catch(reject);
    });
}

deployRegistrar()
    .then((blockHash) => {
        console.log(`Deployment successful! Block hash: ${blockHash}`);
        process.exit(0);
    })
    .catch((error) => {
        console.error('Deployment failed:', error);
        process.exit(1);
    });
EOL

log "Executing deployment..."

# Run the deployment script
NODE_PATH="$TEMP_DIR/node_modules" \
RELAY_WS="$RELAY_WS" \
PARA_ID="$PARA_ID" \
CALL_DATA="$CALL_DATA" \
node deploy.js

# Cleanup
rm -rf "$TEMP_DIR"

success "Deployment script completed!"
