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
| `base_domain` | string | Shared domain to route on, already pointing at the cluster's ingress — see [Adding a new domain](#2-adding-a-new-domain) below. With several clusters, use the one served by the cluster where the target scope runs; the agent's `PATH_ROUTER_BASE_DOMAINS` refuses the others. |
| `path_prefix` | string | Path prefix to route to the target scope, e.g. `/api-private`. Must match `^/[a-zA-Z0-9_\-]+$` and be unique per `base_domain`. |
| `scope` | string | Slug of the target scope to receive traffic. It must run in the same cluster as the service and have a finalized deployment. |
| `strip_prefix` | boolean | If `true` (default), the prefix is stripped before forwarding (`/api-private/health` → `/health`). |

The service's dimensions decide which agent (cluster) runs it, so set them like the target scope's. The path router doesn't use links: creating the service is all it takes.

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
| `PATH_ROUTER_BASE_DOMAINS` | No | — | Comma-separated `base_domain` values this cluster serves. For installations where several clusters share the spec (e.g. one domain per cloud); set it on the agent or on each cluster's service channel `environment`. When set, create/update fail before touching any route if the `base_domain` isn't in the list or the target scope is deployed in another cluster. Unset, nothing is validated. |

These all have working defaults (`scripts/istio/config`) — you only need to set them if your cluster uses different Gateway names/namespace.

### 2. Adding a new domain

`base_domain` is free text, validated as a hostname. The domains a cluster serves are declared on its agent, in `PATH_ROUTER_BASE_DOMAINS` (comma-separated); with it set, create and update refuse a `base_domain` the cluster does not serve, or a target scope deployed elsewhere, before touching any route. Unset, nothing is validated and a typo ends as an `active` service whose route answers 404.

To support a new domain:
1. Add it to `PATH_ROUTER_BASE_DOMAINS` on the agent (or on the package worker's environment) of the cluster that serves it.
2. Complete the DNS step below **before** anyone creates a path-router service with that domain — otherwise the route exists in the cluster but nothing resolves to it.

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

## Install in your organization

The service is published once as the package `np-path-router` (specification "Path Router"), visible to every organization. You do not copy its specs: you install the package and use it read-only.

How installing a package works, how it coexists with a copy you registered, how to upgrade, and when to fork instead are in the [package installation guide](https://docs.nullplatform.com/docs/packages/install); this section has what is specific to this service.

Already registered a copy from the former `specs/install/istio`? It keeps working: it called tofu-modules' `service_definition` on specs that stay in every release, and the package installs next to it, as the guide explains. If you sourced that directory as a module, pin its `?ref` to a release that still has it. The copy's `base_domain` enum is replaced by `PATH_ROUTER_BASE_DOMAINS` on the agent (see [Adding a new domain](#2-adding-a-new-domain)).

Installing it touches two layers: the agent, which runs the worker and the blue/green sync, and the nullplatform layer. There is no infrastructure module: the service creates no cloud resources.

| Layer | What | Module |
|---|---|---|
| agent (Helm) | The package in `worker_orchestrated_packages`, its environment, and the `container-scope-override` on the containers package's worker | tofu-modules' [`nullplatform/agent`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/agent) |
| nullplatform (nullplatform API key) | The installation of the package and the agent channel | tofu-modules' `service_package_installation` |

Pick ONE release of this repository (the latest is on its [releases page](https://github.com/nullplatform/services-path-router/releases)) and use its version in both places below: the override the containers worker fetches is the one this release ships.

```hcl
# ── nullplatform layer ───────────────────────────────────────────────
# For a service the installation is the whole nullplatform side, channel included.
module "path_router" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_package_installation?ref=v9.16.0"

  nrn                  = var.nrn
  package_slug         = "np-path-router"
  package_version      = "X.Y.Z" # the same release, without the v
  agent_tags_selectors = { cluster = "runtime" } # must match the agent's TAGS
}
# Keeping channels in a separate bindings layer instead? Use
# nullplatform/package_installation here and service_definition_agent_association
# there, with package_slug = "np-path-router".

# ── agent (tofu-modules' nullplatform/agent) ─────────────────────────
  worker_orchestrated_packages = ["np-path-router", "np-containers"]

  worker = {
    patches = [
      # The path-router worker: the ingress stack and the domains this
      # cluster serves (scripts/istio/config has the defaults).
      {
        target = { package = "np-path-router" }
        merge = {
          spec = {
            containers = [{
              name = "worker"
              env = [
                { name = "INGRESS_TYPE", value = "istio" },
                { name = "PATH_ROUTER_BASE_DOMAINS", value = "apps.example.com" },
              ]
            }]
          }
        }
      },
      # Blue/green sync: after every deploy of a Containers scope, the
      # container-scope-override re-points the route at the new Services.
      # The containers worker runs the scopes image, which does not ship that
      # override, so an init container fetches it from this release and
      # NP_OVERRIDES_PATH (read by worker-bridge and passed to the entrypoint
      # as --overrides-path) points the scope at it. Several overrides join
      # with a comma (the Endpoint Exposer ships one too).
      {
        target = { package = "np-containers" } # or the slug of your containers package
        merge = {
          spec = {
            volumes = [{ name = "path-router-override", emptyDir = {} }]
            initContainers = [{
              name         = "fetch-path-router-override"
              image        = "public.ecr.aws/docker/library/alpine:3.20"
              command      = ["sh", "-c", "wget -qO- https://github.com/nullplatform/services-path-router/archive/refs/tags/vX.Y.Z.tar.gz | tar -xzC /overrides --strip-components=1"]
              volumeMounts = [{ name = "path-router-override", mountPath = "/overrides" }]
            }]
            containers = [{
              name         = "worker"
              volumeMounts = [{ name = "path-router-override", mountPath = "/app/overrides/path-router", readOnly = true }]
              env          = [{ name = "NP_OVERRIDES_PATH", value = "/app/overrides/path-router/container-scope-override" }]
            }]
          }
        }
      },
    ]
  }
```

To upgrade, move `package_version` and the tag of the override to the new release. See tofu-modules' [`service_package_installation`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/service_package_installation) for its inputs and outputs.

Prerequisites: an agent whose `TAGS` match the channel's `tags_selectors`, with `public.ecr.aws/nullplatform/*` in `worker.allowedRegistries` and `kubectl` access to the cluster (the worker runs as the agent's service account); Istio with the Gateway API CRDs and the `gateway-public` / `gateway-private` Gateways; and the DNS records of [Requirements](#requirements).

## How the package is published

Every release publishes a new revision of the package from this repository, in the same run that pushes the worker image ([`.github/workflows/release.yml`](./.github/workflows/release.yml)): the `publish-package` job applies [`publish`](./publish), a stack on tofu-modules' `service_package_publish`, which pins this tag's specs and the image by digest. The package version is the release tag, as for the image. The stack keeps its state where the organization secrets `PACKAGE_STATE_AWS_ACCOUNT_ID`, `PACKAGE_TFSTATE_BUCKET` and `PACKAGE_TFSTATE_REGION` point; the state role is `github-actions-<repository>-package-state` in that account, by convention.

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

All of these invoke `container-scope-override/deployment/sync_router`, which looks up the path-router service instance for the current application and triggers its `update` action, then polls until it completes. The step finds the service by its specification slug, which depends on how the spec was registered: `np-path-router` when the package is installed (the default in `container-scope-override/values.yaml`) and `path-router` for a copy registered from `specs/`. Both are looked up; `PATH_ROUTER_SERVICE_SPECIFICATION_SLUG` in the agent environment names one (also for a spec registered under any other slug). Only an **active** instance whose `scope` attribute matches the slug of the scope being deployed is selected, so applications with several path-router instances (one per scope, or leftovers whose creation failed) update the right one; an instance under each of both specs for the same scope fails the step, asking for the variable. **If no path-router specification is visible to the application, the step logs `WARNING: no service specification with slug ...` and skips the sync; if none of its services routes to the scope, it skips too — a no-op, not an error.** A payload rejected by validation fails the step immediately instead of being retried.

> Which overrides run is decided by the containers worker's `NP_OVERRIDES_PATH` (see [Install in your organization](#install-in-your-organization)): every directory listed there runs on **every** deployment event of the scope, unconditionally. An entry left for a service no longer installed only logs the warning above on each deploy; keep the list and the fetched release in sync with what is installed.

## Known Limitations

- The domains a cluster serves are not discovered: they are declared in `PATH_ROUTER_BASE_DOMAINS` (see [Adding a new domain](#2-adding-a-new-domain)).
- DNS is entirely out of band — nothing in this service or in nullplatform provisions it automatically.
- Without `PATH_ROUTER_BASE_DOMAINS`, a `base_domain` or scope of another cluster isn't detected: the service ends up `active` with a route that answers 404.
- Mixed-visibility routing on a single `base_domain` is not supported (see the DNS table note above).
