# shellcheck shell=bash
#
# SC2034 is disabled file-wide: the variables defined here are read by the
# hook programs that source this file, which a lint of this file alone
# cannot see.
# shellcheck disable=SC2034
#
# Shared library for the `platform: external` reference hooks (AWS/CAPA).
#
# Sourced, never executed -- which is why it has no shebang and no executable
# bit. That is a requirement, not tidiness: payload layout validation rejects
# any executable in the image that openshift.yaml does not declare, and this
# file is not a hook, so it must not be declared and must not be executable.
#
#
# THE FILES
#
#   lib/common.sh       this file: the contract, logging, and the two Route 53
#                       helpers that more than one phase needs.
#   infra-ready.sh      publishes api / api-int. Writes dns.json.
#   post-provision.sh   publishes *.apps. Writes apps-dns.json.
#   pre-destroy.sh      removes everything the other two created. Reads both
#                       state files and deletes them.
#
# One program per phase, because that is how the installer invokes them and
# how a reader meets them. The cost of the split is that what a phase creates
# and what removes it are no longer on the same screen, so the state files
# below are the contract that keeps the two directions honest.
#
#
# THE STATE CONTRACT
#
# ${OPENSHIFT_INSTALL_STATE_DIR} is the only channel between the three
# programs. They run minutes or hours apart, in separate processes, and
# nothing else survives between them. Two files, with these exact shapes:
#
#   dns.json        written by infra-ready, read by post-provision and
#                   pre-destroy
#     .privateHostedZoneId   the zone infra-ready created for the cluster
#                            domain. Deleted wholesale at pre-destroy, so only
#                            the id is needed.
#     .publicHostedZoneId    the base domain's public zone. NOT ours: it long
#                            outlives the cluster and holds other clusters'
#                            records.
#     .publicRecordName      "api.<cluster domain>." -- recorded by name
#                            because pre-destroy must delete exactly this
#                            record out of that shared zone and nothing else.
#     .publicRecordTarget    the internet-facing API load balancer's DNS name.
#
#   apps-dns.json   written by post-provision, read and removed by pre-destroy
#     .service               namespace/name of the ingress Service.
#     .recordName            "*.apps.<cluster domain>."
#     .publicHostedZoneId    where that record went.
#     .privateHostedZoneId   the in-VPC copy's zone, deleted with the zone.
#     .address               the load balancer address the CCM assigned.
#     .loadBalancerArn       the load balancer itself. Recorded because
#                            `destroy cluster` deletes the nodes the CCM ran
#                            on, not the Service, so nothing else will ever
#                            remove it.
#
# Either file can legitimately be absent. An install that reached infra-ready
# and no further has the first and not the second, and pre-destroy has to
# clean up whichever it finds.
#
#
# THE CONTRACT WITH THE INSTALLER
#
# The installer execs each hook directly -- no shell -- with the environment
# below and with whatever arguments the install-config gave it. Working
# directory is the install directory.
#
# Output contract: exit 0 is success and any other exit is failure. On
# failure the installer aborts, and the last few lines the program wrote are
# quoted in the installer's own error, so the last thing said before exiting
# should be the reason. Everything written to stdout and stderr is streamed
# to the installer log as it arrives, prefixed with the hook kind.
#
# Environment is the half of the input the installer owns and every hook
# shares:
#
#   OPENSHIFT_INSTALL_HOOK            "infra-ready", "post-provision" or
#                                     "pre-destroy"
#   OPENSHIFT_INSTALL_INFRA_ID        e.g. my-cluster-knzjv
#   OPENSHIFT_INSTALL_CLUSTER_NAME    e.g. my-cluster
#   OPENSHIFT_INSTALL_BASE_DOMAIN     e.g. example.com
#   OPENSHIFT_INSTALL_CLUSTER_DOMAIN  <cluster name>.<base domain>
#   OPENSHIFT_INSTALL_PUBLISH         External | Internal
#   OPENSHIFT_INSTALL_DIR             the install directory
#   OPENSHIFT_INSTALL_MANIFEST_DIR    <install dir>/external-install
#   OPENSHIFT_INSTALL_STATE_DIR       writable; what is recorded here on
#                                     infra-ready is what pre-destroy reads
#   OPENSHIFT_INSTALL_CLUSTER_JSON    PATH of a file holding the core CAPI
#                                     Cluster object as JSON
#   OPENSHIFT_INSTALL_INFRA_JSON      PATH of a file holding the provider's
#                                     infrastructure object as JSON, verbatim
#                                     from the local control plane -- unset if
#                                     there is not exactly one. A path, not
#                                     the document: the reads below pass it to
#                                     jq as a FILE argument, which is the only
#                                     correct form.
#   OPENSHIFT_INSTALL_KUBECONFIG      the installed cluster's admin
#                                     kubeconfig. Set for every hook and
#                                     usable by none until the cluster's API
#                                     is serving, which at infra-ready it is
#                                     not and at post-provision it is
#
# Arguments are the other half, and are the partner's own: the installer
# passes them through verbatim from
# platform.external.clusterAPI.hooks.<hook>.args and does not read them. Only
# post-provision takes any; the other two reject arguments rather than
# ignoring them, so a flag attached to the wrong phase is an error and not a
# silent no-op.
#
# Two of the environment entries deserve comment.
#
# OPENSHIFT_INSTALL_INFRA_JSON is the whole mechanism. The installer cannot
# read `status.networkStatus.apiServerElb.dnsName` off an AWSCluster, because
# it has no AWSCluster type and must not acquire one. It can copy the object
# out of its local control plane as JSON and let the hook dig. Every field
# these scripts read is CAPA's schema, not the installer's.
#
# OPENSHIFT_INSTALL_STATE_DIR is how destroy stays honest. Anything created
# by a hook is outside CAPI's ownership, so nothing else will ever clean it
# up. The rule on this pilot is that each new resource ships with its teardown
# in the same change, and the state files are the link between the two
# directions.
#
# AWS is the *reference* provider used to exercise the mechanism. Nothing here
# is installer code, and an OCI or other partner would write their own.

# Strict mode is each entry script's own business and is set there, before
# this file is sourced -- so that sourcing it is strict too.

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)] external-hook:" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- contract

: "${OPENSHIFT_INSTALL_HOOK:?}"
: "${OPENSHIFT_INSTALL_INFRA_ID:?}"
: "${OPENSHIFT_INSTALL_CLUSTER_DOMAIN:?}"
: "${OPENSHIFT_INSTALL_BASE_DOMAIN:?}"
: "${OPENSHIFT_INSTALL_STATE_DIR:?}"

PUBLISH=${OPENSHIFT_INSTALL_PUBLISH:-External}
INFRA_ID=${OPENSHIFT_INSTALL_INFRA_ID}
CLUSTER_DOMAIN=${OPENSHIFT_INSTALL_CLUSTER_DOMAIN}
BASE_DOMAIN=${OPENSHIFT_INSTALL_BASE_DOMAIN}
STATE=${OPENSHIFT_INSTALL_STATE_DIR}/dns.json
# The ingress half keeps its own file. It is written by a different hook
# invocation, minutes later, and either half can legitimately exist without
# the other -- an install that got as far as infra-ready and no further has
# the first and not the second, and pre-destroy has to clean up whichever it
# finds.
APPS_STATE=${OPENSHIFT_INSTALL_STATE_DIR}/apps-dns.json

# Provider-specific, and therefore this script's own business rather than the
# installer's. AWS_REGION is how the AWS CLI is configured everywhere else in
# this workspace; the hook inherits the installer's environment.
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}

for tool in aws jq; do
	command -v "${tool}" >/dev/null || die "${tool} is required and is not on PATH"
done

mkdir -p "${OPENSHIFT_INSTALL_STATE_DIR}"

# expect_hook asserts that the installer called this program for the phase it
# implements.
#
# Worth the four lines. The openshift.yaml layout names three programs by
# path, and nothing in the file prevents two entries pointing at the same one.
# A preDestroy entry mis-wired to infra-ready.sh would create a hosted zone
# and publish DNS in the middle of a teardown, exit 0, and look like success.
expect_hook() {
	[[ ${OPENSHIFT_INSTALL_HOOK} == "$1" ]] ||
		die "this program implements the $1 hook, but the installer called it as ${OPENSHIFT_INSTALL_HOOK}; check the hooks entries in openshift.yaml or install-config.yaml"
}

# reject_args refuses arguments for the two phases that take none, rather than
# ignoring them. An argument meant for post-provision and attached to the
# wrong phase is a configuration error, and silence would hide it until the
# wildcard record failed to appear.
reject_args() {
	[[ $# -eq 0 ]] || die "this hook takes no arguments, got: $*"
}
# ----------------------------------------------------------- route 53

# alias_zone maps a load balancer's DNS name to the hosted zone ID a Route 53
# alias record has to name. This is not in the provider's status -- it is an
# AWS fact about the load balancer -- so it is looked up.
#
# Filtering happens in jq, not in `--query`, and that is not a style choice.
# The AWS CLI applies `--query` to each page of a paginated response and prints
# one result per page, so a filter that matches on page 1 of 2 emits the value
# followed by a line reading `None`. Captured into a shell variable that is a
# two-line string which then fails far away from its cause -- this cost a
# NoSuchHostedZone on a zone ID that plainly existed. `--output json` returns
# the pages already merged.
alias_zone() {
	local dns=$1
	aws elbv2 describe-load-balancers --region "${REGION}" --output json |
		jq -r --arg d "${dns}" '.LoadBalancers[] | select(.DNSName==$d) | .CanonicalHostedZoneId' | head -1
}

# upsert_alias writes one A-record alias. UPSERT rather than CREATE so that a
# re-run of the hook is not an error; the installer may legitimately call it
# again after a retried provisioning step.
upsert_alias() {
	local zone_id=$1 name=$2 target_dns=$3 target_zone=$4
	log "upsert ${name} -> ${target_dns} in ${zone_id}"
	aws route53 change-resource-record-sets --hosted-zone-id "${zone_id}" \
		--change-batch "$(jq -n --arg n "${name}" --arg d "${target_dns}" --arg z "${target_zone}" '{
			Changes: [{
				Action: "UPSERT",
				ResourceRecordSet: {
					Name: $n, Type: "A",
					AliasTarget: { DNSName: $d, HostedZoneId: $z, EvaluateTargetHealth: false }
				}
			}]
		}')" >/dev/null
}
