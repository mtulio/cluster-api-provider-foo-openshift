#!/usr/bin/env bash
#
# PreDestroy hook for `platform: external` with a Cluster API infrastructure
# provider -- AWS/CAPA reference implementation.
#
# Removes everything infra-ready.sh and post-provision.sh created. Reads
# dns.json and apps-dns.json and deletes them.
#
#
# WHY A TEARDOWN HOOK IS NOT OPTIONAL
#
# Anything a hook creates is outside Cluster API's ownership, so nothing else
# will ever clean it up. `destroy cluster` deletes the Cluster object and
# CAPA deletes what CAPA made; a hosted zone, a DNS record in somebody else's
# zone, and a load balancer the cluster's own CCM built are all invisible to
# that. They would outlive the cluster that paid for them.
#
# The rule on this pilot is that each new resource ships with its teardown in
# the same change. These three programs are where that rule is kept, and the
# state files are what make it keepable: this hook deletes only what the
# other two recorded creating, by id and by exact name, never by discovery.
#
# That matters most for the public zone. It belongs to the base domain, not
# to this cluster, and it holds every other cluster's records. A filter that
# matched more than intended would take out somebody else's cluster.
#
#
# ORDER
#
# Ingress first, API second; within each, records before the thing they point
# at. An alias record is described in terms of the load balancer it names, so
# Route 53 is easier to reason about while that target still exists.
#
# Every step is idempotent and tolerant of absence. An install that reached
# infra-ready and no further wrote dns.json and never wrote apps-dns.json,
# and a destroy re-run after a partial failure finds some of its work already
# done. Neither is an error.
#
# Takes no arguments.
#
# See lib/common.sh for the environment contract, the state file shapes, and
# the shared Route 53 helpers.

set -euo pipefail

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

expect_hook pre-destroy
reject_args "$@"

# ------------------------------------------------------------- route 53

# delete_alias_record removes one record by exact name and type, and only if
# it is there.
#
# By exact name, always. The public zone belongs to the base domain and holds
# every other cluster's records; a filter that matched more than intended
# would take out somebody else's cluster. Read-then-delete rather than a
# blind DELETE because Route 53 requires the full record in the change batch
# and errors if it does not match, which would turn an already-clean zone
# into a failed destroy.
delete_alias_record() {
	local zone=$1 name=$2 type=${3:-A}
	[[ -n ${zone} && -n ${name} ]] || return 0

	# Route 53 stores a wildcard label in its octal escape form: a record
	# created as `*.apps.x.` is returned as `\052.apps.x.`. Creation accepts
	# either spelling, so the asymmetry is invisible until something reads the
	# record back -- and then an exact match against the name as written never
	# fires, this function reports the record as already gone, and destroy
	# leaks it while exiting 0. That is exactly what happened to the `*.apps`
	# record of the first pilot cluster taken down by this path.
	#
	# Match either spelling rather than picking one. The comparison moved from
	# JMESPath to jq because the escaped name contains a backslash, and
	# quoting that through --query correctly is harder to get right than to
	# pass as an argument.
	local escaped=${name/#\*./\\052.}
	local found
	found=$(aws route53 list-resource-record-sets --hosted-zone-id "${zone}" --output json |
		jq --arg n "${name}" --arg e "${escaped}" --arg t "${type}" \
			'[.ResourceRecordSets[] | select((.Name == $n or .Name == $e) and .Type == $t)]')
	if [[ $(jq 'length' <<<"${found}") -eq 0 ]]; then
		log "${name} is already gone from ${zone}"
		return 0
	fi
	log "deleting ${name} from zone ${zone}"
	aws route53 change-resource-record-sets --hosted-zone-id "${zone}" \
		--change-batch "$(jq -n --argjson r "$(jq '.[0]' <<<"${found}")" \
			'{Changes: [{Action: "DELETE", ResourceRecordSet: $r}]}')" >/dev/null
}

# -------------------------------------------------------------- ingress

# delete_ingress_lb removes the load balancer the cluster's CCM built for the
# ingress Service.
#
# Nothing else will. While the cluster is alive the CCM owns this load
# balancer and deleting the Service deletes it, but `destroy cluster` never
# deletes the Service -- it deletes the nodes the controller ran on. The load
# balancer, its target groups and its listeners would survive the cluster
# that paid for them.
#
# The ARN is read from state rather than discovered, so this can only ever
# delete the one load balancer this hook recorded creating.
delete_ingress_lb() {
	local arn=$1
	[[ -n ${arn} ]] || return 0

	if ! aws elbv2 describe-load-balancers --region "${REGION}" --load-balancer-arns "${arn}" >/dev/null 2>&1; then
		log "ingress load balancer is already gone"
		return 0
	fi

	# Read the target groups before the delete: afterwards there is no load
	# balancer to list them from, and they are not deleted with it.
	local tgs
	tgs=$(aws elbv2 describe-target-groups --region "${REGION}" --load-balancer-arn "${arn}" --output json |
		jq -r '.TargetGroups[].TargetGroupArn')

	log "deleting the ingress load balancer ${arn}"
	aws elbv2 delete-load-balancer --region "${REGION}" --load-balancer-arn "${arn}"

	# A target group cannot be deleted while a load balancer still references
	# it, and the delete above is asynchronous.
	local waited=0
	while aws elbv2 describe-load-balancers --region "${REGION}" --load-balancer-arns "${arn}" >/dev/null 2>&1; do
		if [[ ${waited} -ge 300 ]]; then
			log "WARNING: the load balancer is still present after 300s; leaving its target groups in place rather than failing the destroy"
			return 0
		fi
		sleep 10
		waited=$((waited + 10))
	done

	local tg
	for tg in ${tgs}; do
		log "deleting target group ${tg}"
		aws elbv2 delete-target-group --region "${REGION}" --target-group-arn "${tg}" >/dev/null ||
			log "WARNING: could not delete target group ${tg}"
	done
}

# destroy_ingress removes what post-provision created: the wildcard records
# and the load balancer they point at.
#
# Records first, load balancer second, for the same reason infra-ready's
# teardown runs before the Cluster delete: an alias record is described in
# terms of the load balancer it names, and Route 53 is easier to reason about
# while that target still exists.
destroy_ingress() {
	if [[ ! -f ${APPS_STATE} ]]; then
		log "no ${APPS_STATE}; this hook created no ingress records or load balancer"
		return 0
	fi

	local pub rec arn
	pub=$(jq -r '.publicHostedZoneId // empty' "${APPS_STATE}")
	rec=$(jq -r '.recordName // empty' "${APPS_STATE}")
	arn=$(jq -r '.loadBalancerArn // empty' "${APPS_STATE}")

	# Only the public copy is deleted by name. The private copy lives in the
	# cluster's own hosted zone, which is emptied and deleted wholesale
	# below.
	delete_alias_record "${pub}" "${rec}" A

	delete_ingress_lb "${arn}"

	rm -f "${APPS_STATE}"
}

# ----------------------------------------------------------------- main

main() {
	destroy_ingress

	if [[ ! -f ${STATE} ]]; then
		log "no ${STATE}; nothing else this hook created to remove"
		return 0
	fi

	local phz pub rec dns
	phz=$(jq -r '.privateHostedZoneId // empty' "${STATE}")
	pub=$(jq -r '.publicHostedZoneId // empty' "${STATE}")
	rec=$(jq -r '.publicRecordName // empty' "${STATE}")
	dns=$(jq -r '.publicRecordTarget // empty' "${STATE}")

	# The public record first, and by exact name. This zone belongs to the
	# base domain and holds other clusters' records; deleting anything not
	# named here would take out somebody else's cluster.
	if [[ -n ${pub} && -n ${rec} && -n ${dns} ]]; then
		delete_alias_record "${pub}" "${rec}" A
	fi

	# Then the private zone. Route 53 refuses to delete a zone that still has
	# records other than its own NS and SOA, so they go first.
	if [[ -n ${phz} ]]; then
		if ! aws route53 get-hosted-zone --id "${phz}" >/dev/null 2>&1; then
			log "private zone ${phz} is already gone"
		else
			local records
			records=$(aws route53 list-resource-record-sets --hosted-zone-id "${phz}" \
				--query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" --output json)
			if [[ $(jq 'length' <<<"${records}") -gt 0 ]]; then
				log "deleting $(jq 'length' <<<"${records}") record(s) from ${phz}"
				aws route53 change-resource-record-sets --hosted-zone-id "${phz}" \
					--change-batch "$(jq -n --argjson rs "${records}" \
						'{Changes: [$rs[] | {Action: "DELETE", ResourceRecordSet: .}]}')" >/dev/null
			fi
			log "deleting private hosted zone ${phz}"
			aws route53 delete-hosted-zone --id "${phz}" >/dev/null
		fi
	fi

	rm -f "${STATE}"
	log "pre-destroy complete"
}

main
