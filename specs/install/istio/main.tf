################################################################################
# Install — registers the path-router service definition and its agent
# associations (notification channels) on a nullplatform account.
#
# path-router creates no AWS (or other cloud) infrastructure, so this is the
# only registration step needed. It covers:
#   1. the service specification (service_definition)
#   2. the service-level notification channel, so the agent's entrypoint gets
#      invoked for path-router's own create/update/delete/link actions
#      (service_definition_agent_association)
#   3. the scope-level container-scope-override hook that keeps HTTPRoutes in
#      sync during blue/green deployments of the scopes path-router routes to
#      (scope_definition_agent_association)
#
# See ../../../README.md ("Tofu Implementation") for the full picture,
# including the Gateway env vars, base_domain enum, and DNS steps this
# registration alone does not cover.
################################################################################

locals {
  service_path      = "."
  available_links   = ["connect"]
  available_actions = []
}

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v4.5.1"

  nrn               = var.nrn
  repository_org    = var.repository_org
  repository_name   = var.repository_name
  repository_branch = var.repository_branch
  repository_token  = var.repository_token
  service_path      = local.service_path
  service_name      = var.service_name
  available_links   = local.available_links
  available_actions = local.available_actions
}

module "service_definition_association_api_key" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/api_key?ref=v4.5.1"

  type               = "scope_notification"
  nrn                = var.nrn
  specification_slug = "k8s"
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v4.5.1"

  nrn                          = var.nrn
  repository_service_spec_repo = "${var.repository_org}/${var.repository_name}"
  service_path                 = local.service_path
  service_specification_slug   = module.service_definition.service_specification_slug
  api_key                      = module.service_definition_association_api_key.api_key
  tags_selectors               = var.tags_selectors
  agent_arguments              = ["--service-path=${var.agent_service_path}"]
}

module "scope_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_definition_agent_association?ref=v4.5.1"

  nrn                      = var.nrn
  tags_selectors           = var.tags_selectors
  api_key                  = module.service_definition_association_api_key.api_key
  scope_specification_id   = var.scope_specification_id
  scope_specification_slug = var.scope_specification_slug
  enabled_override         = true
  override_repo_path       = var.override_repo_path
  overrides_service_path   = "/container-scope-override"
}
