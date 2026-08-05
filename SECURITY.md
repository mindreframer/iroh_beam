# Security policy

## Supported version

IrohBeam `0.2.x` receives security fixes while it is the current release line.

## Reporting

Do not open a public issue for a suspected vulnerability. Email
roman.heinrich@gmail.com with reproduction steps, affected versions, and impact.
Please allow a reasonable coordinated-disclosure window.

## Operational boundaries

- Keep each live endpoint private key distinct and protect identity files.
- Treat relay bearer tokens as credentials and rotate relay configuration after exposure.
- Treat endpoint tickets as public but potentially address-disclosing.
- Validate authenticated endpoint IDs at the application admission boundary.
- For distribution, keep exact node/endpoint-ID mappings and Erlang cookies secret and current.
- Choose byte, connection, accept, stream, distribution-frame, and timeout limits appropriate to the deployment.
- Precompiled archives are accepted only when their published SHA-256 digest matches the package manifest.

IrohBeam provides transport and an optional OTP carrier. It does not provide application authorization, membership, topology management, automatic reconnect, partition healing, or relay uptime.
