# syntax=docker/dockerfile:1
#
# path-router service worker image, on the lean gRPC worker bridge. The bridge
# dials over gRPC and runs the bash entrypoint on each package-exec action;
# this image adds the cluster tooling the workflows call and bakes the service
# in, so the package-exec channel needs no cmdline.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.7

# Tooling the istio workflows call: kubectl (HTTPRoute apply/delete and the
# scope's Service lookups), gomplate (templates/istio/httproute.yaml.tpl) and
# yq (HTTPRoute YAML inspection in scripts/istio/*). bash, jq, np, base64 and
# curl ship in the base.
RUN apk add --no-cache kubectl gomplate yq-go

# Bake the service in. --chown so the files belong to the uid this image runs
# as: `np` chmods the action script in place at runtime, and the workflows
# write their rendered manifests under $SERVICE_PATH/output.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=path-router \
    NP_SERVICE_PATH=/app/pkg \
    NP_SCOPE_ENTRYPOINT=/app/pkg/entrypoint/entrypoint

# Hand HOME to the runtime user: the RUN steps above ran as root with HOME
# already set to /home/app by the base.
RUN chown -R 10001:10001 /home/app

# Drop root for the runtime. Numeric on purpose: k8s admission with
# runAsNonRoot resolves USER to a numeric id to prove it isn't root.
USER 10001:10001
