#!/bin/bash

################################################################################
#                                                                              #
#  EVCC Victoria Metrics Aggregation Script                                    #
#                                                                              #
#  This script performs data aggregation for EVCC Grafana dashboards.          #
#  It processes and consolidates metrics collected from EVCC instances         #
#  to prepare them for visualization in Grafana.                               #
#                                                                              #
#  For more information, dashboard setup instructions, and source code, visit: #
#    https://github.com/ha-puzzles/evcc-grafana-dashboards                     #
#                                                                              #
################################################################################



###############################################################################
### GLOBAL VARIABLES
###############################################################################


# Argument parameters
AGGREGATE_YEAR=0
AGGREGATE_YESTERDAY=false
AGGREGATE_TODAY=false
AGGREGATE_MONTH_YEAR=0
AGGREGATE_MONTH_MONTH=0
AGGREGATE_DAY_YEAR=0
AGGREGATE_DAY_MONTH=0
AGGREGATE_DAY_DAY=0
AGGREGATE_FROM_YEAR=0
AGGREGATE_FROM_MONTH=0
AGGREGATE_FROM_DAY=0
AGGREGATE_TO_YEAR=0
AGGREGATE_TO_MONTH=0
AGGREGATE_TO_DAY=0
DELETE_AGGREGATIONS=false
DETECT_VALUES=false
DRY_RUN=false

# Array of vehicles
declare -A VEHICLES

#Array of loadpoints
declare -A LOADPOINTS

#Array of ext devices
declare -A EXT_DEVICES

#Array of aux devices
declare -A AUX_DEVICES

# All metrics written by aggregateDay(). Keep in sync when adding new aggregations, as --delete-aggregations relies on this list.
AGGREGATED_METRICS=(
    "pvEnergyDaily"
    "homeEnergyDaily"
    "gridEnergyImportDaily"
    "gridEnergyExportDaily"
    "batteryEnergyDischargedDaily"
    "batteryEnergyChargedDaily"
    "loadpointEnergyDaily"
    "auxEnergyDaily"
    "extEnergyDaily"
    "consumerEnergyDaily"
    "energyPriceBoughtDaily"
    "energyPriceSoldDaily"
    "energyPriceMaxDaily"
    "energyPriceMinDaily"
    "energyPriceAvgDaily"
    "greenShareHomeDaily"
    "batterySocMaxDaily"
    "batterySocMinDaily"
    "vehicleOdometerMaxDaily"
    "vehicleEnergyDaily"
    "potentialHomeDailyPrice"
    "potentialLoadpointDailyPrice"
    "energyDischargeDailyPrice"
    "energyChargeDailyPrice"
    "vehicleChargeDailyPrice"
    "potentialVehicleChargeDailyPrice"
)



###############################################################################
### FUNCTIONS
###############################################################################


logError() {
    local msg="$1"
    echo "[ERROR]   $msg" >&2
}

logWarning() {
    local msg="$1"
    echo "[WARNING] $msg" >&2
}

logInfo() {
    local msg="$1"
    echo "[INFO]    $msg" >&2
}

logDebug() {
    local msg="$1"
    if [ "$DEBUG" == "true" ]; then
        echo "[DEBUG]   $msg" >&2
    fi
}

validateNumber() {
    local num="$1"
    if ! [[ "$num" =~ ^[1-9][0-9]*$ ]]; then
        return 1
    fi
    return 0
}

validateDate() {
    local year="$1" month="${2:-}" day="${3:-}" text
    [[ "$year" =~ ^[0-9]{4}$ ]] && (( 10#$year >= 1970 && 10#$year <= 2100 )) || {
        logError "Year must be between 1970 and 2100."; exit 1;
    }
    if [[ -n "$month" ]]; then
        [[ "$month" =~ ^[0-9]{1,2}$ ]] && (( 10#$month >= 1 && 10#$month <= 12 )) || {
            logError "Month must be between 1 and 12."; exit 1;
        }
    fi
    if [[ -n "$day" ]]; then
        [[ "$day" =~ ^[0-9]{1,2}$ ]] && (( 10#$day >= 1 && 10#$day <= 31 )) || {
            logError "Day must be between 1 and 31."; exit 1;
        }
        printf -v text '%04d-%02d-%02d' "$((10#$year))" "$((10#$month))" "$((10#$day))"
        TZ="$TIMEZONE" date -d "$text" +%F >/dev/null 2>&1 || { logError "Invalid date: $text"; exit 1; }
    fi
}

parseArguments() {
    if [ $# -eq 0 ]; then
        printUsage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --debug)
                export DEBUG=true
                logDebug "Enabling debug."
                shift
                ;;
            --year)
                if [ $# -lt 2 ]; then printUsage; exit 1; fi
                validateDate "$2"
                AGGREGATE_YEAR=$((10#$2))
                logDebug "Aggregating year $AGGREGATE_YEAR"
                shift 2
                ;;
            --month)
                if [ $# -lt 3 ]; then printUsage; exit 1; fi
                validateDate "$2" "$3"
                AGGREGATE_MONTH_YEAR=$((10#$2))
                AGGREGATE_MONTH_MONTH=$((10#$3))
                logDebug "Aggregating month ${AGGREGATE_MONTH_YEAR}-${AGGREGATE_MONTH_MONTH}"
                shift 3
                ;;
            --day)
                if [ $# -lt 4 ]; then printUsage; exit 1; fi
                validateDate "$2" "$3" "$4"
                AGGREGATE_DAY_YEAR=$((10#$2))
                AGGREGATE_DAY_MONTH=$((10#$3))
                AGGREGATE_DAY_DAY=$((10#$4))
                logDebug "Aggregating day ${AGGREGATE_DAY_YEAR}-${AGGREGATE_DAY_MONTH}-${AGGREGATE_DAY_DAY}"
                shift 4
                ;;
            --from)
                if [ $# -lt 4 ]; then printUsage; exit 1; fi
                validateDate "$2" "$3" "$4"
                AGGREGATE_FROM_YEAR=$((10#$2))
                AGGREGATE_FROM_MONTH=$((10#$3))
                AGGREGATE_FROM_DAY=$((10#$4))
                AGGREGATE_TO_YEAR=$(TZ="$TIMEZONE" date +%Y)
                AGGREGATE_TO_MONTH=$(TZ="$TIMEZONE" date +%-m)
                AGGREGATE_TO_DAY=$(TZ="$TIMEZONE" date +%-d)
                shift 4
                if [[ "$1" == "--to" ]]; then
                    if [ $# -lt 4 ]; then printUsage; exit 1; fi
                    validateDate "$2" "$3" "$4"
                    AGGREGATE_TO_YEAR=$((10#$2))
                    AGGREGATE_TO_MONTH=$((10#$3))
                    AGGREGATE_TO_DAY=$((10#$4))
                    shift 4
                fi
                logDebug "Aggregating from day ${AGGREGATE_FROM_YEAR}-${AGGREGATE_FROM_MONTH}-${AGGREGATE_FROM_DAY} to ${AGGREGATE_TO_YEAR}-${AGGREGATE_TO_MONTH}-${AGGREGATE_TO_DAY}"
                ;;
            --yesterday)
                AGGREGATE_YESTERDAY=true
                logDebug "Aggregating yesterday"
                shift
                ;;
            --today)
                AGGREGATE_TODAY=true
                logDebug "Aggregating today"
                shift
                ;;
            --delete-aggregations)
                DELETE_AGGREGATIONS=true
                logDebug "Deleting aggregations."
                shift
                ;;
            --detect)
                DETECT_VALUES=true
                logDebug "Detecting loadpoints and vehicles."
                shift
                ;;
            *)
                printUsage
                exit 1
                ;;
        esac
    done
}

printUsage() {
    echo "Usage: One of the following:"
    echo "       `basename $0` --year <year> [--debug]"
    echo "       `basename $0` --month <year> <month> [--debug]"
    echo "       `basename $0` --day <year> <month> <day> [--debug]"
    echo "       `basename $0` --from <year> <month> <day> [--to <year> <month> <day>] [--debug]"
    echo "       `basename $0` --yesterday [--debug]"
    echo "       `basename $0` --today [--debug]"
    echo "       `basename $0` --detect [--debug]"
    echo "       `basename $0` --delete-aggregations [--debug]"
    echo "       Add --dry-run to calculate and print daily samples without any writes."
}


deleteMetric() {
    local metric=$1
    logInfo "  - Deleting $metric"
    vmRequest /api/v1/admin/tsdb/delete_series -X POST --data-urlencode "match[]=${metric}" >/dev/null
}


deleteAggregations() {
    logWarning "You are about to delete all aggregated metrics. You will lose all historical metrics for the time frames, where realtime data is no longer available."
    logWarning "Are you sure you want to delete all aggregated data? Type 'YES' to continue."
    local confirmation
    read confirmation
    if [ "$confirmation" == "YES" ]; then
        logInfo "Deleting all aggregated metrics in 3 seconds."
        sleep 1
        logInfo "Deleting all aggregated metrics in 2 seconds."
        sleep 1
        logInfo "Deleting all aggregated metrics in 1 seconds."
        sleep 1
        for metric in "${AGGREGATED_METRICS[@]}"; do
            deleteMetric "$metric" || return 1
        done
        logInfo "All aggregations deleted."
    else
        logInfo "Deletion of aggregated metrics aborted."
    fi
}

checkDependencies() {

    # Checking if required commands are available
    local missing=0
    for dep in curl jq mktemp; do
        if ! command -v $dep > /dev/null 2>&1; then
            logError "This script requires the '$dep' command. Please install '$dep'."
            missing=1
        fi
    done
    if [ $missing -ne 0 ]; then
        exit 1
    fi
}

# Parse simple configuration durations. Fractional sampling and compound durations
# are deliberately rejected rather than silently rounding day/price boundaries.
durationSeconds() {
    local value="$1" number unit
    [[ "$value" =~ ^([1-9][0-9]*)(s|m|h|d)$ ]] || { logError "Invalid duration: $value (use e.g. 60s, 15m, 1h)."; return 1; }
    number=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}
    case "$unit" in s) echo "$number";; m) echo $((number*60));; h) echo $((number*3600));; d) echo $((number*86400));; esac
}

vmRequest() {
    local endpoint="$1"; shift
    curl --silent --show-error --fail --connect-timeout 10 --max-time 180 \
        "${VM_AUTH[@]}" "$VM_URL$endpoint" "$@"
}

queryVM() {
    local endpoint="$1"; shift
    local response
    response=$(vmRequest "$endpoint" "$@") || { logError "VictoriaMetrics request failed: $endpoint"; return 1; }
    jq -e '.status == "success" and (.data.result | type == "array")' <<< "$response" >/dev/null || {
        logError "VictoriaMetrics returned an invalid/error response: $response"; return 1;
    }
    printf '%s\n' "$response"
}

# Calculate MEAN of matching RAW samples per interval, not a resampled gauge.
# Sums/counts are combined before division to match Influx's grouping across
# series with the same device tag. Include zero samples in the denominator.
powerMean() {
    local selector="$1" mode="$2" tag="$3" window="${SAMPLE_SECONDS}s"
    local x="$selector[$window] offset 1ms" numerator denominator
    case "$mode" in
        positive)
            numerator="sum_gt_over_time($x,0) - sum_gt_over_time($x,$PEAK_POWER_LIMIT) - sum_eq_over_time($x,$PEAK_POWER_LIMIT)"
            denominator="count_gt_over_time($x,0) + count_eq_over_time($x,0) - count_gt_over_time($x,$PEAK_POWER_LIMIT) - count_eq_over_time($x,$PEAK_POWER_LIMIT)";;
        negative)
            # Keep the legacy signed charging/export convention. Unlike the old
            # upper-only peak check, reject impossible negative spikes as well.
            numerator="sum_le_over_time($x,0) - sum_le_over_time($x,-$PEAK_POWER_LIMIT)"
            denominator="count_le_over_time($x,0) - count_le_over_time($x,-$PEAK_POWER_LIMIT)";;
        signed)
            numerator="sum_le_over_time($x,$PEAK_POWER_LIMIT) - sum_eq_over_time($x,$PEAK_POWER_LIMIT) - sum_le_over_time($x,-$PEAK_POWER_LIMIT)"
            denominator="count_le_over_time($x,$PEAK_POWER_LIMIT) - count_eq_over_time($x,$PEAK_POWER_LIMIT) - count_le_over_time($x,-$PEAK_POWER_LIMIT)";;
        *) logError "Unknown power filter: $mode"; return 1;;
    esac
    local grouping=""
    [[ -n "$tag" ]] && grouping="by ($tag)"
    printf '(sum %s(%s)) / clamp_min(sum %s(%s),1)\n' "$grouping" "$numerator" "$grouping" "$denominator"
}

powerMatrix() {
    local selector="$1" mode="$2" tag="$3" expression
    expression=$(powerMean "$selector" "$mode" "$tag") || return 1
    queryVM /api/v1/query_range --get --data-urlencode "query=$expression" \
        --data-urlencode "start=$((DAY_START+SAMPLE_SECONDS))" \
        --data-urlencode "end=$SAMPLE_END" --data-urlencode "step=$SAMPLE_SECONDS"
}

# Trapezoids between adjacent interval means, including zero-filled missing
# intervals. No extrapolation before the first or after the last bin centre.
# Tariff intervals are multiples of the sample interval, so each trapezoid
# belongs to the tariff interval of its left bin. All time arithmetic here
# is UTC seconds; local date handling stays in Bash.
reducePower() {
    local matrix="$1" prices="$2" sign="$3"
    # Responses can exceed Linux's per-argument size limit (typically 128 KiB).
    # printf is a Bash builtin: pass the two JSON documents over stdin, never
    # as jq command-line arguments.
    printf '%s\n%s\n' "$matrix" "$prices" | jq -s \
        --argjson start "$DAY_START" --argjson stop "$SAMPLE_END" \
        --argjson step "$SAMPLE_SECONDS" --argjson tariff "$TARIFF_SECONDS" \
        --argjson sign "$sign" '
        .[0] as $power | .[1] as $prices |
        def numeric: (tonumber) as $v | if ($v|isnan) or ($v|isinfinite) then error("non-finite sample") else $v end;
        (($stop-$start)/$step | floor) as $n |
        (($prices.data.result[0].values // []) | map({key: (((.[0]-$start)/$tariff | round)-1 | tostring), value:(.[1]|numeric)}) | from_entries) as $p |
        [
            $power.data.result[] |
            .metric as $labels |
            (.values | map({key: (((.[0]-$start)/$step | round)-1 | tostring), value:(.[1]|numeric)}) | from_entries) as $v |
            (reduce range(1;$n) as $i ({area:0, missing:false};
                ($v[($i-1|tostring)] // 0) as $a |
                ($v[($i|tostring)] // 0) as $b |
                (($a+$b)*$step/2) as $energy |
                if $prices == null then .area += $energy
                elif $energy == 0 then .
                else
                    # A segment lies between bin STARTS; bins ending at T were
                    # queried at T with a 1ms offset to select [T-step,T).
                    ((($i-1)*$step/$tariff)|floor|tostring) as $block |
                    if $p[$block] == null then .missing = true
                    else .area += $energy*$p[$block] end
                end
            )) as $sum |
            {metric:$labels, missing:$sum.missing, value:[$start, ($sum.area*$sign/(if $prices==null then 3600 else 3600000 end)|tostring)]}
        ] as $results |
        {status:"success", missingTariffs:[$results[] | select(.missing) | .metric],
         data:{resultType:"vector", result:[$results[] | select(.missing|not) | del(.missing)]}}
    '
}

tariffMatrix() {
    local metric="$1" mode="$2" seed response expression partial remainder complete lastvalue lasttime
    seed=$(queryVM /api/v1/query --get --data-urlencode "query=avg(last_over_time($metric[100y] offset 1ms))" --data-urlencode "time=$DAY_START") || return 1
    seed=$(jq -r '.data.result[0].value[1] // empty' <<< "$seed")
    # If no historic price exists, do not invent free energy.
    expression="avg(last_over_time($metric[${TARIFF_SECONDS}s] offset 1ms))"
    if [[ "$mode" == mean ]]; then
        expression="sum(sum_over_time($metric[${TARIFF_SECONDS}s] offset 1ms)) / sum(count_over_time($metric[${TARIFF_SECONDS}s] offset 1ms))"
    fi
    complete=$(( (SAMPLE_END-DAY_START)/TARIFF_SECONDS ))
    remainder=$(( (SAMPLE_END-DAY_START)%TARIFF_SECONDS ))
    if (( complete > 0 )); then
        local filled="keep_last_value($expression)"
        [[ -n "$seed" ]] && filled="($filled) default $seed"
        response=$(queryVM /api/v1/query_range --get --data-urlencode "query=$filled" \
            --data-urlencode "start=$((DAY_START+TARIFF_SECONDS))" \
            --data-urlencode "end=$((DAY_START+complete*TARIFF_SECONDS))" --data-urlencode "step=$TARIFF_SECONDS") || return 1
    else
        response='{"status":"success","data":{"resultType":"matrix","result":[]}}'
    fi
    if (( remainder > 0 )); then
        expression="avg(last_over_time($metric[${remainder}s] offset 1ms))"
        [[ "$mode" == mean ]] && expression="sum(sum_over_time($metric[${remainder}s] offset 1ms)) / sum(count_over_time($metric[${remainder}s] offset 1ms))"
        partial=$(queryVM /api/v1/query --get --data-urlencode "query=$expression" --data-urlencode "time=$SAMPLE_END") || return 1
        lastvalue=$(jq -r '.data.result[0].value[1] // empty' <<< "$partial")
        [[ -z "$lastvalue" ]] && lastvalue=$(jq -r '.data.result[0].values[-1][1] // empty' <<< "$response")
        [[ -z "$lastvalue" ]] && lastvalue="$seed"
        if [[ -n "$lastvalue" ]]; then
            lasttime=$((DAY_START+(complete+1)*TARIFF_SECONDS))
            response=$(jq --arg value "$lastvalue" --argjson time "$lasttime" '
                if (.data.result|length)==0 then .data.result=[{metric:{},values:[]}] else . end |
                .data.result[0].values += [[$time,$value]]' <<< "$response") || return 1
        fi
    fi
    printf '%s\n' "$response"
}

# Validate every vector before staging it. Scalars MUST be a single series;
# device outputs MUST have exactly one series per nonempty requested tag.
# Never silently discard extra results with result[0].
stageResult() {
    local metric="$1" tag="$2" response="$3" lines
    lines=$(jq -er --arg metric "$metric" --arg tag "$tag" --arg day "$DAY_DATE" \
        --arg month "${DAY_DATE:0:7}" --arg year "${DAY_DATE:0:4}" --argjson ts "$((DAY_START*1000))" '
        .data.result as $r |
        if ($tag=="" and ($r|length)>1) then error("multiple scalar series")
        elif ($tag!="" and (any($r[]; (.metric[$tag] // "")=="") or ([$r[].metric[$tag]]|unique|length)!=($r|length))) then error("missing/duplicate device labels")
        else $r[] |
            (.value[1]|tonumber) as $v |
            if ($v|isnan) or ($v|isinfinite) then error("non-finite result") else
            $metric+"{year="+($year|tojson)+",month="+($month|tojson)+",day="+($day|tojson)+
            (if $tag=="" then "" else ","+$tag+"="+(.metric[$tag]|tojson) end)+"} "+($v|tostring)+" "+($ts|tostring) end
        end' <<< "$response")
    local status=$?
    if (( status == 4 )) && [[ $(jq '.data.result|length' <<< "$response") == 0 ]]; then
        logDebug "$DAY_DATE: no data for $metric; existing values retained."
        return 0
    fi
    (( status == 0 )) || { logError "Invalid results for $metric; day not published."; return 1; }
    printf '%s\n' "$lines" >> "$DAY_OUTPUT"
    DAY_METRICS+=("$metric")
}

aggregateEnergy() {
    local metric="$1" selector="$2" mode="$3" tag="$4" sign="$5" response
    logDebug "  - Calculating $metric"
    response=$(powerMatrix "$selector" "$mode" "$tag") || return 1
    response=$(reducePower "$response" null "$sign") || return 1
    stageResult "$metric" "$tag" "$response"
}

aggregateCost() {
    local metric="$1" selector="$2" mode="$3" tag="$4" sign="$5" prices="$6" response
    logDebug "  - Calculating $metric"
    response=$(powerMatrix "$selector" "$mode" "$tag") || return 1
    response=$(reducePower "$response" "$prices" "$sign") || return 1
    local missing
    missing=$(jq '.missingTariffs | length' <<< "$response") || return 1
    if (( missing > 0 )); then
        logWarning "$DAY_DATE: $metric omitted for $missing series: energy without tariff; previous costs for those series removed on publication."
        # Publication replaces this metric/day as a whole. Valid devices are
        # staged below; omitted devices must not retain misleading old costs.
        if [[ $(jq '.data.result|length' <<< "$response") == 0 ]]; then
            DAY_METRICS+=("$metric")
            return 0
        fi
    fi
    stageResult "$metric" "$tag" "$response"
}

aggregateStatistic() {
    local metric="$1" expression="$2" tag="${3:-}" response
    response=$(queryVM /api/v1/query --get --data-urlencode "query=$expression" --data-urlencode "time=$DAY_CUTOFF") || return 1
    stageResult "$metric" "$tag" "$response"
}

aggregateSoc() {
    local raw response
    # Filtering before min/max must operate on RAW values, without a subquery
    # that samples away short extrema. Export is read-only and restricted to one day.
    raw=$(vmRequest /api/v1/export --get --data-urlencode 'match[]=batterySoc_value{id=""}' \
        --data-urlencode "start=$DAY_START" --data-urlencode "end=$((DAY_CUTOFF-1)).999") || return 1
    response=$(jq -s --argjson start "$((DAY_START*1000))" --argjson stop "$((DAY_CUTOFF*1000))" '
        [ .[] | if (.metric|type)!="object" or (.values|type)!="array" or (.timestamps|type)!="array" or (.values|length)!=(.timestamps|length) then error("invalid raw export") else . end | . as $s | range(0;(.values|length)) as $i |
          select($s.timestamps[$i]>=$start and $s.timestamps[$i]<$stop) |
          $s.values[$i] | select(type=="number" and .>=0 and .<=100) ] as $v |
        {status:"success",data:{result:[if ($v|length)>0 then {metric:{},value:[0,($v|max|tostring)]} else empty end]}}' <<< "$raw") || return 1
    stageResult batterySocMaxDaily "" "$response" || return 1
    response=$(jq -s --argjson start "$((DAY_START*1000))" --argjson stop "$((DAY_CUTOFF*1000))" '
        [ .[] | if (.metric|type)!="object" or (.values|type)!="array" or (.timestamps|type)!="array" or (.values|length)!=(.timestamps|length) then error("invalid raw export") else . end | . as $s | range(0;(.values|length)) as $i |
          select($s.timestamps[$i]>=$start and $s.timestamps[$i]<$stop) |
          $s.values[$i] | select(type=="number" and .>0 and .<=100) ] as $v |
        {status:"success",data:{result:[if ($v|length)>0 then {metric:{},value:[0,($v|min|tostring)]} else empty end]}}' <<< "$raw") || return 1
    stageResult batterySocMinDaily "" "$response"
}

aggregateDay() {
    DAY_DATE="$1"
    DAY_START=$(TZ="$TIMEZONE" date -d "$DAY_DATE 00:00:00" +%s) || return 1
    # Advance the calendar date in UTC; only then resolve local midnight.
    local next_date next_start now elapsed window grid_prices feed_prices charge_prices
    next_date=$(TZ=UTC date -d "$DAY_DATE +1 day" +%F) || return 1
    next_start=$(TZ="$TIMEZONE" date -d "$next_date 00:00:00" +%s) || return 1
    now=$(date +%s)
    (( DAY_START < now )) || { logInfo "Skipping future day $DAY_DATE"; return 0; }
    DAY_CUTOFF=$next_start
    (( DAY_CUTOFF > now )) && DAY_CUTOFF=$now
    SAMPLE_END=$((DAY_START+(DAY_CUTOFF-DAY_START)/SAMPLE_SECONDS*SAMPLE_SECONDS))
    (( SAMPLE_END-DAY_START >= SAMPLE_SECONDS*2 )) || { logInfo "Skipping $DAY_DATE: fewer than two complete sample intervals."; return 0; }
    elapsed=$((DAY_CUTOFF-DAY_START)); window="${elapsed}s"
    DAY_OUTPUT=$(mktemp) || return 1
    DAY_METRICS=()
    logInfo "Aggregating $DAY_DATE"

    aggregateEnergy pvEnergyDaily 'pvPower_value{id=""}' positive "" 1 || return 1
    aggregateEnergy homeEnergyDaily homePower_value positive "" 1 || return 1
    aggregateEnergy gridEnergyImportDaily gridPower_value positive "" 1 || return 1
    aggregateEnergy gridEnergyExportDaily gridPower_value negative "" -1 || return 1
    aggregateEnergy loadpointEnergyDaily 'chargePower_value{loadpoint!=""}' positive loadpoint 1 || return 1
    aggregateEnergy vehicleEnergyDaily 'chargePower_value{vehicle!=""}' positive vehicle 1 || return 1
    aggregateEnergy auxEnergyDaily 'auxPower_value{title!=""}' positive title 1 || return 1
    aggregateEnergy extEnergyDaily 'extPower_value{title!=""}' positive title 1 || return 1
    aggregateEnergy consumerEnergyDaily 'consumersPower_value{title!=""}' positive title 1 || return 1
    aggregateStatistic vehicleOdometerMaxDaily "max by(vehicle)(max_over_time(vehicleOdometer_value{vehicle!=\"\"}[$window] offset 1ms))" vehicle || return 1
    aggregateStatistic greenShareHomeDaily "avg(avg_over_time(greenShareHome_value[$window] offset 1ms))" || return 1

    grid_prices=$(tariffMatrix tariffGrid_value last) || return 1
    feed_prices=$(tariffMatrix tariffFeedIn_value last) || return 1
    charge_prices=$(tariffMatrix tariffPriceLoadpoints_value mean) || return 1
    aggregateCost energyPriceBoughtDaily gridPower_value positive "" 1 "$grid_prices" || return 1
    aggregateCost energyPriceSoldDaily gridPower_value negative "" -1 "$feed_prices" || return 1
    aggregateCost potentialHomeDailyPrice homePower_value signed "" 1 "$grid_prices" || return 1
    aggregateCost potentialLoadpointDailyPrice 'chargePower_value{loadpoint!=""}' signed loadpoint 1 "$grid_prices" || return 1
    aggregateCost vehicleChargeDailyPrice 'chargePower_value{vehicle!=""}' signed vehicle 1 "$charge_prices" || return 1
    aggregateCost potentialVehicleChargeDailyPrice 'chargePower_value{vehicle!=""}' signed vehicle 1 "$grid_prices" || return 1
    if [[ "$HOME_BATTERY" == true ]]; then
        aggregateEnergy batteryEnergyDischargedDaily 'batteryPower_value{id=""}' positive "" 1 || return 1
        aggregateEnergy batteryEnergyChargedDaily 'batteryPower_value{id=""}' negative "" -1 || return 1
        aggregateCost energyDischargeDailyPrice 'batteryPower_value{id=""}' positive "" 1 "$grid_prices" || return 1
        aggregateCost energyChargeDailyPrice 'batteryPower_value{id=""}' negative "" 1 "$feed_prices" || return 1
        aggregateSoc || return 1
    fi
    if [[ "$DYNAMIC_TARIFF" == true ]]; then
        aggregateStatistic energyPriceMaxDaily "max(max_over_time(tariffGrid_value[$window] offset 1ms))" || return 1
        aggregateStatistic energyPriceMinDaily "min(min_over_time(tariffGrid_value[$window] offset 1ms))" || return 1
        aggregateStatistic energyPriceAvgDaily "sum(sum_over_time(tariffGrid_value[$window] offset 1ms))/sum(count_over_time(tariffGrid_value[$window] offset 1ms))" || return 1
    fi
    if [[ "$DRY_RUN" == true ]]; then
        cat "$DAY_OUTPUT"
    else
        # All calculations/validation for the day have succeeded before deleting
        # any old values. A failed request must never be reported as success.
        local metric
        for metric in "${DAY_METRICS[@]}"; do
            vmRequest /api/v1/admin/tsdb/delete_series -X POST \
                --data-urlencode "match[]=$metric{year=\"${DAY_DATE:0:4}\",month=\"${DAY_DATE:0:7}\",day=\"$DAY_DATE\"}" >/dev/null || return 1
        done
        if [[ -s "$DAY_OUTPUT" ]]; then
            vmRequest /api/v1/import/prometheus --data-binary "@$DAY_OUTPUT" >/dev/null || return 1
        fi
    fi
    rm -f "$DAY_OUTPUT"
    DAY_OUTPUT=""
}

aggregateRange() {
    local current="$1" final="$2"
    [[ "$current" > "$final" ]] && { logError "Start date is after end date."; return 1; }
    while [[ ! "$current" > "$final" ]]; do
        aggregateDay "$current" || return 1
        current=$(TZ=UTC date -d "$current +1 day" +%F) || return 1
    done
}


###############################################################################
### MAIN
###############################################################################


main() {
    local config_dir
    config_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    if [[ -f "$config_dir/evcc-vm-aggregate.conf" ]]; then
        . "$config_dir/evcc-vm-aggregate.conf"
    else
        logError "Configuration file $config_dir/evcc-vm-aggregate.conf not found."
        return 1
    fi
    checkDependencies || return 1
    date -d '2000-01-01' +%s >/dev/null 2>&1 || { logError "GNU date is required."; return 1; }
    [[ -n "$TIMEZONE" ]] || { logError "TIMEZONE must be configured."; return 1; }
    SAMPLE_SECONDS=$(durationSeconds "$ENERGY_SAMPLE_INTERVAL") || return 1
    TARIFF_SECONDS=$(durationSeconds "$TARIFF_PRICE_INTERVAL") || return 1
    (( TARIFF_SECONDS % SAMPLE_SECONDS == 0 && SAMPLE_SECONDS <= 3600 && 3600 % SAMPLE_SECONDS == 0 )) || {
        logError "The tariff interval must be a multiple of the sample interval; the sample interval must divide one hour."; return 1;
    }
    [[ "$PEAK_POWER_LIMIT" =~ ^[1-9][0-9]*$ ]] || { logError "PEAK_POWER_LIMIT must be a positive integer."; return 1; }
    VM_URL="http://${VM_HOST}:${VM_PORT}"
    VM_AUTH=()
    [[ -n "$VM_USER" ]] && VM_AUTH=(--user "$VM_USER:$VM_PASSWORD")
    parseArguments "$@"
    if [[ "$DELETE_AGGREGATIONS" == true ]]; then
        [[ "$DRY_RUN" == true ]] && { logError "--dry-run cannot be combined with --delete-aggregations."; return 1; }
        deleteAggregations
        return $?
    fi
    local first final
    if (( AGGREGATE_YEAR != 0 )); then
        printf -v first '%04d-01-01' "$AGGREGATE_YEAR"
        printf -v final '%04d-12-31' "$AGGREGATE_YEAR"
    elif (( AGGREGATE_MONTH_YEAR != 0 )); then
        printf -v first '%04d-%02d-01' "$AGGREGATE_MONTH_YEAR" "$AGGREGATE_MONTH_MONTH"
        final=$(TZ=UTC date -d "$first +1 month -1 day" +%F) || return 1
    elif (( AGGREGATE_DAY_YEAR != 0 )); then
        printf -v first '%04d-%02d-%02d' "$AGGREGATE_DAY_YEAR" "$AGGREGATE_DAY_MONTH" "$AGGREGATE_DAY_DAY"
        final="$first"
    elif (( AGGREGATE_FROM_YEAR != 0 )); then
        printf -v first '%04d-%02d-%02d' "$AGGREGATE_FROM_YEAR" "$AGGREGATE_FROM_MONTH" "$AGGREGATE_FROM_DAY"
        printf -v final '%04d-%02d-%02d' "$AGGREGATE_TO_YEAR" "$AGGREGATE_TO_MONTH" "$AGGREGATE_TO_DAY"
    elif [[ "$AGGREGATE_YESTERDAY" == true ]]; then
        first=$(TZ="$TIMEZONE" date -d yesterday +%F); final="$first"
    elif [[ "$AGGREGATE_TODAY" == true ]]; then
        first=$(TZ="$TIMEZONE" date +%F); final="$first"
    else
        printUsage; return 1
    fi
    trap '[[ -z "$DAY_OUTPUT" ]] || rm -f "$DAY_OUTPUT"' EXIT
    aggregateRange "$first" "$final" || { logError "Aggregation failed; stopping."; return 1; }
    logDebug "Aggregation finished."
}

# Allow tests to source the query builders without running a live aggregation.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
