// Spawned by process-boundary tests: start a gateway from the JSON config in GATEWAY_CONFIG.
import { createGateway } from '../../engine/gateway/index.mjs';
await createGateway(JSON.parse(process.env.GATEWAY_CONFIG));
