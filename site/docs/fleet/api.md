---
title: Operator JSON API
description: Versioned, authenticated REST API for reading rig status and queueing validated fleet commands.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Operator JSON API

Use the fleet API from an automation job or a client of your own. It is disabled
unless `FLEET_API_TOKEN` is configured; it is separate from the browser password
and must be stored as a secret and sent only over HTTPS. Generate a random value
with at least 32 characters. Do not put it in browser code, a URL, a log, or a
repository.

The machine-readable OpenAPI 3.1 contract is available at
`/api/v1/openapi.json`. It describes the request and response formats and can be
used to generate clients. The API uses JSON and bearer authentication; it does
not enable cross-origin browser access.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FLEET_API_TOKEN" \
  'https://fleet.example.com/api/v1/devices?limit=50'

curl --fail-with-body -X POST \
  -H "Authorization: Bearer $FLEET_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"command":"setup","args":{"mode":"safe","maxtemp":72,"threads":8} }' \
  'https://fleet.example.com/api/v1/devices/ZMR-1A2B-3C4D-5E6F/commands'
```

## Endpoints

| Method and path | Purpose |
| --- | --- |
| `GET /api/v1/devices?limit=50&after=<id>` | List enrolled rigs in stable ID order; `limit` is 1–100 and `next_cursor` continues the page. |
| `GET /api/v1/devices/{id}` | Read one enrolled rig's reported status and queue depth. |
| `GET /api/v1/audit?limit=50` | Review recent operator actions without exposing command payloads. |
| `POST /api/v1/devices/{id}/commands` | Validate and queue one action or setup update. |
| `GET /api/v1/openapi.json` | Read the API contract; this endpoint is public and contains no fleet data. |

Every control response is `202 Accepted`: the command is queued and applies on
the rig's next check-in, not immediately. The response includes a command ID.
The API accepts `start`, `stop`, `restart`, `update`, `reboot`, `log`, and
`setup`. Setup accepts only documented fields (`wallet`, `pool`, `coin`, `mode`,
`threads`, `worker`, and `maxtemp`) and validates them before queueing. `maxtemp`
requires safe mode. An unsupported command, extra field, invalid wallet, or
full queue is rejected without changing the rig.

```json
{"command":"setup","args":{"mode":"safe","maxtemp":72,"threads":"auto"} }
```

List responses are cursor-paginated and device views never include rig keys,
enrolment codes, or queued command bodies. Fleet status may include settings
that the authenticated operator needs to inspect. Requests have a 16 KiB body
limit, a per-client rate limit, and structured JSON errors. API actions enter the
same bounded queue and audit trail as dashboard and chat actions.

## Security and operating limits

- Use one secret per deployment and rotate it by updating the environment and
  restarting the service. The API currently uses one operator token, not
  per-user scopes; anyone holding it can read and control every enrolled rig.
- Authentication is in the `Authorization` header only. The token is never
  accepted in query parameters or cookies.
- The service does not add CORS headers. Call it from a trusted backend, not
  directly from a public website.
- The JSON state store and its bounded command/audit history are designed for a
  small self-hosted fleet, not a multi-tenant service. For larger deployments,
  use a durable database and explicit per-operator authorization before
  exposing it to additional users.
- Pool and mining infrastructure remain self-hosted development tools; the API
  is not a hosted mining or pool service.
