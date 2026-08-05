# Security policy

## Supported version

IrohBeam `0.1.x` receives security fixes while it is the current release line.

## Reporting

Do not open a public issue for a suspected vulnerability. Email
roman.heinrich@gmail.com with reproduction steps, affected versions, and impact.
Please allow a reasonable coordinated-disclosure window.

## Operational boundaries

- Keep each live endpoint private key distinct and protect identity files.
- Treat relay bearer tokens as credentials and rotate relay configuration after exposure.
- Treat endpoint tickets as public but potentially address-disclosing.
- Validate authenticated endpoint IDs at the application admission boundary.
- Choose byte, connection, accept, stream, and timeout limits appropriate to the deployment.
- Precompiled archives are accepted only when their published SHA-256 digest matches the package manifest.

IrohBeam provides transport primitives, not application authorization, message framing, replay protection above QUIC, membership, RPC, or relay uptime.
