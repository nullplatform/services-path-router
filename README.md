# path-router

A nullplatform `dependency` service that exposes an application's scope under a shared domain using **path-based routing** (Gateway API `HTTPRoute` on Istio). It lets multiple applications/scopes share one public or private domain, each mounted under its own path prefix (e.g. `/api-private`, `/billing`).

## What It Does

- Creates a Kubernetes Gateway API `HTTPRoute` that matches `base_domain` + `path_prefix` and forwards traffic to the target `scope`'s backend `Service`.
- Optionally strips the path prefix before forwarding (`strip_prefix`), so `/api-private/health` reaches the backend as `/health`.
- Infers which Istio Gateway to attach to (`gateway-public` or `gateway-private`) from the **target scope's own visibility** — no manual gateway selection needed.
- Detects and prevents path-prefix collisions on the same `base_domain` before creating a route.
- Hooks into the target scope's deployment lifecycle (via `container-scope-override`) to keep the `HTTPRoute` in sync during blue/green deployments, traffic switches, rollbacks, and finalization — including weighted traffic splitting between blue and green backends while a deployment is in progress.

## Architecture

```
nullplatform Application
        │
        │ service (base_domain, path_prefix, scope, strip_prefix)
        ▼
   path-router  ──────► HTTPRoute (Gateway API)
  (this service)          │  hostnames: [base_domain]
        │                 │  matches: PathPrefix(path_prefix)
        │                 │  parentRef: gateway-public | gateway-private
        │                 │  backendRefs: → target scope's Service(s)
        │
        └─ container-scope-override:
             hooks the target scope's own deployment workflow
             (initial / blue_green / switch_traffic / rollback / finalize / delete)
             to rebuild the HTTPRoute whenever the scope deploys
```

Unlike `rds-postgres-server` or other infra-provisioning services, path-router creates **no AWS infrastructure** — only Kubernetes `HTTPRoute` objects.

## Attributes

| Attribute | Type | Description |
|---|---|---|
| `base_domain` | string (enum) | Shared domain to route on. Must be pre-registered — see [Adding a New Domain](#adding-a-new-domain) below. |
| `path_prefix` | string | Path prefix to route to the target scope, e.g. `/api-private`. Must match `^/[a-zA-Z0-9_\-]+$`. |
| `scope` | string | Slug of the target scope to receive traffic. |
| `strip_prefix` | boolean | If `true` (default), the prefix is stripped before forwarding (`/api-private/health` → `/health`). |

## Requirements

Getting path-router working end-to-end requires infra outside this repo, in this order:

### 1. Agent environment variables

Set on the nullplatform agent (`extra_envs` in the agent's tofu module):

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `INGRESS_TYPE` | No | `istio` | Selects `workflows/$INGRESS_TYPE/*.yaml`. Only `istio` is implemented today. |
| `PUBLIC_GATEWAY_NAME` | No | `gateway-public` | Name of the Istio Gateway used for scopes with `visibility: public`. |
| `PRIVATE_GATEWAY_NAME` | No | `gateway-private` | Name of the Istio Gateway used for scopes with `visibility: private`. |
| `GATEWAY_NAMESPACE` | No | `gateways` | Namespace where the Gateways live. |

These all have working defaults (`scripts/istio/config`) — you only need to set them if your cluster uses different Gateway names/namespace.

> **`PATH_ROUTER_DOMAINS` is not currently used by the code.** An earlier iteration read a comma-separated domain list from this env var to populate the `base_domain` dropdown at spec-registration time, but the Gomplate array syntax it relied on (`{{ env.Getenv "PATH_ROUTER_DOMAINS" | strings.Split "," | conv.ToJSON }}`) broke `jsondecode()` in the tofu `service_definition` module used to register the spec. It was replaced with a hardcoded JSON array (see below). If this env var is still set in an agent's `extra_envs`, it's harmless but has no effect — remove it once confirmed dead, or wire it back in if the enum is reworked.

### 2. Adding a new domain

`base_domain` is a fixed enum in [`specs/service-spec.json.tpl`](specs/service-spec.json.tpl):

```json
"base_domain": {
    "type": "string",
    "title": "Base Domain",
    "description": "Shared domain for path-based routing.",
    "enum": ["path-router.example.com", "path-router.api-private.playground.nullapps.io"]
}
```

To support a new domain:
1. Add it to this `enum` array.
2. Re-register the service specification with nullplatform (however your environment installs `specs/*.json.tpl` — e.g. re-running the tofu `service_definition` module that renders and applies this template).
3. Complete the DNS step below **before** anyone tries to create a path-router service with that domain — otherwise the route will exist in the cluster but nothing will resolve to it.

### 3. DNS record pointing at the load balancer

**path-router does not create or manage DNS records.** It only creates the `HTTPRoute`; something external has to route requests for `base_domain` to the cluster's ingress load balancer, or the route is unreachable no matter how correctly it's configured.

For every domain added to the `base_domain` enum, create a DNS record (A/ALIAS if using Route53, or CNAME otherwise) pointing at the **ALB that fronts the gateway matching the domain's intended visibility**:

| Visibility | Gateway | Ingress (namespace `gateways`) | ALB |
|---|---|---|---|
| Public | `gateway-public` | `gateway-alb-public` | Internet-facing ALB (`k8s-nullplatform-internet-facing-*.elb.amazonaws.com`) |
| Private | `gateway-private` | `gateway-alb-private` | Internal ALB (`internal-k8s-nullplatform-internal-*.elb.amazonaws.com`) |

Get the exact hostname for your cluster with:

```bash
kubectl get ingress -n gateways gateway-alb-public  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
kubectl get ingress -n gateways gateway-alb-private -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Example Route53 alias record:

```
path-router.example.com.  A (Alias)  →  dualstack.k8s-nullplatform-internet-facing-xxxxxxxxxx.us-east-1.elb.amazonaws.com.
```

Note: **which gateway/ALB to point at depends on the visibility of the scopes you intend to route to**, not on the domain name itself — path-router inspects the target scope's `visibility` at request-routing time (`scripts/istio/build_httproute`) and attaches the `HTTPRoute` to the matching Gateway automatically. If a single `base_domain` is ever used to route to scopes of mixed visibility, only one Gateway/ALB will be reachable at a time per route — keep one domain per visibility tier to avoid surprises.

## Tofu Implementation (Registering the Service)

path-router itself creates no AWS infrastructure, but it still needs to be **registered with nullplatform and wired to the agent** via `nullplatform/tofu-modules`. This is normally done in the account's platform-provisioning tofu project (e.g. `services-testing` / `ifr-platformups-*`), not in this repo. Three module calls are involved — a ready-to-copy working example lives in [`specs/install/istio`](specs/install/istio):

### 1. Register the service specification

Renders and pushes `specs/service-spec.json.tpl` (and its `available_links`) to nullplatform as a service specification:

```hcl
module "service_definition_path_router" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v4.5.1"

  nrn               = var.nrn                    # target namespace/account NRN
  repository_org    = "nullplatform"
  repository_name   = "services-path-router"
  repository_branch = "main"                       # or the branch you're testing
  repository_token  = var.repository_token
  service_path      = "."                          # root of the repo
  service_name      = "Path Router"
  available_links   = ["connect"]
  available_actions = []
}
```

### 2. Associate the agent with the service (service-level actions)

Creates the notification channel so the agent's `entrypoint` gets invoked for this service's own `create`/`update`/`delete`/`link` actions:

```hcl
module "service_definition_association_api_key" {
  source             = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/api_key?ref=v4.5.1"
  type               = "scope_notification"
  nrn                = var.nrn
  specification_slug = "k8s"
}

module "service_definition_channel_association_path_router" {
  source                        = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v4.5.1"
  nrn                           = var.nrn
  repository_service_spec_repo  = "nullplatform/services-path-router"
  service_path                  = "."
  service_specification_slug    = module.service_definition_path_router.service_specification_slug
  api_key                       = module.service_definition_association_api_key.api_key
  tags_selectors                = var.tags_selectors_path_router   # e.g. { owner = "api-private" }
  agent_arguments                = ["--service-path=/root/.np/nullplatform/services-path-router"]
}
```

### 3. Register the `container-scope-override` on the target scope specification

This is the piece that powers [Blue/Green Deployment Sync](#bluegreen-deployment-sync). It does **not** hook into path-router's own service specification — it hooks into the **scope specification** of the applications path-router will route to, so their deploy workflow calls `container-scope-override/deployment/sync_router` on every blue/green step.

`enabled_override` / `override_repo_path` / `overrides_service_path` are just extra inputs on the standard `scope_definition_agent_association` module — **not** a separate mechanism. If the target scope already has a `scope_definition_agent_association` module call in your project (registering its normal action-notification channel), add these three inputs to that **same** call instead of adding a second one:

```hcl
module "scope_definition_agent_association" {
  source                   = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_definition_agent_association?ref=v4.5.1"
  nrn                      = var.nrn
  tags_selectors           = var.tags_selectors
  api_key                  = module.scope_definition_agent_association_api_key.api_key
  scope_specification_id   = module.scope_definition.service_specification_id
  scope_specification_slug = module.scope_definition.service_slug

  # path-router container-scope-override — added to the scope's existing channel,
  # not a separate module instance (see warning below).
  enabled_override        = true
  override_repo_path      = "/root/.np/nullplatform/services-path-router"
  overrides_service_path  = "/container-scope-override"
}
```

> **Don't add a second `scope_definition_agent_association`-based module call for the same scope just to carry the override.** The channel's `filters` are built solely from `scope_specification_slug` / `scope_specification_id` (see `k8s/specs/notification-channel.json.tpl` in `nullplatform/scopes`) — `enabled_override` doesn't change them, it only appends `--overrides-path=...` to the channel's `cmdline`. Two module calls pointed at the same scope produce two `nullplatform_notification_channel` resources with **identical filters**, so every action notification for that scope fires both channels: the base entrypoint logic runs twice, once per channel, and one of the two invocations additionally triggers the override sync. Only reach for a dedicated `scope_channel_association`-style module (below) when the target scope does **not** already have its own agent association in your project.

If the target scope has no existing `scope_definition_agent_association` in your project (e.g. it's a shared scope another team owns and you're only adding the override), register a dedicated instance instead:

```hcl
module "scope_channel_association" {
  for_each = toset([
    "/container-scope-override",
    # add one entry per service that ships a container-scope-override directory
  ])

  source                   = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_definition_agent_association?ref=v4.5.1"
  nrn                      = var.nrn
  tags_selectors           = var.tags_selectors_path_router
  api_key                  = module.service_definition_association_api_key.api_key
  scope_specification_id   = var.scope_specification_id      # the scope spec apps deploy under
  scope_specification_slug = var.scope_specification_slug
  enabled_override         = true
  override_repo_path       = "/root/.np/nullplatform/services-path-router"
  overrides_service_path   = each.value
}
```

> **This `for_each` list is the actual mechanism behind the blue-green sync — and the actual failure mode to watch for.** Every path in the set gets its `container-scope-override` invoked on **every** deployment event of the target scope, unconditionally. If an entry stays in this list after its corresponding service has been removed from nullplatform (e.g. a leftover `"/endpoint-exposer/container-scope-override"` from a decommissioned service), that override still fires on every blue/green deploy, fails when it can't resolve a service specification, and **rolls back the entire deployment** — even though it has nothing to do with path-router. Keep this list in sync with the services actually registered in the account, in addition to keeping the services repo checkout itself up to date (see the note under Blue/Green Deployment Sync below).

## How Routing Works

On `create`/`update` (`workflows/istio/{create,update}.yaml`):
1. `find k8s namespace` — locates the `nullplatform` namespace.
2. `build context` — resolves the target scope.
3. `check path conflict` (`scripts/istio/check_path_conflict`) — fails the action if another `HTTPRoute` already serves the same `base_domain` + `path_prefix`.
4. `delete existing httproute` — removes any prior route for this service (idempotent update).
5. `build httproute` (`scripts/istio/build_httproute` → `build_rule` → `templates/istio/httproute.yaml.tpl`) — resolves the scope's backend `Service`(s), infers the Gateway from scope visibility, and renders the `HTTPRoute` manifest. If the scope has an in-progress blue/green deployment, this step builds a weighted `blue_green_annotation` splitting traffic between the blue and green `Service`s instead of a single backend.
6. `apply` — applies the manifest with `kubectl`.

On `delete` (`workflows/istio/delete.yaml`): deletes all `HTTPRoute`s created for the service.

## Blue/Green Deployment Sync

`container-scope-override/` hooks into the **target scope's own** deployment workflow (not path-router's own workflow) so the route stays correct as the scope deploys:

| Scope deployment step | Override workflow | What it does |
|---|---|---|
| Initial deploy | `initial.yaml` | Rebuilds the route once the first version is live. |
| Blue/green start | `blue_green.yaml` | Rebuilds the route with blue=100%, green=0% once the new pods are ready. |
| Traffic switch | `switch_traffic.yaml` | Rebuilds the route with the deployment's current `desired_switched_traffic` weight. |
| Rollback | `rollback.yaml` | Rebuilds the route pointing back at the surviving (green) backend after the failed blue deployment is torn down. |
| Finalize | `finalize.yaml` | Rebuilds the route pointing at the single finalized backend once blue/green concludes. |
| Delete | `delete.yaml` | Cleans up when the scope itself is deleted. |

All of these invoke `container-scope-override/deployment/sync_router`, which looks up the path-router service instance for the current application (`SERVICE_SPECIFICATION_SLUG=path-router`, set in `container-scope-override/values.yaml`) and triggers its `update-path-router` action, then polls until it completes. **If no path-router service exists for the application, this step exits cleanly (status 0) — it's a no-op, not an error.**

> Which override directories actually get invoked is controlled by the `scope_channel_association` tofu resource's `for_each` set (see [Tofu Implementation](#3-register-the-container-scope-override-on-the-target-scope-specification) above) — it is **not** derived from scanning the filesystem. Two things both need to hold for this to work reliably: (1) the `for_each` list must only contain paths for services still registered in nullplatform — a leftover entry for a decommissioned service fails and **rolls back the entire deployment**, unrelated to path-router; and (2) the agent's checkout of this repo must actually contain the directory each listed path points to — an unmerged/stale feature branch missing a path that's still in the `for_each` list will fail the same way. Keep both the tofu `for_each` list and the branch in sync with what's actually deployed.

## Known Limitations

- `base_domain` is a static enum (see [Adding a New Domain](#adding-a-new-domain)) — there is no dynamic domain list today.
- DNS is entirely out of band — nothing in this service or in nullplatform provisions it automatically.
- Mixed-visibility routing on a single `base_domain` is not supported (see the DNS table note above).
