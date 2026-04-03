#!/bin/bash

# Aggregation script for EVCC grafana dashboards. See https://github.com/ha-puzzles/evcc-grafana-dashboards

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

# Source configuration from evcc-influx-aggregate.conf, which needs to be located in the same directory as this script.
if [ -f "$(dirname $0)/evcc-vm-aggregate.conf" ]; then
    . "$(dirname $0)/evcc-vm-aggregate.conf"
else
    logError "Configuration file $(dirname $0)/evcc-vm-aggregate.conf not found."
    exit 1
fi

#arguments
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

    if ! validateNumber "$year" || [ "$year" -lt 1970 ] || [ "$year" -gt 2100 ]; then
        logError "Year must be a number between 1970 and 2100."
        exit 1
    fi

    if [ "$month" == "" ]; then
        return 0
    fi
    if ! validateNumber "$month" || [ "$month" -lt 1 ] || [ "$month" -gt 12 ]; then
        logError "Month must be number between 1 and 12."
        exit 1
    fi

    if [ "$day" == "" ]; then
        return 0
    fi
    if isLeapYear $year; then
        logDebug "The year $year is a leap year. February has 29 days."
        DAYS_OF_MONTH[2]=29
    fi
    if ! validateNumber "$day" || [ "$day" -lt 1 ] || [ "$day" -gt ${DAYS_OF_MONTH[$month]} ]; then
        logError "Day must be a number between 1 and ${DAYS_OF_MONTH[$month]} for the month $month."
        exit 1
    fi
}

parseArguments() {
    local args=("$@")
    if [ "${#args[@]}" -eq 0 ]; then
        printUsage
        exit 1
    fi
    local i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        local arg="${args[$i]}"
        if [ "$arg" == '--debug' ]; then
            export DEBUG=true
            logDebug "Enabling debug."
            ((i++))
        elif [ "$arg" == '--year' ]; then
            if [ "$(( ${#args[@]} - i ))" -lt 2 ]; then
                printUsage
                exit 1
            fi
            validateDate "${args[$((i+1))]}"
            AGGREGATE_YEAR="${args[$((i+1))]}"
            logDebug "Aggregating year $AGGREGATE_YEAR"
            ((i+=2))
        elif [ "$arg" == '--month' ]; then
            if [ "$(( ${#args[@]} - i ))" -lt 3 ]; then
                printUsage
                exit 1
            fi
            validateDate "${args[$((i+1))]}" "${args[$((i+2))]}"
            AGGREGATE_MONTH_YEAR="${args[$((i+1))]}"
            AGGREGATE_MONTH_MONTH="${args[$((i+2))]}"
            logDebug "Aggregating month ${AGGREGATE_MONTH_YEAR}-${AGGREGATE_MONTH_MONTH}"
            ((i+=3))
        elif [ "$arg" == '--day' ]; then
            if [ "$(( ${#args[@]} - i ))" -lt 4 ]; then
                printUsage
                exit 1
            fi
            validateDate "${args[$((i+1))]}" "${args[$((i+2))]}" "${args[$((i+3))]}"
            AGGREGATE_DAY_YEAR="${args[$((i+1))]}"
            AGGREGATE_DAY_MONTH="${args[$((i+2))]}"
            AGGREGATE_DAY_DAY="${args[$((i+3))]}"
            logDebug "Aggregating day ${AGGREGATE_DAY_YEAR}-${AGGREGATE_DAY_MONTH}-${AGGREGATE_DAY_DAY}"
            ((i+=4))
        elif [ "$arg" == '--from' ]; then
            if [ "$(( ${#args[@]} - i ))" -lt 4 ]; then
                printUsage
                exit 1
            fi
            validateDate "${args[$((i+1))]}" "${args[$((i+2))]}" "${args[$((i+3))]}"
            AGGREGATE_FROM_YEAR="${args[$((i+1))]}"
            AGGREGATE_FROM_MONTH="${args[$((i+2))]}"
            AGGREGATE_FROM_DAY="${args[$((i+3))]}"
            AGGREGATE_TO_YEAR=$(date +%Y)
            AGGREGATE_TO_MONTH=$(date +%-m)
            AGGREGATE_TO_DAY=$(date +%-d)
            ((i+=4))
            if [ "${args[$i]}" == '--to' ]; then
                if [ "$(( ${#args[@]} - i ))" -lt 4 ]; then
                    printUsage
                    exit 1
                fi
                validateDate "${args[$((i+1))]}" "${args[$((i+2))]}" "${args[$((i+3))]}"
                AGGREGATE_TO_YEAR="${args[$((i+1))]}"
                AGGREGATE_TO_MONTH="${args[$((i+2))]}"
                AGGREGATE_TO_DAY="${args[$((i+3))]}"
                ((i+=4))
            fi
            logDebug "Aggregating from day ${AGGREGATE_FROM_YEAR}-${AGGREGATE_FROM_MONTH}-${AGGREGATE_FROM_DAY} to ${AGGREGATE_TO_YEAR}-${AGGREGATE_TO_MONTH}-${AGGREGATE_TO_DAY}"
        elif [ "$arg" == '--yesterday' ]; then
            AGGREGATE_YESTERDAY=true
            logDebug "Aggregating yesterday"
            ((i++))
        elif [ "$arg" == '--today' ]; then
            AGGREGATE_TODAY=true
            logDebug "Aggregating today"
            ((i++))
        elif [ "$arg" == '--delete-aggregations' ]; then
            DELETE_AGGREGATIONS=true
            logDebug "Deleting aggregations."
            ((i++))
        elif [ "$arg" == '--detect' ]; then
            DETECT_VALUES=true
            logDebug "Detecting loadpoints and vehicles."
            ((i++))
        else
            printUsage
            exit 1
        fi
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
    logDebug "Deleting metric $metric"
    curl -s -X POST "http://${VM_HOST}:${VM_PORT}/api/v1/admin/tsdb/delete_series" -d "match[]=${metric}"
}


deleteAggregations() {
    logWarning "You are about to delete all aggregated metrics. You will lose all historical metrics for the times, where realtime data is no longer available."
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
    else
        logInfo "Deletion of aggregated metrics aborted."
    fi
}

detectValues() {
    # We are reading from vehicleOdometer as it typically contains entries for all vehicles and loadpoints, however has
    # the least amount of records for a speedy query result.

    # Detecting vehicles
    local index=0
    local vehicle_list
    vehicle_list=$(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -execute "show tag values from vehicleOdometer with key=vehicle" | grep "^vehicle " | sed 's/^vehicle //' | sort)
    while read vehicle; do
        if [ "$vehicle" != "" ]; then
            VEHICLES[${index}]=$vehicle
            index=$((index+1))
            logInfo "Detected vehicle $index: $vehicle"
        fi
    done <<< "$vehicle_list"
    logDebug "Detected ${#VEHICLES[*]} vehicles: ${VEHICLES[*]}"

    # Detecting loadpoints
    index=0
    local loadpoint_list
    loadpoint_list=$(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -execute "show tag values from vehicleOdometer with key=loadpoint" | grep "^loadpoint " | sed 's/^loadpoint //' | sort)
    while read loadpoint; do
        if [ "$loadpoint" != "" ]; then
            LOADPOINTS[${index}]=$loadpoint
            index=$((index+1))
            logInfo "Detected loadpoint $index: $loadpoint"
        fi
    done <<< "$loadpoint_list"

    # Detecting ext devices
    index=0
    local ext_device_list
    ext_device_list=$(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -execute "show tag values from extPower with key=title" | grep "^title " | sed 's/^title //' | sort)
    while read ext_device; do
        if [ "$ext_device" != "" ]; then
            EXT_DEVICES[${index}]=$ext_device
            index=$((index+1))
            logInfo "Detected ext device $index: $ext_device"
        fi
    done <<< "$ext_device_list"

    # Detecting aux devices
    index=0
    local aux_device_list
    aux_device_list=$(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -execute "show tag values from auxPower with key=title" | grep "^title " | sed 's/^title //' | sort)
    while read aux_device; do
        if [ "$aux_device" != "" ]; then
            AUX_DEVICES[${index}]=$aux_device
            index=$((index+1))
            logInfo "Detected aux device $index: $aux_device"
        fi
    done <<< "$aux_device_list"

    logDebug "Detected: vehicles ${#VEHICLES[*]} loadpoints: ${LOADPOINTS[*]} ext devices: ${EXT_DEVICES[*]} aux devices: ${AUX_DEVICES[*]}"
}

checkDependencies() {

    # Checking if required commands are available
    local missing=0
    for dep in curl jq vmctl; do
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

    logInfo "Creating aggregated metric $metric"

    curl -s "http://${VM_HOST}:${VM_PORT}/api/v1/query_range" \
        -d "query=${encoded_query}" \
        -d "start=${starttime}" \
        -d "end=${endtime}" \
        -d "step=1d" | jq -r '
            .data.result[0].values[]
            | [
                (.[0] | tonumber),
                (.[1] | tonumber),
                (.[0] | strftime("%Y") | tonumber),
                (.[0] | strftime("%m") | tonumber),
                (.[0] | strftime("%d") | tonumber)
            ]
            | @csv
        ' | while IFS=',' read -r timestamp value year month day; do
            # Compose line protocol: metric{year="YYYY",month="MM",day="DD"} value=VAL TIMESTAMP
            line="${metric}{year=\"${year}\",month=\"${month}\",day=\"${day}\"} ${value} ${timestamp}"
            echo "$line" | curl -s --data-binary @- "http://${VM_HOST}:${VM_PORT}/api/v1/import/prometheus" > /dev/null
        done
}

aggregate() {
    local starttime="$1"
    local endtime="$2"

    aggregateQuery 'sum(integrate(((pvPower_value{id=""}) default 0) [1d:1m] offset -1d)/3600)' "pvEnergyDaily" "$starttime" "$endtime"
    aggregateQuery 'sum(integrate(((homePower_value) default 0) [1d:1m] offset -1d)/-3600)' "homeEnergyDaily" "$starttime" "$endtime"
    aggregateQuery 'integrate(((gridPower_value > 0) default 0) [1d:1m] offset -1d) / 3600' "gridEnergyImportDaily" "$starttime" "$endtime"
    aggregateQuery 'integrate(((gridPower_value < 0) default 0) [1d:1m] offset -1d) / 3600' "gridEnergyExportDaily" "$starttime" "$endtime"
}

###############################################################################
### MAIN
###############################################################################

start_time=$(date +%s)

checkDependencies

# Check if timezone is set
if [ "$TIMEZONE" == "" ]; then
    logError "Timezone is not set. Please set the script variable TIMEZONE to your timezone."
    exit 1
fi

parseArguments $@

# Start aggregation
# if [ "$DELETE_AGGREGATIONS" != "true" ]; then
#     detectValues
#     if [ "$DETECT_VALUES" != "true" ]; then
#         logInfo "[`date '+%F %T'`] Starting aggregation..."
#     fi
# fi

if [ "$AGGREGATE_YEAR" -ne 0 ]; then
    starttime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_YEAR-01-01 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_YEAR-12-31 23:59:59" +%s)
    aggregate "$starttime" "$endtime"
elif [ "$AGGREGATE_MONTH_YEAR" -ne 0 ]; then
    starttime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_MONTH_YEAR-$(printf "%02d" $AGGREGATE_MONTH_MONTH)-01 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_MONTH_YEAR-$(printf "%02d" $AGGREGATE_MONTH_MONTH)-01 +1 month -1 day 23:59:59" +%s)
    aggregate "$starttime" "$endtime"
elif [ "$AGGREGATE_DAY_YEAR" -ne 0 ]; then
    starttime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_DAY_YEAR-$(printf "%02d" $AGGREGATE_DAY_MONTH)-01 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_DAY_YEAR-$(printf "%02d" $AGGREGATE_DAY_MONTH)-${AGGREGATE_DAY_DAY} 23:59:59" +%s)
    aggregate "$starttime" "$endtime"
elif [ "$AGGREGATE_FROM_YEAR" -ne 0 ]; then
    starttime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_FROM_YEAR-$(printf "%02d" $AGGREGATE_FROM_MONTH)-$(printf "%02d" $AGGREGATE_FROM_DAY) 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "$AGGREGATE_TO_YEAR-$(printf "%02d" $AGGREGATE_TO_MONTH)-$(printf "%02d" $AGGREGATE_TO_DAY) 23:59:59" +%s)
    aggregate "$starttime" "$endtime"
elif [ "$AGGREGATE_YESTERDAY" == "true" ]; then
    starttime=$(TZ="$TIMEZONE" date -d "yesterday 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "yesterday 23:59:59" +%s)
    aggregate "$starttime" "$endtime"
elif [ "$AGGREGATE_TODAY" == "true" ]; then
    starttime=$(TZ="$TIMEZONE" date -d "today 00:00:00" +%s)
    endtime=$(TZ="$TIMEZONE" date -d "today 23:59:59" +%s)
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