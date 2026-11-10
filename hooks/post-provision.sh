#!/usr/bin/env bash
#
# PostProvision hook for `platform: external` with a Cluster API
# infrastructure provider -- AWS/CAPA reference implementation.
#
# Materializes the cloud controller manager's credential Secret, then
# publishes the `*.apps` ingress wildcard. Writes apps-dns.json.
#
#
# THE CREDENTIAL COMES FIRST, AND IT IS WHY THE REST OF THIS HOOK CAN FINISH
#
# The wildcard below waits for the partner's CCM to give a Service a load
# balancer address. On the pilot run that wait timed out after thirty minutes
# with the CCM in CrashLoopBackOff, and the cause was not the CCM: nothing had
# created the Secret `aws-cloud-credentials` that its Deployment mounts at
# /etc/aws. Nothing ever would have. The installer emits a cloud-credentials
# Secret only for the integrated platforms (pkg/asset/manifests/openshift.go),
# the cloud credential operator needs that same root Secret plus a
# platform-matched CredentialsRequest and has neither on External, and the
# payload must not ship one -- a credential baked into a versioned image is a
# credential published to everyone who can pull the image. So the only thing
# left that can create it is a hook, at a moment when both the credential and
# a reachable cluster API exist. post-provision is the first such moment.
#
# The AWS SDK's failure here is quiet and misleading. With
# AWS_SHARED_CREDENTIALS_FILE pointing at a path that does not exist, the SDK
# does not error -- it falls through its credential chain to the instance
# metadata service, finds no instance profile (this payload attaches none, see
# ../cluster-api/20_master.yaml), and reports a 404 from IMDS. The 404 is the
# last link of the chain, not the cause, and reading it as "the machine needs
# an instance profile" leads to provisioning IAM that nothing asked for.
#
# See lib/common.sh for the credential contract this implements and for why
# AWS_SHARED_CREDENTIALS_FILE is the only variable it supports.
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
# IT RUNS EVERY STEP, THEN FAILS AT THE END
#
# Only the credential is fail-fast. Every step after it records its failure and
# lets the next one run, and the hook exits non-zero at the very end naming
# everything that went wrong.
#
# The reason is the cost of the alternative. These steps take tens of minutes
# and each one leaves something durable behind -- a Secret, approved
# certificates, a DNS record. Stopping at the first failure throws away the
# work of the steps that would have succeeded, and makes the operator re-run a
# forty-minute install to recover a state they could have reached by hand in a
# minute. A hook that publishes `*.apps` and then reports that two nodes never
# joined leaves a cluster someone can finish; a hook that bails before
# publishing leaves one they must rebuild.
#
# The credential is the exception because it is a precondition rather than a
# step: without it no node is ever initialised, so the node wait and the
# address wait cannot succeed, and continuing would spend the entire budget
# discovering that twice.
#
#
# ARGUMENTS
#
# The installer passes none. It invokes every hook with an empty argv, so in
# an install these flags are never seen and the defaults below are the whole
# configuration. They exist so that this hook can be re-run by hand against a
# half-finished cluster from a line copied out of the installer log, which is
# the only situation in which anything but the defaults is wanted.
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
#   --timeout-seconds <n>                how long this hook may take in total
#                                        (default 2700). One budget covers all
#                                        of its waits -- for the cluster API to
#                                        serve, for the expected nodes to join,
#                                        and for that address
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
INPUT_TIMEOUT=2700

# Steps that failed but did not stop the hook. See "IT RUNS EVERY STEP, THEN
# FAILS AT THE END" above; main() turns a non-empty list into the exit code.
FAILED_STEPS=()

record_failure() {
	FAILED_STEPS+=("$1")
	# Same "ERROR:" prefix die() uses, so one grep of the hook log finds every
	# failure whether it stopped the hook or not.
	log "ERROR: $1"
}

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

# The Secret the CCM Deployment mounts, and the namespace it mounts it in.
# Both are fixed by ../manifests/99_external-02-ccm-aws.yaml, which is shipped
# alongside this hook, so they are facts about this payload rather than
# anything configurable. The key name `credentials` is fixed by that file too:
# the volume mounts at /etc/aws and the container sets
# AWS_SHARED_CREDENTIALS_FILE=/etc/aws/credentials.
CCM_NAMESPACE="openshift-cloud-controller-manager"
CCM_SECRET="aws-cloud-credentials"
CCM_SELECTOR="k8s-app=aws-cloud-controller-manager"

# ensure_cloud_credentials gives the cloud controller manager the credential
# the installer was run with.
#
# The namespace is not created here and is waited for instead. It belongs to
# the CloudControllerManager capability's payload manifests, which the
# cluster-version operator applies on the bootstrap node. Creating it here
# would mean this payload owning an OpenShift namespace it does not own
# anywhere else in the file.
#
# THAT WAIT IS NOT A FORMALITY AND ITS BUDGET IS NOT A FORMALITY EITHER.
# Measured on two pilot runs: the installer invokes post-provision about five
# minutes after `create cluster` starts, immediately after it creates the
# machine objects -- so at the moment this function is entered the bootstrap
# instance has only just been asked for and nothing is serving the API. The
# namespace cannot appear for another ten to fifteen minutes. A run was lost to
# a hardcoded ten-minute budget here, which expired a few minutes before the
# thing it was waiting for could possibly have existed.
#
# So the budget is the caller's --timeout-seconds, shared with the Service wait
# below rather than invented separately: both waits are for the cluster's own
# progress, the hook is finished when either the whole sequence completes or
# that one budget is gone, and one number is the only contract a caller can
# reason about.
#
# The Secret is piped from `create --dry-run=client` into `apply`, which is
# the idempotent form: a re-run of this hook replaces the Secret rather than
# failing on AlreadyExists. Nothing in this function writes the credential to
# stdout, to the log, or to the state directory -- only its length, which is
# enough to tell an empty file from a real one and is not the value.
ensure_cloud_credentials() {
	local kube=$1 kubeconfig=$2 deadline=$3

	local src=${AWS_SHARED_CREDENTIALS_FILE:-}
	[[ -n ${src} ]] || die "AWS_SHARED_CREDENTIALS_FILE is unset. It is the only credential source this reference implementation supports, and without it nothing will ever create the ${CCM_SECRET} Secret the cloud controller manager mounts -- see lib/common.sh"
	[[ -r ${src} ]] || die "AWS_SHARED_CREDENTIALS_FILE points at ${src}, which is not readable by this hook"
	local bytes
	bytes=$(wc -c <"${src}")
	[[ ${bytes} -gt 0 ]] || die "AWS_SHARED_CREDENTIALS_FILE points at ${src}, which is empty"

	log "waiting for the cluster API to serve namespace ${CCM_NAMESPACE}"
	until "${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s \
		get namespace "${CCM_NAMESPACE}" >/dev/null 2>&1; do
		[[ $(date +%s) -lt ${deadline} ]] ||
			die "namespace ${CCM_NAMESPACE} never appeared within this hook's ${INPUT_TIMEOUT}s budget. Most often this means the bootstrap control plane is not serving yet or the cluster-version operator has not reached the CloudControllerManager capability's manifests; it can also mean that capability is disabled. Check 'openshift-install wait-for bootstrap-complete' and the bootstrap node's journal"
		sleep 10
	done
	log "namespace ${CCM_NAMESPACE} exists"

	"${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s \
		-n "${CCM_NAMESPACE}" create secret generic "${CCM_SECRET}" \
		--from-file=credentials="${src}" --dry-run=client -o yaml |
		"${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s apply -f - >/dev/null
	log "applied secret ${CCM_NAMESPACE}/${CCM_SECRET} from AWS_SHARED_CREDENTIALS_FILE (${bytes} bytes)"

	# Restart whatever is already running. THIS IS NOT AN OPTIMISATION -- it is
	# what makes the credential take effect.
	#
	# The Deployment's volume is `optional: true`, so a pod born before the
	# Secret existed started with an empty directory at /etc/aws and is
	# crash-looping. The intuition is that the kubelet will sync the new Secret
	# into that volume on its next pass and the pod will recover on its own.
	# Measured on a pilot cluster 2026-11-09, it does not: seven minutes after
	# the Secret was created, a pod left alone was still crash-looping on the
	# same IMDS 404, while a pod that had been replaced came up Running on its
	# first attempt. Within ninety seconds of replacing both, the uninitialized
	# taint was gone from all three masters.
	#
	# A no-op if the Deployment has not been created yet, which is the ordinary
	# case when this hook is early.
	#
	# `optional: true` is what makes any of this orderable, and should stay:
	# with the default a pod created before this hook runs would sit in
	# ContainerCreating on a missing Secret, and nothing here could restart it
	# into a working state.
	"${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s \
		-n "${CCM_NAMESPACE}" delete pod -l "${CCM_SELECTOR}" --ignore-not-found >/dev/null 2>&1 || true
}

# ------------------------------------------- node certificate approval
#
# NOTHING IN AN `external` CLUSTER APPROVES A KUBELET'S CERTIFICATE, AND THE
# COMPONENT THAT NORMALLY WOULD IS RUNNING THE WHOLE TIME
#
# A node joins in two steps, each gated on a certificate signing request the
# cluster will not issue unsupervised: the kubelet first asks for a client
# certificate (signer kubernetes.io/kube-apiserver-client-kubelet, requested on
# its behalf by the machine-config-operator's node-bootstrapper), registers,
# and then asks for its own serving certificate (kubernetes.io/kubelet-serving).
# Both must be approved or the node never becomes Ready.
#
# cluster-machine-approver is present and healthy on this platform and approves
# neither, because it decides by looking the node up in the Machine API:
#
#   csr-r7frx: failed to find machine with InternalDNS matching ip-10-0-7-140,
#   cannot approve                        (measured on a pilot cluster 2026-11-09)
#
# `oc get machines.machine.openshift.io -A` returns nothing on `platform:
# external`. The Cluster API Machine objects that drove this install live in the
# installer's local, temporary control plane and are never delivered to the
# cluster being built, so the approver's source of truth is empty and it
# correctly refuses every request. This is not a bug in the approver. It is the
# consequence of provisioning a cluster whose machines no in-cluster API knows
# about, and on this platform closing it is the provider's job -- the same
# contract that makes the cloud credential the provider's job.
#
# WHY THIS IS NOT `certificate approve` ON EVERYTHING PENDING
#
# Because that is a reference implementation teaching partners to hand out node
# identities to anybody who can file a CSR. The approver this replaces is safe
# precisely because it checks the request against a source of truth, and the
# fix is to give this hook one rather than to drop the check.
#
# The source of truth available here is the cloud: the instances CAPA created
# for this cluster carry kubernetes.io/cluster/<infra-id>=owned, applied by
# ../cluster-api/cluster.yaml, so the payload and this hook agree by
# construction. A CSR is approved only when its subject names a node whose name
# matches one of those instances. Verified on a pilot cluster 2026-11-09: CSR
# subject `CN=system:node:ip-10-0-18-239` against instance PrivateDnsName
# `ip-10-0-18-239.ec2.internal`, tagged for that cluster.
#
# That mapping assumes the default EC2 hostname type, where the private DNS
# name is derived from the private IP. A VPC configured for resource-name
# hostnames would name instances `i-0abc…` instead and this check would refuse
# everything -- loudly, by design, rather than approving what it cannot verify.
#
# THIS COVERS DAY 0 AND ONLY DAY 0. Certificates rotate and nodes get replaced
# long after the installer has exited, and nothing here will be running then.
# The durable answer is an in-cluster controller the provider ships; it is an
# open item in the enhancement proposal and deliberately not solved here.

CSR_SIGNER_CLIENT="kubernetes.io/kube-apiserver-client-kubelet"
CSR_SIGNER_SERVING="kubernetes.io/kubelet-serving"
CSR_BOOTSTRAPPER="system:serviceaccount:openshift-machine-config-operator:node-bootstrapper"

# The node names of every running instance CAPA tagged for this cluster, which
# is the set a CSR subject must fall inside to be approved.
cluster_instance_node_names() {
	aws ec2 describe-instances --region "${REGION}" \
		--filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
		"Name=instance-state-name,Values=running" \
		--query 'Reservations[].Instances[].PrivateDnsName' --output text 2>/dev/null |
		tr '\t' '\n' | sed -e 's/\..*$//' -e '/^$/d' | sort -u
}

# How many nodes to wait for, counted from the cloud rather than hardcoded, so
# that changing the machine count in ../cluster-api/ cannot leave a stale
# constant here. The bootstrap instance is excluded: it runs a kubelet but
# never registers as a node in the cluster it is building.
expected_node_count() {
	# The backticks below are JMESPath string literals belonging to the AWS
	# CLI's --query, not command substitution, and must reach it unexpanded --
	# which is exactly what the single quotes achieve.
	# shellcheck disable=SC2016
	aws ec2 describe-instances --region "${REGION}" \
		--filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
		"Name=instance-state-name,Values=running" \
		--query 'Reservations[].Instances[].Tags[?Key==`Name`]|[].Value' --output text 2>/dev/null |
		tr '\t' '\n' | sed '/^$/d' | grep -cv -- '-bootstrap$' || true
}

# The node a CSR is asking to be. Read from the request's subject rather than
# from any field on the CSR object, because the subject is what the certificate
# will actually assert.
csr_node_name() {
	local kube=$1 kubeconfig=$2 csr=$3
	"${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s \
		get csr "${csr}" -o jsonpath='{.spec.request}' 2>/dev/null |
		base64 -d 2>/dev/null | openssl req -noout -subject 2>/dev/null |
		grep -oE 'CN *= *system:node:[^,/[:space:]]+' |
		sed -E 's/.*system:node://' | head -1
}

# name, signer and requester of every CSR nobody has decided on yet, in one
# call rather than one call per CSR.
pending_csrs() {
	local kube=$1 kubeconfig=$2
	"${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s get csr -o json 2>/dev/null |
		jq -r '.items[] | select(((.status.conditions // []) | length) == 0)
		       | [.metadata.name, .spec.signerName, .spec.username] | @tsv'
}

# approve_csr is the one place the two clients this hook accepts disagree.
#
# Approval lives under `oc adm certificate approve` but `kubectl certificate
# approve` -- measured 2026-11-09, `oc certificate approve` answers `error:
# unknown command "certificate" for "oc"`. Nothing else in this file has to
# care which binary kube_cmd() found; this does.
#
# The client's own error is returned rather than discarded, because "could not
# approve" without it is the exact failure mode this payload's own logging
# rules call out: a message that says something went wrong and makes the
# reader go somewhere else to find out what.
approve_csr() {
	local kube=$1 kubeconfig=$2 csr=$3
	local -a argv=("${kube}" --kubeconfig "${kubeconfig}" "--request-timeout=30s")
	# An `if`, not `[[ ... ]] && argv+=(adm)`: under `set -e` an AND-list whose
	# test fails returns 1 and takes the whole hook with it.
	if [[ ${kube} == oc || ${kube} == */oc ]]; then
		argv+=(adm)
	fi
	argv+=(certificate approve "${csr}")
	"${argv[@]}" 2>&1
}

ready_node_count() {
	local kube=$1 kubeconfig=$2
	"${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s get nodes -o json 2>/dev/null |
		jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready") | .status=="True")] | length'
}

approve_node_csrs() {
	local kube=$1 kubeconfig=$2 deadline=$3

	# Checked here rather than in common.sh's global tool list, so that the
	# other two phases -- which never read a certificate -- do not acquire a
	# dependency they have no use for.
	if ! command -v openssl >/dev/null; then
		record_failure "node certificate approval: openssl is not on PATH, so this hook cannot read a CSR's subject to check it against the cluster's instances. It approves nothing it cannot verify"
		return 1
	fi

	local expected
	expected=$(expected_node_count)
	if ! [[ ${expected} =~ ^[0-9]+$ ]] || [[ ${expected} -eq 0 ]]; then
		record_failure "node certificate approval: found no running instances tagged kubernetes.io/cluster/${INFRA_ID}=owned, so there is no trustworthy set of nodes to approve against"
		return 1
	fi
	log "expecting ${expected} node(s), counted from instances tagged kubernetes.io/cluster/${INFRA_ID}=owned"

	local approved=0 ready=0 allowed name signer user node out
	while :; do
		ready=$(ready_node_count "${kube}" "${kubeconfig}")
		[[ ${ready} =~ ^[0-9]+$ ]] || ready=0
		if [[ ${ready} -ge ${expected} ]]; then
			log "${ready} of ${expected} expected node(s) are Ready; approved ${approved} CSR(s)"
			return 0
		fi

		allowed=$(cluster_instance_node_names)
		while IFS=$'\t' read -r name signer user; do
			[[ -n ${name} ]] || continue
			case ${signer} in
			"${CSR_SIGNER_CLIENT}")
				[[ ${user} == "${CSR_BOOTSTRAPPER}" ]] ||
					{ log "skipping ${name}: client CSR requested by ${user}, not the node bootstrapper"; continue; }
				;;
			"${CSR_SIGNER_SERVING}")
				[[ ${user} == system:node:* ]] ||
					{ log "skipping ${name}: serving CSR requested by ${user}, not a node"; continue; }
				;;
			*)
				log "skipping ${name}: this hook does not approve ${signer}"
				continue
				;;
			esac

			node=$(csr_node_name "${kube}" "${kubeconfig}" "${name}")
			if [[ -z ${node} ]]; then
				log "skipping ${name}: no system:node:<name> subject could be read from it"
				continue
			fi
			if ! grep -qxF "${node}" <<<"${allowed}"; then
				log "REFUSING ${name}: it asks to be node ${node}, which is not an instance tagged for this cluster"
				continue
			fi

			if out=$(approve_csr "${kube}" "${kubeconfig}" "${name}"); then
				approved=$((approved + 1))
				log "approved ${name} for node ${node}"
			else
				log "could not approve ${name}: $(head -1 <<<"${out}")"
			fi
		done <<<"$(pending_csrs "${kube}" "${kubeconfig}")"

		if [[ $(date +%s) -ge ${deadline} ]]; then
			record_failure "node certificate approval: only ${ready} of ${expected} expected node(s) became Ready within this hook's ${INPUT_TIMEOUT}s budget (${approved} CSR(s) approved). Nothing in an 'external' cluster approves these automatically -- cluster-machine-approver matches CSRs against Machine API Machines and none exist here. Finish by hand with 'oc get csr' and 'oc adm certificate approve <name>'"
			return 1
		fi
		sleep 15
	done
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

	# One deadline for the whole hook, taken once and handed to every wait.
	#
	# The wait is long on purpose. This hook is invoked about five minutes into
	# the install, just after the machines are created, so almost everything it
	# needs is still in the future: the bootstrap control plane has to start
	# serving, the cluster-version operator has to apply the day-0 manifests,
	# the partner's cloud controller manager has to be scheduled onto a tainted
	# master, clear node.cloudprovider.kubernetes.io/uninitialized, the workers
	# have to boot and have their certificates approved, and only then is the
	# Service reconciled into a real load balancer. Measured on a pilot cluster
	# 2026-11-09: the first worker CSR appeared twenty minutes after this hook
	# started. The default of 45 leaves room for that and for the address.
	#
	# Shared rather than one budget per wait, so that --timeout-seconds means
	# "how long this hook may take" -- a number the caller can reason about --
	# instead of a number that silently multiplies by the number of steps.
	local deadline=$(($(date +%s) + INPUT_TIMEOUT))

	# 1. The credential. Fail-fast, and the only step that is: nothing below
	#    can succeed without a working cloud controller manager, so continuing
	#    would spend the whole budget discovering that twice.
	ensure_cloud_credentials "${kube}" "${kubeconfig}" "${deadline}"

	# 2. The nodes. Before the address wait, and that order is load-bearing for
	#    a reason beyond this step's own value: a node joining is what makes
	#    the service controller re-run its node sync and register targets on
	#    the load balancer. Measured on a pilot cluster 2026-11-09 -- the CCM
	#    created the ingress load balancer with zero targets and left it that
	#    way for fifty-two minutes, because the node set never changed again
	#    after the initial registration. Waiting for the workers here is what
	#    produces the event that fixes it.
	approve_node_csrs "${kube}" "${kubeconfig}" "${deadline}" || true

	# 3. The address.
	log "waiting for ${INPUT_SERVICE} to be given a load balancer address"
	local address=""
	if ! address=$(service_address "${kube}" "${kubeconfig}" "${ns}" "${name}" "${deadline}"); then
		address=""
		record_failure "${INPUT_SERVICE} still has no status.loadBalancer.ingress within this hook's ${INPUT_TIMEOUT}s budget. Nothing on this platform creates that address except the cloud controller manager the partner supplies, so either it is not running or it cannot reconcile the Service; check 'oc -n ${ns} describe service ${name}' and the CCM's logs"
	fi

	# 4. The wildcard, which needs step 3 to have produced something. Skipped
	#    rather than guessed at: a record pointing nowhere is worse than none.
	if [[ -n ${address} ]]; then
		publish_apps_wildcard "${address}"
	else
		log "skipping the *.apps record: there is no address to point it at"
	fi

	if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
		local joined
		joined=$(printf '(%s) ' "${FAILED_STEPS[@]}")
		die "post-provision ran every step and ${#FAILED_STEPS[@]} failed: ${joined%% }"
	fi
	log "post-provision complete"
}

# publish_apps_wildcard puts the ingress wildcard in front of the address the
# cluster's own cloud controller manager assigned, in both zones that need it,
# and records what it created for pre-destroy.
publish_apps_wildcard() {
	local address=$1

	local target_zone
	target_zone=$(alias_zone "${address}")
	if [[ -z ${target_zone} ]]; then
		record_failure "no alias hosted zone for ${address}; it does not look like an ELBv2 load balancer in ${REGION}, so the *.apps record was not created"
		return 1
	fi

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
		if [[ -z ${pub} ]]; then
			# Recorded, not fatal. The private record above is already in
			# place, so in-cluster resolution works and the operator can add
			# the public one by hand -- which is cheaper than re-running the
			# install to recover a record they could create in a minute.
			record_failure "no public hosted zone for the ${wildcard} record: infra-ready recorded none in ${STATE} and --input-dns-zone <hostedZoneId> was not given. The private record was created; routes will not resolve from outside the VPC until a public one exists"
		else
			pub=${pub#/hostedzone/}
			upsert_alias "${pub}" "${wildcard}" "${address}" "${target_zone}"
		fi
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
	log "published ${wildcard} -> ${address}"
}

main "$@"
