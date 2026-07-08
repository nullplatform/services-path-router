# Install — registering the path-router service

This directory holds the reference OpenTofu/Terraform used to **install**
path-router on a nullplatform account: registering its service
specification, agent association (notification channel), and the
`container-scope-override` hook on the target scope specification, so
`np service create` starts routing actions to an agent and deployments of
the routed scopes keep their `HTTPRoute` in sync.

Unlike `rds-postgres-server`/`rds-postgres-db`, path-router has no separate
`requirements/` step — it creates no cloud infrastructure, so there is no
AssumeRole (or equivalent) IAM setup to provision beforehand.

## Layout

```
install/
├── README.md          (this file)
└── istio/              Working example (only ingress type implemented today)
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

## Using the example

```bash
cp -r specs/install/istio /path/to/your/infra/path-router
cd /path/to/your/infra/path-router
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

tofu init
tofu apply
```

`tags_selectors` must match the tag selectors of the agent(s) that should
pick up path-router actions (the same selectors passed as `tags_selectors`
to the `nullplatform/agent` tofu-module).

`scope_specification_id`/`scope_specification_slug` identify the scope spec
whose deploy workflow gets the `container-scope-override` hook — i.e. the
type of application that will be routed to via path-router. Run this once
per scope specification that needs blue/green sync; see the top-level
[`README.md`](../../README.md#3-register-the-container-scope-override-on-the-target-scope-specification)
for the failure mode to watch out for if a scope specification's `for_each`
list of override paths ever falls out of sync with the services actually
registered on the account.

This only registers the service with the platform and wires the deployment
hook — it does not create the Gateway API resources or DNS records the
service needs to actually route traffic. See the top-level
[`README.md`](../../README.md) ("Requirements") for those steps.
