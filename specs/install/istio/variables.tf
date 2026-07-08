variable "nrn" {
  description = "NullPlatform Resource Name (namespace-level, e.g. organization=<org>:account=<account>:namespace=<namespace>) where the service definition is registered."
  type        = string
}

variable "tags_selectors" {
  description = "Agent tag selectors for the notification channels (must match the tags the target agent registers with)."
  type        = map(string)
}

variable "scope_specification_id" {
  description = "ID of the scope specification whose deploy workflow should be hooked with the container-scope-override — i.e. the scope spec that the applications path-router routes to deploy under."
  type        = string
}

variable "scope_specification_slug" {
  description = "Slug of the scope specification identified by scope_specification_id."
  type        = string
}

variable "override_repo_path" {
  description = "Path on the agent's filesystem where this repository is checked out (used to resolve overrides_service_path)."
  type        = string
  default     = "/root/.np/nullplatform/services-path-router"
}

variable "agent_service_path" {
  description = "Path on the agent's filesystem passed as --service-path so the agent's entrypoint resolves this service's scripts and specs."
  type        = string
  default     = "/root/.np/nullplatform/services-path-router"
}

variable "service_name" {
  description = "Display name for the Path Router service in nullplatform."
  type        = string
  default     = "Path Router"
}

variable "repository_org" {
  description = "GitHub organization owning the services-path-router repository."
  type        = string
  default     = "nullplatform"
}

variable "repository_name" {
  description = "Repository name containing the path-router service spec templates."
  type        = string
  default     = "services-path-router"
}

variable "repository_branch" {
  description = "Branch of the services-path-router repository to register the service spec/links/entrypoint from."
  type        = string
  default     = "main"
}

variable "repository_token" {
  description = "Access token for private repositories. Unnecessary once services-path-router is public."
  type        = string
  default     = null
  sensitive   = true
}
