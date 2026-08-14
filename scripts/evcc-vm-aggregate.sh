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

# Array of vehicles
declare -A VEHICLES

#Array of loadpoints
declare -A LOADPOINTS

#Array of ext devices
declare -A EXT_DEVICES

#Array of aux devices
declare -A AUX_DEVICES



###############################################################################
### FUNCTIONS
###############################################################################


logError() {
    local msg="$1"
    echo "[ERROR]   $msg"
}

logWarning() {
    local msg="$1"
    echo "[WARNING] $msg"
}

logInfo() {
    local msg="$1"
    echo "[INFO]    $msg"
}

logDebug() {
    local msg="$1"
    if [ "$DEBUG" == "true" ]; then
        echo "[DEBUG]   $msg"
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
    local year=$1
    local month=$2
    local day=$3

    # Validate year, month, and day as a full date if all are provided
    if [ -n "$year" ] && [ -n "$month" ] && [ -n "$day" ]; then
        if ! date -d "$year-$(printf "%02d" $month)-$(printf "%02d" $day)" "+%Y-%m-%d" >/dev/null 2>&1; then
            logError "Invalid date: $year-$month-$day"
            exit 1
        fi
        return 0
    fi

    # Validate year and month if only those are provided
    if [ -n "$year" ] && [ -n "$month" ]; then
        if ! date -d "$year-$(printf "%02d" $month)-01" "+%Y-%m-%d" >/dev/null 2>&1; then
            logError "Invalid year/month: $year-$month"
            exit 1
        fi
        return 0
    fi

    # Validate year only
    if [ -n "$year" ]; then
        if ! validateNumber "$year" || [ "$year" -lt 1970 ] || [ "$year" -gt 2100 ]; then
            logError "Year must be a number between 1970 and 2100."
            exit 1
        fi
        return 0
    fi
}

parseArguments() {
    if [ $# -eq 0 ]; then
        printUsage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --debug)
                export DEBUG=true
                logDebug "Enabling debug."
                shift
                ;;
            --year)
                if [ $# -lt 2 ]; then printUsage; exit 1; fi
                validateDate "$2"
                AGGREGATE_YEAR="$2"
                logDebug "Aggregating year $AGGREGATE_YEAR"
                shift 2
                ;;
            --month)
                if [ $# -lt 3 ]; then printUsage; exit 1; fi
                validateDate "$2" "$3"
                AGGREGATE_MONTH_YEAR="$2"
                AGGREGATE_MONTH_MONTH="$3"
                logDebug "Aggregating month ${AGGREGATE_MONTH_YEAR}-${AGGREGATE_MONTH_MONTH}"
                shift 3
                ;;
            --day)
                if [ $# -lt 4 ]; then printUsage; exit 1; fi
                validateDate "$2" "$3" "$4"
                AGGREGATE_DAY_YEAR="$2"
                AGGREGATE_DAY_MONTH="$3"
                AGGREGATE_DAY_DAY="$4"
                logDebug "Aggregating day ${AGGREGATE_DAY_YEAR}-${AGGREGATE_DAY_MONTH}-${AGGREGATE_DAY_DAY}"
                shift 4
                ;;
            --from)
                if [ $# -lt 4 ]; then printUsage; exit 1; fi
                validateDate "$2" "$3" "$4"
                AGGREGATE_FROM_YEAR="$2"
                AGGREGATE_FROM_MONTH="$3"
                AGGREGATE_FROM_DAY="$4"
                AGGREGATE_TO_YEAR=$(date +%Y)
                AGGREGATE_TO_MONTH=$(date +%-m)
                AGGREGATE_TO_DAY=$(date +%-d)
                shift 4
                if [[ "$1" == "--to" ]]; then
                    if [ $# -lt 4 ]; then printUsage; exit 1; fi
                    validateDate "$2" "$3" "$4"
                    AGGREGATE_TO_YEAR="$2"
                    AGGREGATE_TO_MONTH="$3"
                    AGGREGATE_TO_DAY="$4"
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
}


deleteMetric() {
    local metric=$1
    logInfo "  - Deleting $metric"
    curl -s -X POST "http://${VM_HOST}:${VM_PORT}/api/v1/admin/tsdb/delete_series" -d "match[]=${metric}"
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
        deleteMetric "pvEnergyDaily"
        deleteMetric "homeEnergyDaily"
        deleteMetric "gridEnergyImportDaily"
        deleteMetric "gridEnergyExportDaily"
        deleteMetric "batteryEnergyDischargedDaily"
        deleteMetric "batteryEnergyChargedDaily"
        deleteMetric "loadpointEnergyDaily"
        deleteMetric "auxEnergyDaily"
        deleteMetric "extEnergyDaily"
        deleteMetric "consumerEnergyDaily"
        deleteMetric "energyPriceBoughtDaily"
        deleteMetric "energyPriceSoldDaily"
        deleteMetric "energyPriceMaxDaily"
        deleteMetric "energyPriceMinDaily"
        deleteMetric "energyPriceAvgDaily"
        deleteMetric "greenShareHomeDaily"
        deleteMetric "batterySocMaxDaily"
        deleteMetric "batterySocMinDaily"
    else
        logInfo "Deletion of aggregated metrics aborted."
    fi

    logInfo "All aggregations deleted."
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

aggregateQuery() {
    local query="$1"
    local metric="$2"
    local starttime="$3"
    local endtime="$4"
    local encoded_query
    encoded_query=$(jq -rn --arg v "$query" '$v|@uri')

    logInfo "  - Calculating $metric"

    logDebug "Executing aggregation: $query"
    local last_deleted_date=""
    local jq_output
    local jq_err
    jq_err=$(mktemp)
    jq_output=$(curl -s "http://${VM_HOST}:${VM_PORT}/api/v1/query_range" \
        -d "query=${encoded_query}" \
        -d "start=${starttime}" \
        -d "end=${endtime}" \
        -d "step=1d" | jq -r '
            .data.result[0].values[]
            | [
                (.[0] | tonumber),
                (.[1] | tonumber)
            ]
            | @csv
        ' 2>"$jq_err")

    local jq_err_content
    jq_err_content=$(cat "$jq_err")
    rm -f "$jq_err"

    if [ -n "$jq_err_content" ]; then
        if echo "$jq_err_content" | grep -q "Cannot iterate over null"; then
            logInfo "    No data returned for $metric (query result is null)."
            return
        else
            logError "jq error for $metric: $jq_err_content"
            return
        fi
    fi

    if [ -z "$jq_output" ]; then
        logInfo "    No data returned for $metric (query result is empty)."
        return
    fi

    echo "$jq_output" | while IFS=',' read -r timestamp value; do
            # Calculate timezone-aware date for THIS specific timestamp (handles DST correctly)
            local ts_int=${timestamp%.*}
            local year=$(TZ="$TIMEZONE" date -d @$ts_int +%Y)
            local month=$(TZ="$TIMEZONE" date -d @$ts_int +%m)
            local day=$(TZ="$TIMEZONE" date -d @$ts_int +%d)
            local month_str="${year}-${month}"
            local date_str="${year}-${month}-${day}"

            # Delete existing data for this day before inserting to make sure that there is just one aggregation per day (only once per day)
            if [ "$last_deleted_date" != "$date_str" ]; then
                logDebug "Deleting series for metric $metric with labels year=\"$year\", month=\"$month_str\", day=\"$date_str\""
                curl -s -X POST "http://${VM_HOST}:${VM_PORT}/api/v1/admin/tsdb/delete_series" \
                    -d "match[]=${metric}{year=\"${year}\",month=\"${month_str}\",day=\"${date_str}\"}" > /dev/null
                last_deleted_date="$date_str"
            fi

            local line="${metric}{year=\"${year}\",month=\"${month_str}\",day=\"${date_str}\"} ${value} ${timestamp}"
            logDebug "Inserting line: $line"
            echo "$line" | curl -s --data-binary @- "http://${VM_HOST}:${VM_PORT}/api/v1/import/prometheus" > /dev/null
        done
}

aggregateQueryByTag() {
    local query="$1"
    local tag="$2"
    local metric="$3"
    local starttime="$4"
    local endtime="$5"
    local encoded_query
    encoded_query=$(jq -rn --arg v "$query" '$v|@uri')

    logInfo "  - Calculating $metric"

    logDebug "Executing aggregation: $query"
    local last_deleted_date=""
    local jq_output
    local jq_err
    jq_err=$(mktemp)
    jq_output=$(curl -s "http://${VM_HOST}:${VM_PORT}/api/v1/query_range" \
        -d "query=${encoded_query}" \
        -d "start=${starttime}" \
        -d "end=${endtime}" \
        -d "step=1d" | jq -r --arg tag_name "$tag" '
            (.data.result[] | .metric[$tag_name] as $tag_value | .values[] | 
            (.[0] | tonumber) as $timestamp |
            (.[1] | tonumber) as $value |
            [$tag_value, $timestamp, $value]) | @csv
        ' 2>"$jq_err")

    local jq_err_content
    jq_err_content=$(cat "$jq_err")
    rm -f "$jq_err"

    if [ -n "$jq_err_content" ]; then
        if echo "$jq_err_content" | grep -q "Cannot iterate over null"; then
            logInfo "    No data returned for $metric (query result is null)."
            return
        else
            logError "jq error for $metric: $jq_err_content"
            return
        fi
    fi

    if [ -z "$jq_output" ]; then
        logInfo "    No data returned for $metric (query result is empty)."
        return
    fi

    echo "$jq_output" | while IFS=',' read -r tagValue timestamp value; do
            # Remove quotes from tagValue if present
            tagValue="${tagValue//\"/}"
            # Calculate timezone-aware date for THIS specific timestamp (handles DST correctly)
            local ts_int=${timestamp%.*}
            local year=$(TZ="$TIMEZONE" date -d @$ts_int +%Y)
            local month=$(TZ="$TIMEZONE" date -d @$ts_int +%m)
            local day=$(TZ="$TIMEZONE" date -d @$ts_int +%d)
            local month_str="${year}-${month}"
            local date_str="${year}-${month}-${day}"
            local delete_key="${tagValue}::${date_str}"

            # Delete existing data for this tag+day before inserting to make sure that there is just one aggregation per day (only once per tag per day)
            if [ "$last_deleted_date" != "$delete_key" ]; then
                logDebug "Deleting series for metric $metric with labels ${tag}=\"$tagValue\", year=\"$year\", month=\"$month_str\", day=\"$date_str\""
                curl -s -X POST "http://${VM_HOST}:${VM_PORT}/api/v1/admin/tsdb/delete_series" \
                    -d "match[]=${metric}{${tag}=\"${tagValue}\",year=\"${year}\",month=\"${month_str}\",day=\"${date_str}\"}" > /dev/null
                last_deleted_date="$delete_key"
            fi

            local line="${metric}{${tag}=\"${tagValue}\",year=\"${year}\",month=\"${month_str}\",day=\"${date_str}\"} ${value} ${timestamp}"
            logDebug "Inserting line: $line"
            echo "$line" | curl -s --data-binary @- "http://${VM_HOST}:${VM_PORT}/api/v1/import/prometheus" > /dev/null
        done
}

aggregate() {
    local starttime="$1"
    local endtime="$2"

    logDebug "Aggregating from $(date -d @$starttime) ($starttime) to $(date -d @$endtime) ($endtime)"

    # pvEnergyDaily
    aggregateQuery "sum(integrate(((pvPower_value{id=\"\"}) default 0) [1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d)/3600)" "pvEnergyDaily" "$starttime" "$endtime"
    # homeEnergyDaily
    aggregateQuery "sum(integrate(((homePower_value) default 0) [1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d)/ 3600)" "homeEnergyDaily" "$starttime" "$endtime"
    # gridEnergyImportDaily
    aggregateQuery "integrate(((gridPower_value > 0) default 0) [1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d) / 3600" "gridEnergyImportDaily" "$starttime" "$endtime"
    # gridEnergyExportDaily
    aggregateQuery "integrate(((gridPower_value < 0) default 0) [1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d) / -3600" "gridEnergyExportDaily" "$starttime" "$endtime"
    # batteryEnergyDischargedDaily
    aggregateQuery "integrate(((batteryPower_value{id=\"\"} > 0) default 0) [1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d) / 3600" "batteryEnergyDischargedDaily" "$starttime" "$endtime"
    # batteryEnergyChargedDaily
    aggregateQuery "integrate(((batteryPower_value{id=\"\"} < 0) default 0) [1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d) / -3600" "batteryEnergyChargedDaily" "$starttime" "$endtime"
    # loadpointEnergyDaily
    aggregateQueryByTag "sum by (loadpoint)(integrate(((chargePower_value{loadpoint!=\"\"}) default 0)[1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d) / 3600)" "loadpoint" "loadpointEnergyDaily" "$starttime" "$endtime"
    # auxEnergyDaily
    aggregateQueryByTag "sum by (title)(integrate(((auxPower_value{title!=\"\"}) default 0)[1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d) / 3600)" "title" "auxEnergyDaily" "$starttime" "$endtime"
    # extEnergyDaily
    aggregateQueryByTag "sum by (title)(integrate(((extPower_value{title!=\"\"}) default 0)[1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d) / 3600)" "title" "extEnergyDaily" "$starttime" "$endtime"
    # consumerEnergyDaily
    aggregateQueryByTag "sum by (title)(integrate(((consumersPower_value{title!=\"\"}) default 0)[1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d) / 3600)" "title" "consumerEnergyDaily" "$starttime" "$endtime"
    # energyPriceBoughtDaily
    aggregateQuery "sum_over_time(( keep_last_value(avg(tariffGrid_value[1h:$TARIFF_PRICE_INTERVAL] offset -$TARIFF_PRICE_INTERVAL)) * integrate((avg(gridPower_value > 0) default 0)[$TARIFF_PRICE_INTERVAL:${ENERGY_SAMPLE_INTERVAL}] offset -$TARIFF_PRICE_INTERVAL) / 3600000)[1d:$TARIFF_PRICE_INTERVAL] offset -1d)" "energyPriceBoughtDaily" "$starttime" "$endtime"
    # energyPriceSoldDaily
    aggregateQuery "sum_over_time(( keep_last_value(tariffFeedIn_value[30d:$TARIFF_PRICE_INTERVAL] offset -$TARIFF_PRICE_INTERVAL) * integrate((avg(gridPower_value < 0) default 0)[$TARIFF_PRICE_INTERVAL:${ENERGY_SAMPLE_INTERVAL}] offset -$TARIFF_PRICE_INTERVAL) / 3600000)[1d:$TARIFF_PRICE_INTERVAL] offset -1d) * (-1)" "energyPriceSoldDaily" "$starttime" "$endtime"
    # energyPriceMaxDaily
    aggregateQuery "max_over_time(avg(tariffGrid_value offset -$TARIFF_PRICE_INTERVAL)[1d:$TARIFF_PRICE_INTERVAL] offset -1d)" "energyPriceMaxDaily" "$starttime" "$endtime"
    # energyPriceMinDaily
    aggregateQuery "min_over_time(avg(tariffGrid_value offset -$TARIFF_PRICE_INTERVAL)[1d:$TARIFF_PRICE_INTERVAL] offset -1d)" "energyPriceMinDaily" "$starttime" "$endtime"
    # energyPriceAvgDaily
    aggregateQuery "avg_over_time(avg(tariffGrid_value offset -$TARIFF_PRICE_INTERVAL)[1d:$TARIFF_PRICE_INTERVAL] offset -1d)" "energyPriceAvgDaily" "$starttime" "$endtime"
    # greenShareHomeDaily
    aggregateQuery "avg_over_time(avg(greenShareHome_value offset -$TARIFF_PRICE_INTERVAL)[1d:$TARIFF_PRICE_INTERVAL] offset -1d)" "greenShareHomeDaily" "$starttime" "$endtime"
    # batterySocMaxDaily
    aggregateQuery "max_over_time(avg(batterySoc_value)[1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d)" "batterySocMaxDaily" "$starttime" "$endtime"
    # batterySocMinDaily (> 0 as read errors may return 0, which is extremely unlikely for a home battery)
    aggregateQuery "min_over_time(avg(batterySoc_value > 0)[1d:${ENERGY_SAMPLE_INTERVAL}] offset -1d)" "batterySocMinDaily" "$starttime" "$endtime"
}



###############################################################################
### MAIN
###############################################################################


# Source configuration from evcc-influx-aggregate.conf, which needs to be located in the same directory as this script.
if [ -f "$(dirname $0)/evcc-vm-aggregate.conf" ]; then
    . "$(dirname $0)/evcc-vm-aggregate.conf"
else
    logError "Configuration file $(dirname $0)/evcc-vm-aggregate.conf not found."
    exit 1
fi


start_time=$(date +%s)


# Crontab may not have /usr/local/bin in PATH, so we add it here if it exists.
if [ -d "/usr/local/bin" ]; then
    export PATH="$PATH:/usr/local/bin"
fi


checkDependencies

# Check if timezone is set
if [ "$TIMEZONE" == "" ]; then
    logError "Timezone is not set. Please set the script variable TIMEZONE to your timezone."
    exit 1
fi

parseArguments $@

if [ "$AGGREGATE_YEAR" -ne 0 ]; then
    # Aggregating by month, because aggregating whole year at once can lead to "too many points" errors.
    for month in {1..12}; do
        starttime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_YEAR-$(printf "%02d" $month)-01 00:00:00" +%s)
        # Get last day of the month
        last_day=$(TZ="$TIMEZONE" date -d "$AGGREGATE_YEAR-$(printf "%02d" $month)-01 +1 month -1 day" +%d)
        endtime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_YEAR-$(printf "%02d" $month)-$last_day 23:59:59" +%s)
        logInfo "Aggregating $AGGREGATE_YEAR-$(printf "%02d" $month)"
        aggregate "$starttime" "$endtime"
    done
elif [ "$AGGREGATE_MONTH_YEAR" -ne 0 ]; then
    starttime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_MONTH_YEAR-$(printf "%02d" $AGGREGATE_MONTH_MONTH)-01 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_MONTH_YEAR-$(printf "%02d" $AGGREGATE_MONTH_MONTH)-01 +1 month -1 day 23:59:59" +%s)
    logInfo "Aggregating month $AGGREGATE_MONTH_YEAR-$(printf "%02d" $AGGREGATE_MONTH_MONTH)"
    aggregate "$starttime" "$endtime"
elif [ "$AGGREGATE_DAY_YEAR" -ne 0 ]; then
    starttime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_DAY_YEAR-$(printf "%02d" $AGGREGATE_DAY_MONTH)-$(printf "%02d" $AGGREGATE_DAY_DAY) 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_DAY_YEAR-$(printf "%02d" $AGGREGATE_DAY_MONTH)-$(printf "%02d" $AGGREGATE_DAY_DAY) 23:59:59" +%s)
    logInfo "Aggregating day $AGGREGATE_DAY_YEAR-$(printf "%02d" $AGGREGATE_DAY_MONTH)-$(printf "%02d" $AGGREGATE_DAY_DAY)"
    aggregate "$starttime" "$endtime"
elif [ "$AGGREGATE_FROM_YEAR" -ne 0 ]; then
    starttime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_FROM_YEAR-$(printf "%02d" $AGGREGATE_FROM_MONTH)-$(printf "%02d" $AGGREGATE_FROM_DAY) 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_TO_YEAR-$(printf "%02d" $AGGREGATE_TO_MONTH)-$(printf "%02d" $AGGREGATE_TO_DAY) 23:59:59" +%s)

    # Calculate the first day of the month for the start date
    current_year=$AGGREGATE_FROM_YEAR
    current_month=$AGGREGATE_FROM_MONTH

    # Loop until we pass the end date
    while : ; do
        # Calculate chunk start
        chunk_start=$(TZ="$TIMEZONE" date -d "$current_year-$(printf "%02d" $current_month)-01 00:00:00" +%s)
        # Calculate last day of this month
        last_day=$(TZ="$TIMEZONE" date -d "$current_year-$(printf "%02d" $current_month)-01 +1 month -1 day" +%d)
        # Calculate chunk end (end of this month or endtime, whichever is earlier)
        chunk_end=$(TZ="$TIMEZONE" date -d "$current_year-$(printf "%02d" $current_month)-$last_day 23:59:59" +%s)
        [ $chunk_end -gt $endtime ] && chunk_end=$endtime

        # Only aggregate if chunk overlaps the requested range
        if [ $chunk_end -ge $starttime ]; then
            # Use max of chunk_start and starttime
            agg_start=$chunk_start
            [ $agg_start -lt $starttime ] && agg_start=$starttime
            agg_end=$chunk_end
            logInfo "Aggregating $current_year-$(printf "%02d" $current_month)"
            logDebug "Aggregating from $(date -d @$agg_start) to $(date -d @$agg_end)"
            aggregate "$agg_start" "$agg_end"
        fi

        # Break if we've reached or passed the endtime
        if [ $chunk_end -ge $endtime ]; then
            break
        fi

        # Increment month/year
        if [ $current_month -eq 12 ]; then
            current_month=1
            current_year=$((current_year + 1))
        else
            current_month=$((current_month + 1))
        fi
    done
elif [ "$AGGREGATE_YESTERDAY" == "true" ]; then
    starttime=$(TZ="$TIMEZONE" date -d "yesterday 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "yesterday 23:59:59" +%s)
    logInfo "Aggregating yesterday"
    aggregate "$starttime" "$endtime"
elif [ "$AGGREGATE_TODAY" == "true" ]; then
    starttime=$(TZ="$TIMEZONE" date -d "today 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "today 23:59:59" +%s)
    logInfo "Aggregating today"
    aggregate "$starttime" "$endtime"
elif [ "$DELETE_AGGREGATIONS" == "true" ]; then
    deleteAggregations
    exit 0
fi

duration=$(( $(date +%s) - $start_time ))
hours=$((duration / 3600))
minutes=$(( (duration % 3600) / 60 ))
seconds=$((duration % 60))
printf -v duration "%02dh %02dm %02ds" $hours $minutes $seconds
echo
logInfo "Aggregation finished after ${duration}."
### END