#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# number of seconds to measure
readonly MEASURE_PERIOD=10

nodes=( )
if [[ $# -gt 0 ]]; then
    nodes+=( "$@" )
fi

if [[ -z "${node:-}" ]]; then
    readarray -t nodes <<<"$(oc get nodes -o name | awk -F / '{print $2}')"
fi

TMPDIR="$(mktemp -d)"
cat >"$TMPDIR/get-system-average.sh" <<-EOF
	#!/usr/bin/env bash
	systemd-cgtop --batch --raw --iterations=$MEASURE_PERIOD | awk '
	BEGIN { skipcpu=1 }
	\$1 ~ /^\/(system\.slice|init.scope|kubepods\.slice)\$/ {
	    if (\$3 !~ /^[[:digit:]]+/) {
	         \$3 = 0.
	    }
	    if (skipcpu) {
	        skipcpu = 0;    /* the very first snapshot does not show any CPU utilization */
	    } else {
	        cpu[\$1][cpucnt[\$1]]=(\$3 + 0.)*10.;  /* %CPU to milicores */
	        cpuavg[\$1]=((cpuavg[\$1] + 0.)*cpucnt[\$1] + (cpu[\$1][cpucnt[\$1]]))/(cpucnt[\$1]+1)
	        cpucnt[\$1]+=1
	    }
	    v  = \$4;           /* number of bytes */
        v /= 1024.*1024.;   /* converted to Mi */
	    mem[\$1][memcnt[\$1]] = v + 0.
	    memavg[\$1]  = ((memavg[\$1] + 0.)*memcnt[\$1] + (mem[\$1][memcnt[\$1]]))/(memcnt[\$1]+1)
	    memcnt[\$1] += 1
	}
	END {
        printf "Systemd Unit\tCores (avg)\tMemory (avg)\n"
	    for (key in cpu) {
	        printf "  %s\t%dm\t%dMi\n", key, cpuavg[key], memavg[key]
	        totalavg["cpu"] += cpuavg[key]
	        totalavg["mem"] += memavg[key]
	    }
	    printf "Total\t%dm\t%dMi\n", totalavg["cpu"], totalavg["mem"]
	}'
	EOF

function cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

function getSystemAllocation() {
    local node="$1"
    local indent
    indent="$(echo -e "${2:-}")"
    scp "$TMPDIR/get-system-average.sh" "$node":~/get-system-average.sh
    ssh "$node" sudo /bin/bash ./get-system-average.sh | sed 's/^/'"${indent:-}"'/'
}
export -f getSystemAllocation

function getSystemContainersAllocation() {
    local node="$1"
    local minSecs="${2:-$MEASURE_PERIOD}"
    local indent
    indent="$(echo -e "${3:-}")"
    local nodeStats
    # Result object with the following attributes:
    #   "cpu": {
    #     "component": {
    #       "started": seconds from epoch of the first snapshot,
    #       "ended": seconds from epoch of the latest snapshot,
    #       "count": number of snapshots taken,
    #       "initialUsage": usage in nano cores of the first snapshot,
    #       "latestUsage": latest usage in nano cores
    #       "usage": average usage in nano cores,
    #     }, ...
    #   },
    #   "memory": {
    #     "component": {
    #       "started": seconds from epoch of the first snapshot,
    #       "avgUsage": average usage in bytes,
    #       "count": number of snapshots taken so far,
    #     },
    #   },
    #   "finished": boolean saying whether it is OK to end the measurement
    local stats='{}'
    while true; do
        nodeStats="$(oc get --raw "/api/v1/nodes/$node/proxy/stats/summary" | \
            jq '.node.systemContainers')"
        stats="$(jq --argjson stats "$stats" --argjson minSecs "$minSecs" <<<"$nodeStats" '
            def mkStats($res; $attr): [.[] | .[$res] as $new | $stats[$res][.name] as $prev | {
                "key": .name,
                "value": (
                    ($prev.initialUsage // $new[$attr]) as $initialUsage |
                    ($new.time | fromdate) as $ended |
                    ((($prev.ended // 0) == 0) or ($prev.ended != $ended)) as $changed |
                    if $changed | not then
                        $prev
                    else {
                        "started": ($prev.started // ($new.time | fromdate)),
                        "ended": $ended,
                        "count": (($prev.count // 0) + 1),
                        "initialUsage": $initialUsage,
                        "latestUsage": $new[$attr],
                        "interval": ($ended - ($prev.ended // $ended)),
                        "minUsage": (if (($prev.count // 0) == 0) then
                            $initialUsage
                        else
                            [$prev.minUsage, $new[$attr]] | min
                        end),
                        "maxUsage": (if (($prev.count // 0) == 0) then
                            $initialUsage
                        else
                            [$prev.maxUsage, $new[$attr]] | max
                        end),
                        "usage": (if (($prev.count // 0) == 0) then
                            # the initial value will not be reflected in the average from the
                            # second snapshot onward because its measurement interval is unknown
                            $initialUsage
                        else
                            ( $prev.usage * ($prev.ended - $prev.started)
                            + $new[$attr] * ($ended - $prev.ended)
                            ) / ($ended - $prev.started)
                        end)
                        }
                    end
                )}] | sort_by(.key) | from_entries;

            def minMeasuredTime($comps): $comps | [keys[] | $comps[.] as $comp |
                $comp.ended - $comp.started] | min;

            {
                "cpu": . | mkStats("cpu"; "usageNanoCores"),
                "memory": . | mkStats("memory"; "usageBytes"),
                "finished": ($stats.finished // false)
            } as $newStats | $newStats | .finished |= ($minSecs <= ([
                    minMeasuredTime($newStats.cpu), minMeasuredTime($newStats.memory)] | min))')"
        #now="$(date +%s)"
        if [[ "$(jq '.finished' <<<"$stats")" == true ]]; then
            break
        fi
        sleep 1
    done
    #printf '%s\n' "$stats"
    jq -r <<<"$stats" --arg indent "${indent:-}" '. as $stats | [
        "\($indent)K8s API Node Stats System Component\tCores (avg)\tMemory (avg)"
    ] + ([$stats.cpu | keys[] |
        "\($indent)  \(.)\t\($stats.cpu[.].usage    / 1000000    | round)m\t\(
                 $stats.memory[.].usage / (1024*1024)|round)Mi"]) + ([
        "\($indent)Total\t\([$stats.cpu    | keys[] | $stats.cpu[.].usage] |
                reduce .[] as $u (0; .+$u) | . / 1000000 | round)m\t\(
          [$stats.memory | keys[] | $stats.memory[.].usage] |
                reduce .[] as $u (0; .+$u) | . / 1000000 | round)Mi"
    ]) | join("\n")'
}
export -f getSystemContainersAllocation

function getAllocationForNode() {
    local node="$1"
    export MEASURE_PERIOD TMPDIR
    local columnArgs=( --table --separator $'\t' )
    if ( column --version | awk '{print $NF}'; printf '2.30\n'; ) | sort -V | head -n 1 | \
            grep -q -F "2.30";
    then
        columnArgs+=( --table-right "3,4" )
    fi
    local args=( --keep-order -P 4 --id "alloc-$node" )
    ( 
        parallel "${args[@]}" echo -e "Node\\\t$node\\\t\\\t"
        parallel "${args[@]}" getSystemAllocation "$node" '\\t'; \
        parallel "${args[@]}" getSystemContainersAllocation "$node" \
            "$MEASURE_PERIOD" '\\t'; \
        parallel "${args[@]}" --wait; \
    ) | column "${columnArgs[@]}"
}
export -f getAllocationForNode

if [[ "${#nodes[@]}" -lt 1 ]]; then
    printf 'No nodes given!\n' >&2
    exit 1
fi

## TODO: debug
#for node in "${nodes[@]}"; do
#    getSystemContainersAllocation  "$node"
#done
#exit 0

export MEASURE_PERIOD TMPDIR
if command -v parallel >/dev/null; then
    parallel --keep-order getAllocationForNode ::: "${nodes[@]}"
    exit 0
fi

for node in "${nodes[@]}"; do
    getAllocationForNode "$node"
done
