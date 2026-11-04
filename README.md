# cluster-api-provider-foo-openshift

Reference implementation of a **provider payload image** — the artifact a cloud provider
publishes so that `openshift-install` can provision infrastructure on their platform with
`platform: external` and their own Cluster API provider.

This repository is the whole thing: a `Containerfile` and the files it packages. Build it,
push it, point an `install-config.yaml` at the digest, and `openshift-install create cluster`
does the rest.

## "Foo" is CAPA

Foo is a fictional cloud. It has no Cluster API provider of its own, so it reuses
**Cluster API Provider AWS (CAPA)** and runs on real AWS. That is the only unusual thing
here, and it is deliberate: it keeps the example runnable end to end while everything that
matters — the descriptor, the templates, the hooks, the packaging — stays
provider-agnostic. Where you read `AWSCluster` or `AWS_REGION`, a real provider reads
their own kinds and their own variables.

Nothing in `openshift-install` knows that Foo exists. There is no Foo code path, no Foo
feature gate and no Foo entry in any installer table. That is the point of the mechanism.

## The repository root is the payload root

`openshift.yaml` declares a layout, and every path it declares is a file or directory in
this repository. The installer extracts the image into `capiInstallerPath` (default
`<install-dir>/capi-installer`) and validates that layout before it makes a single cloud
call.

| Path | `openshift.yaml` key | Where it comes from | Reaches the cluster? |
| --- | --- | --- | --- |
| `bin/controller` | `layout.controller` | copied from the provider's released controller image at build time | no — runs as a local installer process |
| `infrastructure-components.yaml` | `layout.customResource` | the provider's release assets at build time | no — only its CRDs and webhooks are applied, to the local control plane |
| `metadata.yaml` | — | the provider's release assets at build time | no |
| `openshift.yaml` | — | this repository | no |
| `cluster-api/` | `layout.clusterTemplates` | this repository | **no** — applied to the installer's ephemeral control plane |
| `manifests/` | `layout.manifestTemplates` | this repository | **yes** — folded into `<install-dir>/manifests/` |
| `hooks/` | `layout.hooks.*` | this repository | no — run on the installer host |

The three build-time files are not committed. They are fetched by the `Containerfile`,
pinned by digest and SHA-256, and a build that cannot reproduce those digests fails.

`cluster-api/` and `manifests/` look alike and are not alike: same `${VAR}` syntax, two
different destinations and two different lifetimes. That is why they are separate keys
rather than one rendered directory.

## Build

```sh
podman build -t quay.io/<you>/cluster-api-provider-foo-openshift:v0.1.0 .
```

Any builder will do — podman, docker, buildah. The release assets are fetched and
checksummed in a throwaway stage rather than with `ADD --checksum`, which would have
imposed a podman 5.0 / BuildKit floor on everyone copying this repository.

To move to a new provider release, bump `PROVIDER_VERSION` and `PROVIDER_DIGEST` and
re-derive the two asset checksums:

```sh
V=v2.13.1
R=https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download
for f in infrastructure-components.yaml metadata.yaml; do
  curl -sSL "$R/$V/$f" | sha256sum | sed "s|-|$f|"
done
skopeo inspect docker://registry.k8s.io/cluster-api-aws/cluster-api-aws-controller:$V \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Digest"])'
```

Always fetch release assets through the stable
`https://github.com/<org>/<repo>/releases/download/<tag>/<asset>` form and let it redirect.
The URL your browser ends up on is signed, carries a bearer token in its query string and
expires within the hour — pasting it into a `Containerfile`, a log or a commit records a
credential.

## Publish and consume

```sh
podman push quay.io/<you>/cluster-api-provider-foo-openshift:v0.1.0
skopeo inspect docker://quay.io/<you>/cluster-api-provider-foo-openshift:v0.1.0 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Digest"])'
```

```yaml
platform:
  external:
    platformName: foo
    cloudControllerManager: External
    clusterAPI:
      name: foo
      controller:
        sourceType: image
        image: quay.io/<you>/cluster-api-provider-foo-openshift@sha256:<digest>
      variables:
        AWS_REGION: us-east-1
        AWS_AZ: us-east-1a
        AWS_AMI: ami-CHANGE-ME
        CCM_IMAGE: registry.k8s.io/provider-aws/cloud-controller-manager:v1.33.0
```

A conforming payload needs no path configuration at all — every path defaults beneath
`capiInstallerPath`, and `openshift.yaml` supplies the rest.

Compute replicas must be `0`: on `platform: external` the installer creates no MachineSets,
and the worker Machines in `cluster-api/machines/` are what bring the nodes up.

### Variables

Rendered with clusterctl substitution: `${VAR}`, `${VAR=default}`, `${VAR:="default"}`.
`INSTALLER_`-prefixed variables are supplied by the installer; everything else comes from
`clusterAPI.variables`. An unresolvable variable fails validation before any cloud call.

| Variable | Required | Default |
| --- | --- | --- |
| `AWS_REGION` | yes | — |
| `AWS_AZ` | yes | — |
| `AWS_AMI` | yes | — |
| `CCM_IMAGE` | yes | — |
| `AWS_INSTANCE_TYPE` | no | `m6i.xlarge` |
| `AWS_VPC_CIDR` | no | `10.0.0.0/16` |
| `AWS_SUBNET_PUBLIC_CIDR` | no | `10.0.160.0/22` |
| `AWS_SUBNET_PRIVATE_CIDR` | no | `10.0.0.0/19` |
| `INSTALLER_INFRA_ID` | — | supplied by the installer |

### Hooks

Hooks are copied verbatim and **never rendered** — they expand `${OPENSHIFT_INSTALL_INFRA_ID}`,
`${REGION}` and the rest as *shell* variables at run time, and substituting those at render
time would destroy the scripts. They receive **paths, not documents**:
`OPENSHIFT_INSTALL_INFRA_JSON`, `OPENSHIFT_INSTALL_CLUSTER_JSON`, `OPENSHIFT_INSTALL_STATE_DIR`.

| Hook | When | What it must do here |
| --- | --- | --- |
| `infraReady` | after the provider reports `Cluster.status.infrastructureReady` | publish `api` and `api-int` DNS, and write the CCM/CSI credential Secrets whose cloud identifiers only exist once the network is built |
| `postProvision` | after the cluster is up | publish the `*.apps` wildcard at the ingress load balancer |
| `preDestroy` | before `destroy cluster` tears infrastructure down | remove what the other two created |

`infraReady` is not optional in practice. Without `api-int` resolving, bootkube fails at
`resolve-api-int-url` and the install dies roughly forty minutes later at the bootstrap
timeout, with an error that points nowhere near the cause.

A payload hook has nowhere to carry command-line arguments, so each script must work from
its defaults and from the installer's environment alone. `post-provision.sh` is written
that way: it defaults to `openshift-ingress/router-external-default` and recovers the
hosted zone from the state `infra-ready.sh` recorded.

All three phases could equally be served by one script dispatching on
`OPENSHIFT_INSTALL_HOOK`. Whatever you choose, **declare every executable**: layout
validation rejects an executable the descriptor does not name, so an undeclared helper is
not "extra", it is a payload that fails to install. That is why `hooks/lib/common.sh` is
not executable — it is sourced, never run.

## Before you publish

The payload image is the provider's supported artifact. Nobody else validates it.

```sh
# export the image once; every check below reads the extracted tree
root=$(mktemp -d)
id=$(podman create <image>); podman export "$id" | tar -x -C "$root"; podman rm "$id"

# 1. the layout the descriptor promises is the layout the image has
ls -la "$root"

# 2. exactly the declared executables, and no others
find "$root" -type f -perm -u+x

# 3. the controller is statically linked — the installer runs it on the host,
#    not in a container, so it cannot rely on the image's libc
file "$root/bin/controller"       # must say "statically linked"

# 4. no credentials, no customer-specific values. The image must be generic and
#    multi-tenant; an image tied to one account is not a provider payload.
#    AKIAIOSFODNN7EXAMPLE is AWS's documentation placeholder and appears in
#    CAPA's published bundle; nothing else may match.
grep -rIoE 'BEGIN [A-Z ]*PRIVATE KEY|ssh-(rsa|ed25519|dss)|AKIA[0-9A-Z]{16}' "$root" \
  | grep -v AKIAIOSFODNN7EXAMPLE
```

All four run in CI on every pull request — see below — but run them locally before
you open one.

## Continuous integration

`.github/workflows/payload-image.yaml` builds the image, runs those four checks and
publishes to GitHub Container Registry:

| Event | Tag |
| --- | --- |
| pull request | `PR-<number>`, overwritten on each push to that PR |
| push to `main` | `main` |
| push of a `v*` tag | the tag, plus `latest` for a final `vX.Y.Z` only |

Untagged versions left behind by an overwritten `PR-<number>` are pruned after each
push, so an active pull request costs one image, not one per commit.

A pull request from a fork is built and verified but not published: its `GITHUB_TOKEN`
is read-only for packages. Nothing in the job needs a secret beyond that token.

Consume a published image **by digest**, not by tag — the job prints the digest in its
summary. `PR-<number>` and `main` are moving tags and are for testing, not for an
install you intend to keep.

`infrastructure-components.yaml` contains a `Secret` with an `${AWS_B64ENCODED_CREDENTIALS}`
slot and a `Deployment` and `ServiceAccount` that are never applied — the installer runs the
controller as an OS process and applies only the CRDs and webhook configurations. Those
objects are inert here, which is what lets the provider's own published bundle be used
unmodified and still carry no credential.

## What is not in this image

- **No cloud credentials.** On `platform: external` the installer holds none by design.
  The controller takes them from the environment the installer starts it in; the hooks use
  the operator's own cloud CLI configuration.
- **No OpenShift release content.** Red Hat supports the release payload; the provider
  supports what the provider ships.
- **Nothing from the installer's Cluster API control plane.** It is local to the installer
  process and ephemeral. Its objects, and especially its Secrets, never reach the installed
  cluster.
- **No repository furniture.** The `Containerfile` names each path explicitly rather than
  copying `.`, so adding a file here does not add it to the payload. `README.md`,
  `LICENSE`, `.github/` and `.git` are all outside the image.

## License

Apache License 2.0 — see [LICENSE](LICENSE). The upstream artifacts the build pulls in
carry their own licenses: the CAPA controller binary and release manifests are
Apache-2.0 from [kubernetes-sigs/cluster-api-provider-aws](https://github.com/kubernetes-sigs/cluster-api-provider-aws).
