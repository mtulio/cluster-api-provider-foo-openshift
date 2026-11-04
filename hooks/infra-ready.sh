#!/usr/bin/env bash
#
# InfraReady hook for `platform: external` with a Cluster API infrastructure
# provider -- AWS/CAPA reference implementation.
#
# Publishes the cluster's API DNS. Writes dns.json.
#
#
# WHY THIS EXISTS
#
# On an integrated platform the installer creates the cluster's DNS itself,
# after CAPI reports the network ready. For AWS that is
# pkg/infrastructure/aws/clusterapi/aws.go:112 `InfraReady`, which creates the
# private hosted zone for the cluster domain and the `api` / `api-int` records
# pointing at the API load balancers.
#
# `platform: external` has no such code and must not grow any: the whole point
# is that the installer knows nothing about the provider's cloud. But the
# records still have to exist. A control-plane machine's pointer ignition aims
# at `https://api-int.<clusterDomain>:22623/config/master`, and the bootstrap
# node's own kubeconfig targets `https://api-int.<clusterDomain>:6443`. Without
# the record, bootkube fails at its `resolve-api-int-url` stage and the install
# dies after the full bootstrap timeout.
#
# So the seam is here: the installer calls out to a program the user supplies,
# at the same point in the flow where an integrated provider would run its own
# InfraReady, and hands it everything it can describe without knowing the
# provider's API.
#
# This is the one hook an install genuinely cannot do without. A phase that
# neither the payload nor install-config.yaml names is skipped and the
# installer only warns -- which is correct, because publishing these records
# out of band is a legitimate deployment -- but if nothing publishes them, the
# failure arrives forty minutes later at the bootstrap timeout.
#
#
# WHAT IT DOES NOT DO
#
# Not `*.apps`. That record cannot exist yet, and the reason is structural
# rather than a matter of ordering: at this point nothing exists but what the
# infrastructure provider built, and the provider does not build an ingress
# load balancer for anyone. See post-provision.sh, which explains why and
# publishes it.
#
# Takes no arguments. Everything it needs is in the environment or in the
# provider's own infrastructure object.
#
# See lib/common.sh for the environment contract, the state file shapes, and
# the shared Route 53 helpers.

set -euo pipefail

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

expect_hook infra-ready
reject_args "$@"

# ------------------------------------------------------------- discovery

# vpc_id reads the VPC from the provider's own object, and falls back to the
# tag the provider sets. The fallback matters because CAPA only writes
# spec.network.vpc.id back for a VPC it created; a BYO VPC is named by filter.
vpc_id() {
	local id=""
	if [[ -n ${OPENSHIFT_INSTALL_INFRA_JSON:-} && -f ${OPENSHIFT_INSTALL_INFRA_JSON} ]]; then
		id=$(jq -r '.spec.network.vpc.id // empty' "${OPENSHIFT_INSTALL_INFRA_JSON}")
	fi
	if [[ -z ${id} ]]; then
		id=$(aws ec2 describe-vpcs --region "${REGION}" \
			--filters "Name=tag:sigs.k8s.io/cluster-api-provider-aws/cluster/${INFRA_ID},Values=owned" \
			--output json 2>/dev/null | jq -r '.Vpcs[0].VpcId // empty')
	fi
	[[ -n ${id} ]] || die "could not determine the VPC for ${INFRA_ID}"
	printf '%s' "${id}"
}

# lb_dns reads a load balancer DNS name out of the provider's status.
# `apiServerElb` is the internal one and is what Cluster.spec.controlPlaneEndpoint
# also carries; `secondaryAPIServerELB` is the internet-facing one CAPA creates
# when the cluster is published externally.
lb_dns() {
	local field=$1
	[[ -n ${OPENSHIFT_INSTALL_INFRA_JSON:-} && -f ${OPENSHIFT_INSTALL_INFRA_JSON} ]] || return 0
	jq -r ".status.networkStatus.${field}.dnsName // empty" "${OPENSHIFT_INSTALL_INFRA_JSON}"
}

# ----------------------------------------------------------------- main

main() {
	local vpc internal_dns external_dns internal_zone phz_id public_zone_id
	vpc=$(vpc_id)
	log "cluster domain ${CLUSTER_DOMAIN}, vpc ${vpc}, region ${REGION}, publish ${PUBLISH}"

	internal_dns=$(lb_dns apiServerElb)
	# Cluster.spec.controlPlaneEndpoint.host is the one endpoint in the *core*
	# CAPI contract, so it is the provider-agnostic fallback. CAPA fills it
	# with the internal API load balancer, which is exactly what api-int needs.
	if [[ -z ${internal_dns} ]]; then
		internal_dns=${OPENSHIFT_INSTALL_CONTROL_PLANE_ENDPOINT_HOST:-}
	fi
	[[ -n ${internal_dns} ]] || die "no internal API load balancer in the infrastructure object or the Cluster endpoint"
	internal_zone=$(alias_zone "${internal_dns}")
	[[ -n ${internal_zone} ]] || die "no alias hosted zone for ${internal_dns}"

	# --- private hosted zone for the cluster domain -----------------------
	#
	# Idempotent by name and VPC association, because CreateHostedZone with a
	# reused CallerReference fails rather than returning the existing zone.
	phz_id=$(aws route53 list-hosted-zones-by-vpc --vpc-id "${vpc}" --vpc-region "${REGION}" --output json |
		jq -r --arg n "${CLUSTER_DOMAIN}." '.HostedZoneSummaries[] | select(.Name==$n) | .HostedZoneId' | head -1)

	if [[ -z ${phz_id} ]]; then
		log "creating private hosted zone ${CLUSTER_DOMAIN}. in ${vpc}"
		phz_id=$(aws route53 create-hosted-zone \
			--name "${CLUSTER_DOMAIN}" \
			--caller-reference "${INFRA_ID}-$(date +%s)" \
			--vpc "VPCRegion=${REGION},VPCId=${vpc}" \
			--hosted-zone-config "Comment=Created by the openshift-install external InfraReady hook for ${INFRA_ID},PrivateZone=true" \
			--query 'HostedZone.Id' --output text)
		phz_id=${phz_id#/hostedzone/}
		# Tagged so the zone is attributable, the same way CAPA tags what it
		# creates. Nothing keys off this; it is for a human reading the console.
		aws route53 change-tags-for-resource --resource-type hostedzone --resource-id "${phz_id}" \
			--add-tags "Key=kubernetes.io/cluster/${INFRA_ID},Value=owned" >/dev/null
	else
		phz_id=${phz_id#/hostedzone/}
		log "reusing existing private hosted zone ${phz_id}"
	fi

	# Both names resolve to the internal load balancer inside the VPC. api-int
	# is what bootkube, the kubelet and the pointer ignition use; api is here
	# so that in-cluster clients using the external name do not hairpin out.
	upsert_alias "${phz_id}" "api-int.${CLUSTER_DOMAIN}." "${internal_dns}" "${internal_zone}"
	upsert_alias "${phz_id}" "api.${CLUSTER_DOMAIN}." "${internal_dns}" "${internal_zone}"

	# --- public api record ------------------------------------------------
	public_zone_id=""
	if [[ ${PUBLISH} == "External" ]]; then
		external_dns=$(lb_dns secondaryAPIServerELB)
		if [[ -z ${external_dns} ]]; then
			log "publish is External but the provider reports no internet-facing API load balancer; skipping the public record"
		else
			public_zone_id=$(aws route53 list-hosted-zones --output json |
				jq -r --arg n "${BASE_DOMAIN}." \
					'.HostedZones[] | select(.Name==$n and .Config.PrivateZone==false) | .Id' | head -1)
			[[ -n ${public_zone_id} ]] || die "no public hosted zone for ${BASE_DOMAIN}"
			public_zone_id=${public_zone_id#/hostedzone/}
			upsert_alias "${public_zone_id}" "api.${CLUSTER_DOMAIN}." \
				"${external_dns}" "$(alias_zone "${external_dns}")"
		fi
	fi

	# --- state for the teardown -------------------------------------------
	#
	# The private zone is deleted wholesale, so only its ID is needed. The
	# public record lives in a zone that is NOT ours and long outlives the
	# cluster, so it is recorded by name and target: pre-destroy must delete
	# exactly that record and nothing else in a shared zone.
	jq -n \
		--arg phz "${phz_id}" \
		--arg pub "${public_zone_id}" \
		--arg rec "api.${CLUSTER_DOMAIN}." \
		--arg dns "${external_dns:-}" \
		'{privateHostedZoneId: $phz, publicHostedZoneId: $pub, publicRecordName: $rec, publicRecordTarget: $dns}' \
		>"${STATE}"
	log "recorded state in ${STATE}"
	log "infra-ready complete"
}

main
