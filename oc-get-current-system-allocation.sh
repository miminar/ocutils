#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly USAGE="$(basename "${BASH_SOURCE[0]}") [Options] [node1 [node2 ...]]

Options:
  -h | --help       Show this message and exit.
  -l | --node-selector NODE_SELECTOR
                    Node label selector to limit the script execution.
  -m | --measure-period MEASURE_PERIOD
                    The minimum Number of seconds to collect statistics.
  -s | --skip SKIP_STATS
                    A comma separated list of measurements to skip. Valid values are:

                        systemd api

                    Where:
                        systemd - Collects statistics about systemd slices and scopes.
                        api     - Gets statistics from k8s API via HTTP endpoint
                                    /api/v1/nodes/\$nodeName/proxy/stats/summary
                        zombies - Get the number of zombies.
  -e | --exec STATS
                    A comma separated list of measurements to perform. No other measurements will
                    be performed. The list of allowed values is the same as for SKIP_STATS.
  --lb | --line-buffer
                    Useful for debugging. The outputs will be unsorted.
"

function _init() {
    TMPDIR="$(mktemp -d)"
    export TMPDIR

    if grep -q -F 'systemd' <<<"${STATS}"; then
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
    fi

    if grep -q -F 'zombies' <<<"${STATS}"; then
        cat >"$TMPDIR/get-zombies-average.sh" <<-EOF
	#!/usr/bin/env bash
    started="\$(date +%s)"
	while true; do
        ps -axu
        printf '#\n'
        now="\$(date +%s)"
        if [[ "\$((\$now - \$started))" -gt "$MEASURE_PERIOD" ]]; then
            break
        fi
        sleep 1
    done | awk '
	BEGIN { iteration=0; zombies[0] = 0 }
    {
        if (\$1 ~ /^#\$/) {
            if (zombies[iteration] > zmbmax) {
                zmbmax = zombies[iteration]
            }
            if (iteration == 0 || zmbmin > zombies[iteration]) {
                zmbmin = zombies[iteration]
            }
            iteration += 1
        } else if (\$8 ~ /Z/) {
            zombies[iteration] += 1
        }
	}
	END {
        // reindexes the array - indexes are bumped by one
        asort(zombies)
        if (iteration % 2 == 0) {
            zmbmean = (zombies[int((iteration/2))] + zombies[int((iteration/2) + 1)])/2
        } else {
            zmbmean = zombies[int(iteration/2) + 1]
        }
        zmbavg = 0
        for (i=1; i <= iteration; i += 1) {
            zmbavg += zombies[i]
        }
        zmbavg /= iteration

        printf "Zombies: %d\t(Min=%d, Mean=%s,\tAvg=%s, Max=%d,\tIterations=%d)\n", \
            zombies[iteration], zmbmin, zmbmean, zmbavg, zmbmax, iteration
	}'
	EOF
    fi

    trap cleanup EXIT
}

function cleanup() {
    rm -rf "$TMPDIR"
}

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
            def mkStats($res; $sumRes; $attr): [.[] | .[$sumRes] as $new |
                    $stats[$res][.name] as $prev | {
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
                "cpu":   . | mkStats("cpu";   "cpu";    "usageNanoCores"),
                "rss":   . | mkStats("rss";   "memory"; "rssBytes"),
                "usage": . | mkStats("usage"; "memory"; "usageBytes"),
                "finished": ($stats.finished // false)
            } as $newStats | $newStats | .finished |= ($minSecs <= ([
                    minMeasuredTime($newStats.cpu), minMeasuredTime($newStats.rss)] | min))')"
        #now="$(date +%s)"
        if [[ "$(jq '.finished' <<<"$stats")" == true ]]; then
            break
        fi
        sleep 1
    done
    #printf '%s\n' "$stats"
    jq -r <<<"$stats" --arg indent "${indent:-}" '. as $stats | [
        ["\($indent)K8s API Node Stats System Component",
         "Cores (avg)",
         "Memory RSS (avg)",
         "Memory Usage (avg)"] | join("\t")
    ] + ([$stats.cpu | keys[] |
        "\($indent)  \(.)\t\($stats.cpu[.].usage    / 1000000    | round)m\t\(
                 $stats.rss[.].usage / (1024*1024)|round)Mi\t\(
                 $stats.usage[.].usage / (1024*1024)|round)Mi"]) + ([
        "\($indent)Total\t\([$stats.cpu    | keys[] | $stats.cpu[.].usage] |
                reduce .[] as $u (0; .+$u) | . / 1000000 | round)m\t\(
          [$stats.rss | keys[] | $stats.rss[.].usage] |
                reduce .[] as $u (0; .+$u) | . / 1000000 | round)Mi\t\(
          [$stats.usage | keys[] | $stats.usage[.].usage] |
                reduce .[] as $u (0; .+$u) | . / 1000000 | round)Mi"
    ]) | join("\n")'
}
export -f getSystemContainersAllocation

function getZombies() {
    local node="$1"
    local minSecs="${2:-$MEASURE_PERIOD}"
    local indent
    indent="$(echo -e "${3:-}")"
    scp "$TMPDIR/get-zombies-average.sh" "$node":~/get-zombies-average.sh
    ssh "$node" sudo /bin/bash ./get-zombies-average.sh | sed 's/^/'"${indent:-}"'/'
}
export -f getZombies

function getAllocationForNode() {
    local node="$1"
    export MEASURE_PERIOD
    local columnArgs=( --table --separator $'\t' )
    if ( column --version | awk '{print $NF}'; printf '2.30\n'; ) | sort -V | head -n 1 | \
            grep -q -F "2.30";
    then
        # Align the last 3 columns to the right
        # --table-right is supported by column since release 2.30
        columnArgs+=( --table-right "3,4,5" )
    fi
    local args=( -P 5 --id "alloc-$node" )
    if [[ $LINE_BUFFER == 1 ]]; then
        args+=( --line-buffer )
    else
        args+=( --keep-order )
    fi
    ( 
        parallel "${args[@]}" echo -e "01#Node\\\t$node\\\t\\\t"
        if grep -q -F 'systemd' <<<"${STATS}"; then
            parallel "${args[@]}" getSystemAllocation "$node" '02#\\t'; fi;\
        if grep -q -F 'api' <<<"${STATS}"; then
            parallel "${args[@]}" getSystemContainersAllocation "$node" \
                "$MEASURE_PERIOD" '03#\\t'; fi; \
        if grep -q -F "zombies" <<<"${STATS}"; then
            parallel "${args[@]}" getZombies "$node" \
                "$MEASURE_PERIOD" '04#\\t'; fi; \
        parallel "${args[@]}" --wait; \
    ) | sort -t '#' -s -k 1 -n | sed 's/^[[:digit:]]\+#//' | column "${columnArgs[@]}"
}
export -f getAllocationForNode

readonly ALL_STATS=( systemd api zombies )
collectStats=( systemd api zombies )
LINE_BUFFER=0
# number of seconds to measure
MEASURE_PERIOD=10

readonly longOptions=(
    help node-selector: measure-period: skip: exec: line-buffer lb
)

function join() { local IFS="$1"; shift; echo "$*"; }

TMPARGS="$(getopt -o hl:m:s:e: --long "$(join , "${longOptions[@]}")" \
    -n "$(basename "${BASH_SOURCE[0]}")" -- "$@")"
eval set -- "${TMPARGS:-}"

while true; do
    case "$1" in
        -h | --help)
            printf '%s' "$USAGE"
            exit 0
            ;;
        -l | --node-selector)
            NODE_SELECTOR="$2"
            shift 2
            ;;
        -m | --measure-period)
            MEASURE_PERIOD="$2"
            shift 2
            ;;
        -s | --skip)
            readarray -t skipStats <<<"$(tr -d '[:space:]' <<< "$2" | tr ',' '\n')"
            shift 2
            readarray -t unknownStats <<<"$(grep -v -F -f <(printf '%s\n' "${ALL_STATS[@]}") \
                <<<"$(printf '%s\n' "${skipStats[@]}")")"
            if [[ "${#unknownStats[@]}" -gt 1 || ( "${#unknownStats[@]}" == 1 && \
                -n "${unknownStats[0]:-}" ) ]];
            then
                printf 'Cannot skip unknown stats: %s\n' >&2 "$(join , "${unknownStats[@]}")"
                exit 1
            fi

            readarray -t newStats <<<"$(grep -v -F -f <(printf '%s\n' "${skipStats[@]}") \
                    <<<"$(printf '%s\n' "${collectStats[@]:-}")")"
            collectStats=( "${newStats[@]}" )
            ;;

        -e | --exec)
            readarray -t execStats <<<"$(tr -d '[:space:]' <<< "$2" | tr ',' '\n')"
            shift 2
            readarray -t unknownStats <<<"$(grep -v -F -f <(printf '%s\n' "${ALL_STATS[@]}") \
                <<<"$(printf '%s\n' "${execStats[@]}")")"
            if [[ "${#unknownStats[@]}" -gt 1 || ( "${#unknownStats[@]}" == 1 && \
                -n "${unknownStats[0]:-}" ) ]];
            then
                printf 'Cannot skip unknown stats: %s\n' >&2 "$(join , "${unknownStats[@]}")"
                exit 1
            fi

            collectStats=( "${execStats[@]}" )
            ;;

        --lb | --line-buffer)
            LINE_BUFFER=1
            shift
            ;;

        --)
            shift
            break
            ;;
        *)
            printf 'Unknown parameter "%s"!\n' >&2 "$1"
            exit 1
            ;;
    esac
done

if [[ "${#collectStats[@]}" == 0 || ( "${#collectStats[@]}" == 1 && \
        -z "${collectStats[0]:-}" ) ]]; then
    printf 'No stats to collect.\n'
    exit 0
fi

nodes=( )
if [[ -n "${NODE_SELECTOR:-}" ]]; then
    readarray -t nodes <<<"$(oc get nodes -l "${NODE_SELECTOR}" -o name | awk -F / '{print $2}')"
fi

if [[ $# -gt 0 ]]; then
    nodes+=( "$@" )
fi

if [[ "${#nodes[@]}" == 0 || ( "${#nodes[@]}" == 1 && -z "${nodes[0]:-}" ) ]]; then
    if [[ -n "${NODE_SELECTOR:-}" ]]; then
        printf 'No nodes match the given node selector!\n' >&2
        exit 1
    fi
    
    readarray -t nodes <<<"$(oc get nodes -o name | awk -F / '{print $2}')"
fi

if [[ "${#nodes[@]}" == 0 || ( "${#nodes[@]}" == 1 && -z "${nodes[0]:-}" ) ]]; then
    printf 'No nodes given!\n' >&2
    exit 1
fi

STATS="$(join , "${collectStats[@]}")"
export STATS
_init
export MEASURE_PERIOD LINE_BUFFER

if command -v parallel >/dev/null; then
    args=( --keep-order )
    if [[ $LINE_BUFFER == 1 ]]; then
        args=( --line-buffer )
    fi
    parallel "${args[@]}" getAllocationForNode ::: "${nodes[@]}"
    exit 0
fi

for node in "${nodes[@]}"; do
    getAllocationForNode "$node"
done
