#!/usr/bin/env bash
#
# PostProvision hook for `platform: external` with a Cluster API
# infrastructure provider -- AWS/CAPA reference implementation.
#
# Publishes the `*.apps` ingress wildcard. Writes apps-dns.json.
#
#
# WHY IT IS HERE AND NOT IN INFRA-READY
#
# `*.apps` cannot be created at infra-ready, and the reason is structural
# rather than a matter of ordering. At infra-ready nothing exists but what the
# infrastructure provider built, and on this platform the provider does not
# build an ingress load balancer for anyone.
#
# It cannot: CAPA's `reconcileLBAttachment` returns early for anything that is
# not a control-plane machine
# (cluster-api-provider-aws/controllers/awsmachine_controller.go:1040-1043) and
# registration adds a machine to *every* target group on the load balancer
# (pkg/cloud/services/elb/loadbalancer.go:1044-1056), so
# `controlPlaneLoadBalancer.additionalListeners` on 80/443 would register
# control-plane nodes into the ingress target groups and never a worker --
# worse than doing nothing. The field is named for and scoped to the control
# plane load balancer and it means it. This is not an argument against the
# field: ../cluster-api/cluster.yaml uses it correctly for port 22623, because
# the Machine Config Server runs on the control-plane nodes, which is exactly
# the set CAPA registers. It works for any control-plane-hosted service and
# fails for any worker-hosted one, and routers are worker-hosted.
#
# Nor does the ingress operator ask for one. On `platform: external` it selects
# `endpointPublishingStrategy.type: HostNetwork`, so the routers bind 80 and
# 443 on the nodes and the only Service the operator creates is a ClusterIP.
#
# So the cluster asks for its own, and the only thing on this platform that can
# answer is the cloud controller manager the partner already had to supply.
# `../manifests/99_external-03-ingress-nlb.yaml` is a
# `Service type=LoadBalancer` that the installer delivers as a day-0 manifest;
# the partner's CCM reconciles it into a real load balancer some minutes into
# bootstrap, and the address it gets is assigned then, at runtime, by the
# cloud. Nothing at infra-ready could have known it.
#
# post-provision is where it is knowable. It runs after the control-plane
# machines exist and before the installer waits for bootstrap to complete, so
# this hook waits for that Service to be given an address and publishes the
# wildcard. Waiting here does not deadlock: the operators that need `*.apps`
# are authentication and console, and neither is required for bootstrap to
# complete.
#
#
# WHAT IT STILL DOES NOT DO
#
# Nothing here creates the Service. The installer delivers the manifest and
# the cluster applies it; this hook only reads the address the cluster's own
# CCM put on it. If no CCM is delivered, the Service stays Pending, this hook
# times out and says so, and that is the correct outcome -- the wildcard would
# otherwise point at nothing.
#
#
# ARGUMENTS
#
# The installer passes these through verbatim from
# platform.external.clusterAPI.hooks.postProvision.args and does not read
# them. This is the only one of the three hooks that takes any.
#
#   --input-service <namespace>/<name>   the Service whose load balancer
#                                        address the ingress wildcard must
#                                        point at (default
#                                        openshift-ingress/router-external-default,
#                                        the Service this artifact set's own
#                                        99_external-03-ingress-nlb.yaml
#                                        creates)
#   --input-dns-zone <hostedZoneId>      the public hosted zone to publish the
#                                        wildcard in. Optional: infra-ready
#                                        already resolved the base domain's
#                                        public zone and recorded it, so this
#                                        is an override for the case where the
#                                        wildcard belongs somewhere other than
#                                        the zone the api record went into
#   --timeout-seconds <n>                how long to wait for that address
#                                        (default 1800)
#
# All three have defaults on purpose. In image mode this hook is delivered
# inside the provider payload and the install-config supplies no hook
# arguments, so a required flag would be a flag no payload could satisfy.
#
# Flags rather than positional arguments or more environment variables,
# because this is a script today and may be a compiled binary tomorrow, and
# because `--input-dns-zone Z123` can be copied out of the installer log and
# rerun by hand. The same three flags would be the binary's flags.
#
# See lib/common.sh for the environment contract, the state file shapes, and
# the shared Route 53 helpers.

set -euo pipefail

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

expect_hook post-provision

# --------------------------------------------------------------- inputs

# parse_post_provision_args reads this hook's own contract off argv.
#
# Both `--flag value` and `--flag=value` are accepted because both are what
# people type, and an unknown flag is an error rather than something ignored:
# a misspelled --input-dns-zone that is silently dropped would publish the
# wildcard into no zone at all and report success.
# Both inputs have a default, and neither default is a guess about the
# environment.
#
# INPUT_SERVICE names the Service that this artifact set's own
# 99_external-03-ingress-nlb.yaml creates, so it is a fact about the manifests
# shipped alongside this hook. Override it only if you replaced that manifest.
#
# INPUT_DNS_ZONE is empty here and resolved from infra-ready's recorded state
# below, because the zone is already known by then.
#
# The defaults matter beyond convenience: in image mode this hook is delivered
# inside the provider payload and the install-config supplies no hook
# arguments at all, so a hook that *required* either of these could not run
# from a payload.
INPUT_SERVICE="openshift-ingress/router-external-default"
INPUT_DNS_ZONE=""
INPUT_TIMEOUT=1800

parse_post_provision_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--input-service=*) INPUT_SERVICE=${1#*=} ;;
		--input-service)
			INPUT_SERVICE=${2:-}
			shift
			;;
		--input-dns-zone=*) INPUT_DNS_ZONE=${1#*=} ;;
		--input-dns-zone)
			INPUT_DNS_ZONE=${2:-}
			shift
			;;
		--timeout-seconds=*) INPUT_TIMEOUT=${1#*=} ;;
		--timeout-seconds)
			INPUT_TIMEOUT=${2:-}
			shift
			;;
		*) die "unknown argument ${1}; this hook takes --input-service <namespace>/<name>, --input-dns-zone <hostedZoneId> and --timeout-seconds <n>" ;;
		esac
		shift
	done
}

# kube_cmd picks the client this hook will use. oc and kubectl are
# interchangeable for the one read below; whichever is on PATH is fine.
kube_cmd() {
	local c
	for c in oc kubectl; do
		if command -v "${c}" >/dev/null; then
			printf '%s' "${c}"
			return 0
		fi
	done
	die "oc or kubectl is required on PATH for the post-provision hook and neither is there"
}

# service_address polls until the cluster's own cloud controller manager has
# given the Service an address.
#
# hostname first and ip second, in one jsonpath, because which one a cloud
# fills in is a property of the cloud: AWS returns a hostname for an NLB, and
# other providers return an address. Only one is ever set, so concatenating
# them yields whichever exists.
service_address() {
	local kube=$1 kubeconfig=$2 ns=$3 name=$4 deadline=$5
	local address=""
	while :; do
		address=$("${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s \
			-n "${ns}" get service "${name}" \
			-o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' \
			2>/dev/null || true)
		if [[ -n ${address} ]]; then
			printf '%s' "${address}"
			return 0
		fi
		if [[ $(date +%s) -ge ${deadline} ]]; then
			return 1
		fi
		sleep 15
	done
}

# ----------------------------------------------------------------- main

main() {
	parse_post_provision_args "$@"

	[[ -n ${INPUT_SERVICE} ]] || die "--input-service <namespace>/<name> is required"
	[[ ${INPUT_SERVICE} == */* ]] || die "--input-service must be namespace/name, got ${INPUT_SERVICE}"
	[[ ${INPUT_TIMEOUT} =~ ^[0-9]+$ ]] || die "--timeout-seconds must be a whole number, got ${INPUT_TIMEOUT}"
	local ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}

	local kubeconfig=${OPENSHIFT_INSTALL_KUBECONFIG:-${OPENSHIFT_INSTALL_DIR:-.}/auth/kubeconfig}
	[[ -f ${kubeconfig} ]] || die "no kubeconfig at ${kubeconfig}; this hook reads the Service from the cluster being installed"
	local kube
	kube=$(kube_cmd)

	# The wait is long on purpose. Between this hook starting and the Service
	# getting an address, the cluster has to finish applying its day-0
	# manifests, schedule the partner's cloud controller manager onto a
	# tainted master, have it clear node.cloudprovider.kubernetes.io/
	# uninitialized, and only then reconcile the Service into a real load
	# balancer. Twenty minutes is ordinary; the default of 30 leaves room.
	local deadline=$(($(date +%s) + INPUT_TIMEOUT))
	log "waiting up to ${INPUT_TIMEOUT}s for ${INPUT_SERVICE} to be given a load balancer address"
	local address
	if ! address=$(service_address "${kube}" "${kubeconfig}" "${ns}" "${name}" "${deadline}"); then
		die "${INPUT_SERVICE} still has no status.loadBalancer.ingress after ${INPUT_TIMEOUT}s. Nothing on this platform creates that address except the cloud controller manager the partner supplies, so either it is not running or it cannot reconcile the Service; check 'oc -n ${ns} describe service ${name}' and the CCM's logs"
	fi
	log "${INPUT_SERVICE} has address ${address}"

	local target_zone
	target_zone=$(alias_zone "${address}")
	[[ -n ${target_zone} ]] || die "no alias hosted zone for ${address}; it does not look like an ELBv2 load balancer in ${REGION}"

	local wildcard="*.apps.${CLUSTER_DOMAIN}."

	# The private zone first. Every in-cluster client that resolves a route --
	# the console reaching oauth, the authentication operator's own health
	# check -- does it from inside the VPC, and without this record they get
	# NXDOMAIN even when the public record is perfect.
	local phz=""
	if [[ -f ${STATE} ]]; then
		phz=$(jq -r '.privateHostedZoneId // empty' "${STATE}")
	fi
	if [[ -n ${phz} ]]; then
		upsert_alias "${phz}" "${wildcard}" "${address}" "${target_zone}"
	else
		log "WARNING: no private hosted zone in ${STATE}; in-cluster resolution of ${wildcard} will depend on the public record"
	fi

	local pub=""
	if [[ ${PUBLISH} == "External" ]]; then
		# infra-ready already resolved the base domain's public zone, to put
		# the api record in it, and recorded the id in ${STATE}. So the zone
		# is known by now and asking the caller for it again would be asking
		# for a fact this hook already has.
		#
		# --input-dns-zone remains as an override, for the case where the
		# wildcard belongs in a different zone from the api record. It is no
		# longer required: requiring it would mean a hook delivered inside a
		# provider payload could not run, because an image cannot carry a
		# per-environment zone id.
		pub=${INPUT_DNS_ZONE}
		if [[ -z ${pub} && -f ${STATE} ]]; then
			pub=$(jq -r '.publicHostedZoneId // empty' "${STATE}")
			if [[ -n ${pub} ]]; then
				log "using the public hosted zone ${pub} that infra-ready recorded for ${BASE_DOMAIN}"
			fi
		fi
		[[ -n ${pub} ]] || die "no public hosted zone for the ${wildcard} record: infra-ready recorded none in ${STATE} and --input-dns-zone <hostedZoneId> was not given"
		pub=${pub#/hostedzone/}
		upsert_alias "${pub}" "${wildcard}" "${address}" "${target_zone}"
	else
		log "publish is ${PUBLISH}; not creating a public ${wildcard} record"
	fi

	# --- state for the teardown -------------------------------------------
	#
	# The load balancer is recorded as well as the records, and that is the
	# part worth explaining. While the cluster is alive the CCM owns it and
	# deleting the Service deletes it -- proven on a pilot cluster. But `destroy
	# cluster` does not delete the Service, it deletes the machines the
	# Service's controller was running on, so by the time anything notices,
	# there is nothing left to do the deleting. The load balancer would be
	# orphaned. Recording its ARN here is what lets pre-destroy remove it.
	local lb_arn
	lb_arn=$(aws elbv2 describe-load-balancers --region "${REGION}" --output json |
		jq -r --arg d "${address}" '.LoadBalancers[] | select(.DNSName==$d) | .LoadBalancerArn' | head -1)

	jq -n \
		--arg svc "${INPUT_SERVICE}" \
		--arg rec "${wildcard}" \
		--arg pub "${pub}" \
		--arg phz "${phz}" \
		--arg addr "${address}" \
		--arg arn "${lb_arn}" \
		'{service: $svc, recordName: $rec, publicHostedZoneId: $pub, privateHostedZoneId: $phz, address: $addr, loadBalancerArn: $arn}' \
		>"${APPS_STATE}"
	log "recorded state in ${APPS_STATE}"
	log "post-provision complete: ${wildcard} -> ${address}"
}

main "$@"
