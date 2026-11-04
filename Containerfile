# Provider payload image for the Foo cloud, assembled from the artifacts the
# Cluster API provider already publishes. No clone, no compiler, no build of
# the provider: every provider-owned byte in this image is copied out of an
# official release.
#
#   podman build -t quay.io/<you>/cluster-api-provider-foo-openshift:dev .
#
# Foo has no Cluster API provider of its own; it reuses Cluster API Provider
# AWS (CAPA). That is the only thing unusual about this repository, and it is
# deliberate -- it keeps the example runnable end to end on a real cloud while
# the parts that matter, the ones below, stay provider-agnostic.
#
# The result is consumed by `openshift-install` when install-config.yaml sets
#   platform:
#     external:
#       platformName: foo
#       cloudControllerManager: External
#       clusterAPI:
#         name: foo
#         controller:
#           sourceType: image
#           image: quay.io/<you>/cluster-api-provider-foo-openshift@sha256:<digest>
#
# The installer pulls this image, extracts it into capiInstallerPath (default
# <install-dir>/capi-installer), validates the layout declared in
# openshift.yaml, renders the two template trees, and runs bin/controller as a
# local process against its own ephemeral Cluster API control plane.
#
# This repository's root *is* the payload root, one file or directory per
# layout key in openshift.yaml. Nothing is copied with `COPY . /`: each path
# is named explicitly below, so repository furniture -- README.md, .git,
# CI configuration -- stays out of the image. Adding a file to the repository
# does not add it to the payload.
#
# Every provider input is pinned twice over: the controller by image digest,
# the two release manifests by SHA-256. A build that cannot reproduce those
# digests fails before it produces an image.

# --- stage 1: the provider's own released controller image ------------------
#
# registry.k8s.io/cluster-api-aws/cluster-api-aws-controller is the image the
# CAPA release publishes and the one a CAPA user would deploy into a
# management cluster. Its ENTRYPOINT is /manager, a statically linked amd64
# ELF -- which is what makes copying it out viable at all. The installer runs
# the controller as an ordinary host process, not in a container, so a
# dynamically linked binary would have to match a libc the payload author
# cannot know. Verify this for your own provider before adopting the pattern:
#
#   id=$(podman create <provider-controller-image>)
#   podman cp "$id":/manager ./manager && podman rm "$id"
#   file ./manager      # must say "statically linked"
#
# Pinned by digest, with the tag kept alongside it for readability. The tag is
# also what selects the matching release assets in stage 2, so the two cannot
# silently drift to different provider versions.
#
# On AWS this version is deliberately *not* the CAPA revision the installer
# vendors (installer/cluster-api/providers/aws/go.mod pins
# sigs.k8s.io/cluster-api-provider-aws/v2 v2.10.1-0.20260226000023-67627b2da0df).
# The installer embeds CAPA, so a payload reusing that build could not
# distinguish "ran the binary it was handed" from "ran the binary it already
# had". Shipping a different, upstream-released version removes the ambiguity:
# the version the controller logs at startup is proof of which binary ran.
# A provider that the installer does not embed has no such problem and can
# ship whatever version it releases.
ARG PROVIDER_IMAGE=registry.k8s.io/cluster-api-aws/cluster-api-aws-controller
ARG PROVIDER_VERSION=v2.13.1
ARG PROVIDER_DIGEST=sha256:4ac82a803f8913e36d74cd463145d3a6816e9de2fae2ef16ab117e4e31387400

# The throwaway fetcher for stage 2, declared here because only an ARG that
# precedes the first FROM is global enough to be expanded in a later FROM line.
ARG FETCH_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal
ARG FETCH_DIGEST=sha256:dfa0eb04abc59221544e74862432496add1f491f915c9b531880f91affc0e12c

FROM ${PROVIDER_IMAGE}:${PROVIDER_VERSION}@${PROVIDER_DIGEST} AS controller

# --- stage 2: the provider's published release assets -----------------------
#
# infrastructure-components.yaml and metadata.yaml are published as GitHub
# release assets of the same tag as the image above. The stable URL form is
#   https://github.com/<org>/<repo>/releases/download/<tag>/<asset>
# which redirects to a short-lived, signed objectstore URL. Fetch the stable
# form and let the redirect happen -- never paste the signed one. It carries a
# bearer token in its query string, it expires within the hour, and anything
# that records it (a Containerfile, a log, a commit) records a credential.
#
# This runs in a throwaway stage with a shell rather than as `ADD --checksum`
# in the payload stage, which would be shorter. ADD --checksum needs podman
# 5.0 or BuildKit, and a reference implementation that only builds on the
# newest toolchain is not much of a reference: podman 4.9, the version on
# current Ubuntu and on GitHub's runners, fails it with a misleading
# "ADD only supports the --chmod and --chown flag". `sha256sum -c` is portable
# to every builder and states the pin just as plainly.
#
# Re-derive both values when bumping PROVIDER_VERSION:
#
#   for f in infrastructure-components.yaml metadata.yaml; do
#     curl -sSL "${PROVIDER_RELEASES}/${PROVIDER_VERSION}/$f" | sha256sum | sed "s|-|$f|"
#   done
#
# These two assets have no upstream checksum file -- CAPA's published
# checksums.txt covers only the clusterawsadm and clusterctl-aws binaries --
# so the values below were computed from the downloaded assets and are pinned
# here as this build's own record of what it expects.
#
# The fetcher is pinned by digest too, and is registry.access.redhat.com
# rather than Docker Hub so that a CI build cannot fail on an anonymous pull
# rate limit. Nothing from this stage reaches the payload except the two
# verified files.
FROM ${FETCH_IMAGE}@${FETCH_DIGEST} AS assets

ARG PROVIDER_VERSION
ARG PROVIDER_RELEASES=https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download
ARG PROVIDER_COMPONENTS_SHA256=sha256:6fb76f0e60ddccad21c726c755bd24d52d227e4336f2b2a7f285e42090a40db1
ARG PROVIDER_METADATA_SHA256=sha256:5b8f97c9f03ab0f77621bbbbf8b15383c47c63c42f43a523fe4a1da6bd1b3e3a

WORKDIR /assets
RUN set -eu; \
    for f in infrastructure-components.yaml metadata.yaml; do \
      curl -fsSL --retry 3 --retry-delay 2 \
        -o "$f" "${PROVIDER_RELEASES}/${PROVIDER_VERSION}/$f"; \
    done; \
    printf '%s  %s\n%s  %s\n' \
      "${PROVIDER_COMPONENTS_SHA256#sha256:}" infrastructure-components.yaml \
      "${PROVIDER_METADATA_SHA256#sha256:}"   metadata.yaml \
      | sha256sum -c -

# --- stage 3: the payload ---------------------------------------------------
#
# scratch, deliberately. openshift.yaml declares every path the payload
# contains and the installer rejects an executable the payload did not
# declare, so a conventional base image is not merely wasteful here -- its
# /bin and /usr/bin would fail layout validation. The image filesystem is the
# payload and nothing else.
FROM scratch

ARG PROVIDER_IMAGE
ARG PROVIDER_VERSION
ARG PROVIDER_DIGEST

# Renamed on the way in. openshift.yaml declares `controller: bin/controller`,
# a name that is the same for every provider, so the installer's layout
# validation does not have to know that this one calls its binary `manager`.
COPY --from=controller --chmod=0755 /manager /bin/controller

# Only the CustomResourceDefinitions and webhook configurations in the bundle
# are ever applied: the installer runs the controller as an OS process, so the
# Namespace, RBAC, Service, Deployment and cert-manager objects it also
# contains are inert, and so is its ${AWS_B64ENCODED_CREDENTIALS} Secret slot.
# The image therefore carries no credential and nothing customer-specific --
# it is a generic, multi-tenant artifact, which is the requirement for any
# provider payload.
COPY --from=assets --chmod=0644 /assets/infrastructure-components.yaml /infrastructure-components.yaml
COPY --from=assets --chmod=0644 /assets/metadata.yaml                  /metadata.yaml

# The OpenShift-specific descriptor and clusterctl's own metadata.yaml are a
# pair: metadata.yaml carries the Cluster API contract, openshift.yaml carries
# the Kubernetes compatibility range and the layout map.
COPY openshift.yaml /openshift.yaml

# Rendered by the installer with clusterctl substitution -- ${VAR},
# ${VAR=default}, ${VAR:="default"}. INSTALLER_-prefixed variables come from
# the installer; the rest come from platform.external.clusterAPI.variables in
# install-config.yaml. An unresolvable variable fails validation before any
# cloud call.
#
# cluster-api/ is applied to the installer's local, ephemeral control plane and
# never reaches the cluster. manifests/ is folded into <install-dir>/manifests/
# and does reach the cluster. Same syntax, different destinations and
# lifetimes, which is why openshift.yaml declares them as two keys.
COPY cluster-api/ /cluster-api/
COPY manifests/   /manifests/

# Copied verbatim, never rendered. The hooks expand
# ${OPENSHIFT_INSTALL_INFRA_ID}, ${REGION} and others as *shell* variables at
# run time; substituting them at render time would destroy the scripts.
#
# Only the three hook programs are executable. lib/common.sh is sourced,
# never run, and layout validation rejects any executable the descriptor
# does not declare -- so it is copied with the mode it has in the tree.
COPY --chmod=0755 hooks/*.sh /hooks/
COPY hooks/lib/   /hooks/lib/

LABEL org.opencontainers.image.title="OpenShift platform-external provider payload (Foo)" \
      org.opencontainers.image.description="Reference provider payload image for installing OpenShift on Foo with platform: external and openshift-install CAPI provisioning." \
      org.opencontainers.image.source="https://github.com/mtulio/cluster-api-provider-foo-openshift" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${PROVIDER_VERSION}" \
      io.openshift.external-capi.provider="foo" \
      io.openshift.external-capi.upstream-image="${PROVIDER_IMAGE}:${PROVIDER_VERSION}@${PROVIDER_DIGEST}"
