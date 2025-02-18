#!/bin/bash

# Aggregation script for EVCC grafana dashboards. See https://github.com/ha-puzzles/evcc-grafana-dashboards

logError() {
    echo "[ERROR]   $1"
}

logWarning() {
    echo "[WARNING] $1"
}

logInfo() {
    echo "[INFO]    $1"
}

logDebug() {
    if [ "$DEBUG" == "true" ]; then
        echo "[DEBUG]   $1"
    fi
}

# Source configuration from evcc-influx-aggregate.conf, which needs to be located in the same directory as this script.
if [ -f "$(dirname $0)/evcc-influx-aggregate.conf" ]; then
    . "$(dirname $0)/evcc-influx-aggregate.conf"
else
    logError "Configuration file $(dirname $0)/evcc-influx-aggregate.conf not found."
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
DELETE_AGGREGATIONS=false
DETECT_VALUES=false

# Maps of number of days per month. February leap year is updated later
declare -A DAYS_OF_MONTH
DAYS_OF_MONTH[1]=31
DAYS_OF_MONTH[2]=28
DAYS_OF_MONTH[3]=31
DAYS_OF_MONTH[4]=30
DAYS_OF_MONTH[5]=31
DAYS_OF_MONTH[6]=30
DAYS_OF_MONTH[7]=31
DAYS_OF_MONTH[8]=31
DAYS_OF_MONTH[9]=30
DAYS_OF_MONTH[10]=31
DAYS_OF_MONTH[11]=30
DAYS_OF_MONTH[12]=31

# Array of vehicles
declare -A VEHICLES

#Array of loadpoints
declare -A LOADPOINTS

parseArguments() {
    if [ "$#" -eq 0 ]; then
        printUsage
        exit 1
    fi
    if [ "$1" == '--year' ]; then
        if [ "$#" -ne 2 ]; then
            printUsage
            exit 1
        fi
        AGGREGATE_YEAR=$2
        logDebug "Aggregating year $AGGREGATE_YEAR"
        return 0
    fi
    if [ "$1" == '--month' ]; then
        if [ "$#" -ne 3 ]; then
            printUsage
            exit 1
        fi
        AGGREGATE_MONTH_YEAR=$2
        AGGREGATE_MONTH_MONTH=$3
        logDebug "Aggregating month ${AGGREGATE_MONTH_YEAR}-${AGGREGATE_MONTH_MONTH}"
        return 0
    fi
    if [ "$1" == '--day' ]; then
        if [ "$#" -ne 4 ]; then
            printUsage
            exit 1
        fi
        AGGREGATE_DAY_YEAR=$2
        AGGREGATE_DAY_MONTH=$3
        AGGREGATE_DAY_DAY=$4
        logDebug "Aggregating day ${AGGREGATE_DAY_YEAR}-${AGGREGATE_DAY_MONTH}-${AGGREGATE_DAY_DAY}"
        return 0
    fi
    if [ "$1" == '--yesterday' ]; then
        AGGREGATE_YESTERDAY=true
        logDebug "Aggregating yesterday"
        return 0
    fi
    if [ "$1" == '--today' ]; then
        AGGREGATE_TODAY=true
        logDebug "Aggregating today"
        return 0
    fi
    if [ "$1" == '--delete-aggregations' ]; then
        DELETE_AGGREGATIONS=true
        logDebug "Deleting aggregations."
        return 0
    fi
    if [ "$1" == '--detect' ]; then
        DETECT_VALUES=true
        logDebug "Detecting loadpoints and vehicles."
        return 0
    fi
    printUsage
    exit 1
}

printUsage() {
    echo "`basename $0` [--year <year> | --month <year> <month> | --day <year> <month> <day> | --today | --yesterday | --delete-aggregations | --detect]"
}

isLeapYear() {
    year=$1

    # Must be dividable by 4
    if [ $(($year % 4 )) -ne 0 ]; then
        return 1
    fi
    #Must not be dividable by 100
    if [ $(($year % 100 )) -eq 0 ]; then
        #Must be dividable by 400
        if [ $(($year % 400 )) -ne 0 ]; then
            return 1
        fi
    fi
    #It is a leap year
    return 0
}

writeDailyAggregations() {
    mode=$1 # integral-all | integral-positives | integral-negatives | max | min | mean
    field=$2
    sourceMeasurement=$3
    targetMeasurement=$4
    year=$5
    month=$6
    day=$7
    additionalWhere=$8
    defaultZero=$9
    additionalTags=${10}

    printf -v fYear "%04d" $year
    printf -v fMonth "%02d" $month
    printf -v fDay "%02d" $day

    # Convert time to UTC for local timezone
    fromTime=$(date -d "`date -d ${fYear}-${fMonth}-${fDay}T00:00:00 +%FT%T%Z`" -u +%FT%TZ)
    toTime=$(date -d "`date -d ${fYear}-${fMonth}-${fDay}T23:59:59 +%FT%T%Z`" -u +%FT%TZ)
    timeCondition="time >= '${fromTime}' AND time <= '${toTime}'"

    query=""
    case $mode in
        integral-all)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of all values from $sourceMeasurement into ${targetMeasurement}"
            query="SELECT integral(\"$field\") / 3600 FROM \"$sourceMeasurement\" WHERE ${timeCondition} $additionalWhere GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
            ;;
        integral-positives)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of positive values from $sourceMeasurement into ${targetMeasurement}"
            query="SELECT integral(\"subquery\") / 3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$sourceMeasurement\" WHERE ${timeCondition} $additionalWhere AND \"$field\" >=0 GROUP BY time(10s) fill(0)) WHERE ${timeCondition} GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
            ;;
        integral-negatives)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of negative values from $sourceMeasurement into ${targetMeasurement}"
            query="SELECT integral(\"subquery\") / -3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$sourceMeasurement\" WHERE ${timeCondition} $additionalWhere AND \"$field\" <=0 GROUP BY time(10s) fill(0)) WHERE ${timeCondition} GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
            ;;
        min)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating minimums from $sourceMeasurement into ${targetMeasurement}"
            query="SELECT min(\"$field\") FROM \"$sourceMeasurement\" WHERE ${timeCondition} $additionalWhere GROUP BY time(1d) fill(none) tz('$TIMEZONE')"
            ;;
        max)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating maximums from $sourceMeasurement into ${targetMeasurement}"
            query="SELECT max(\"$field\") FROM \"$sourceMeasurement\" WHERE ${timeCondition} $additionalWhere GROUP BY time(1d) fill(none) tz('$TIMEZONE')"
            ;;
        mean)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating averages from $sourceMeasurement into ${targetMeasurement}"
            query="SELECT mean(\"$field\") FROM \"$sourceMeasurement\" WHERE ${timeCondition} $additionalWhere GROUP BY time(1d) fill(none) tz('$TIMEZONE')"
            ;;
        *)
            logError "Unknown query mode: '$mode'."
            exit 1
            ;;
    esac
    logDebug "Query: $query"

    queryResult=`influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1`
    logDebug "Query result (last row): $queryResult"
    timestamp=$(date -d "`date -d ${fYear}-${fMonth}-${fDay}T00:00:00 +%FT%T%Z`" -u +%s%9N)
    energy=0
    if [ `echo $queryResult | wc -w ` -eq 2 ]; then
        energy=`echo "$queryResult" | cut -d " " -f 2`
    else
        logInfo "There is no data from $sourceMeasurement for $targetMeasurement."
    fi
    if [ "$energy" != "0" ] || [ "$defaultZero" == "true" ]; then
        if [ "$additionalTags" != "" ]; then
            insertStatement="INSERT ${targetMeasurement},year=${fYear},month=${fMonth},day=${fDay},${additionalTags} value=${energy} ${timestamp}"
        else
            insertStatement="INSERT ${targetMeasurement},year=${fYear},month=${fMonth},day=${fDay} value=${energy} ${timestamp}"
        fi
        logDebug "Insert statement: $insertStatement"
        influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -execute "$insertStatement"
    fi
}

aggregateDay() {
    ayear=$1
    amonth=$2
    aday=$3

    logInfo "Aggregating daily metrics for `printf "%04d" $ayear`-`printf "%02d" $amonth`-`printf "%02d" $aday`"

    writeDailyAggregations "integral-all" "value" "pvPower" "pvDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"
    writeDailyAggregations "integral-all" "value" "homePower" "homeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"
    writeDailyAggregations "integral-positives" "value" "gridPower" "gridDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"
    writeDailyAggregations "integral-negatives" "value" "gridPower" "feedInDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"

    # writeDailyAggregations "integral-all" "value" "chargePower" "loadpoint1DailyEnergy" $ayear $amonth $aday "AND ("loadpoint"::tag = '${LOADPOINT_1_TITLE}') AND value < $PEAK_POWER_LIMIT" "true"
    # if [ "$LOADPOINT_2_ENABLED" == "true" ]; then
    #     writeDailyAggregations "integral-all" "value" "chargePower" "loadpoint2DailyEnergy" $ayear $amonth $aday "AND ("loadpoint"::tag = '${LOADPOINT_2_TITLE}') AND value < $PEAK_POWER_LIMIT" "true"
    # else
    #     logDebug "Loadpoint 2 is disabled."
    # fi

    # writeDailyAggregations "max" "value" "vehicleOdometer" "vehicle1Odometer" $ayear $amonth $aday "AND ("vehicle"::tag = '${VEHICLE_1_TITLE}')" "false"
    # writeDailyAggregations "integral-positives" "value" "chargePower" "vehicle1DailyEnergy" $ayear $amonth $aday "AND ("vehicle"::tag = '${VEHICLE_1_TITLE}') AND value < $PEAK_POWER_LIMIT" "true" # Workaround: Integral does not work for vehicle as there are too few data points
    # if [ "$VEHICLE_2_ENABLED" == "true" ]; then
    #     writeDailyAggregations "max" "value" "vehicleOdometer" "vehicle2Odometer" $ayear $amonth $aday "AND ("vehicle"::tag = '${VEHICLE_2_TITLE}')" "false"
    #     writeDailyAggregations "integral-positives" "value" "chargePower" "vehicle2DailyEnergy" $ayear $amonth $aday "AND ("vehicle"::tag = '${VEHICLE_2_TITLE}') AND value < $PEAK_POWER_LIMIT" "true" # Workaround: Integral does not work for vehicle as there are too few data points
    # else
    #     logDebug "Vehicle 2 is disabled."
    # fi

    if [ "$HOME_BATTERY" == "true" ]; then
        writeDailyAggregations "integral-positives" "value" "batteryPower" "dischargeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"
        writeDailyAggregations "integral-negatives" "value" "batteryPower" "chargeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"
        writeDailyAggregations "min" "value" "batterySoc" "batteryMinSoc" $ayear $amonth $aday "AND value < 101 AND value > 0" "false"
        writeDailyAggregations "max" "value" "batterySoc" "batteryMaxSoc" $ayear $amonth $aday "AND value < 101" "false"
    else
        logDebug "Home battery aggregation is disabled."
    fi

    if [ "$DYNAMIC_TARIFF" == "true" ]; then
        writeDailyAggregations "min" "value" "tariffGrid" "tariffGridDailyMin" $ayear $amonth $aday "" "false"
        writeDailyAggregations "max" "value" "tariffGrid" "tariffGridDailyMax" $ayear $amonth $aday "" "false"
        writeDailyAggregations "mean" "value" "tariffGrid" "tariffGridDailyMean" $ayear $amonth $aday "" "false"
    else
        logDebug "Dynamic tariff aggregation is disabled."
    fi

    for vehicle in "${VEHICLES[@]}"; do
        logDebug "Aggregating vehicle $vehicle"
        escapedVehicle=$(echo $vehicle | sed 's/ /\\ /g')
        writeDailyAggregations "max" "value" "vehicleOdometer" "vehicleOdometerDailyMax" $ayear $amonth $aday "AND \"vehicle\"::tag = '${vehicle}'" "false" "vehicle=${escapedVehicle}"
        writeDailyAggregations "integral-positives" "value" "chargePower" "vehicleDailyEnergy" $ayear $amonth $aday "AND \"vehicle\"::tag = '${vehicle}' AND value < $PEAK_POWER_LIMIT" "true" "vehicle=${escapedVehicle}"
    done

    for loadpoint in "${LOADPOINTS[@]}"; do
        logDebug "Aggregating loadpoint $loadpoint"
        escapedLoadpoint=$(echo $loadpoint | sed 's/ /\\ /g')
        writeDailyAggregations "integral-all" "value" "chargePower" "loadpointDailyEnergy" $ayear $amonth $aday "AND \"loadpoint\"::tag = '${loadpoint}' AND value < $PEAK_POWER_LIMIT" "true" "loadpoint=${escapedLoadpoint}"
    done
}

writeMonthlyAggregations () {
    aggregation=$1
    field=$2
    dailytargetMeasurement=$3
    monthlytargetMeasurement=$4
    year=$5
    month=$6
    additionalWhere=$7
    additionalTags=$8

    numDays=${DAYS_OF_MONTH[$month]}

    printf -v fYear "%04d" $year
    printf -v fMonth "%02d" $month
    printf -v fDays "%02d" $numDays

    # Convert time to UTC for local timezone
    fromTime=$(date -d "`date -d ${fYear}-${fMonth}-01T00:00:00 +%FT%T%Z`" -u +%FT%TZ)
    toTime=$(date -d "`date -d ${fYear}-${fMonth}-${fDays}T23:59:59 +%FT%T%Z`" -u +%FT%TZ)
    timeCondition="time >= '${fromTime}' AND time <= '${toTime}'"

    logDebug "${fYear}-${fMonth}: Creating monthly aggregation from $dailytargetMeasurement into ${monthlytargetMeasurement}"
    logDebug "Month has $numDays days."
    if [ "$additionalWhere" != "" ]; then
        query="SELECT $aggregation(\"$field\") FROM $dailytargetMeasurement WHERE ${timeCondition} ${additionalWhere} tz('$TIMEZONE')"
    else
        query="SELECT $aggregation(\"$field\") FROM $dailytargetMeasurement WHERE ${timeCondition} tz('$TIMEZONE')"
    fi
    logDebug "Query: $query"

    queryResult=`influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1`
    logDebug "Query result (last row): $queryResult"
    timestamp=$(date -d "`date -d ${fYear}-${fMonth}-01T00:00:00 +%FT%T%Z`" -u +%s%9N)
    energy=0
    if [ `echo $queryResult | wc -w ` -eq 2 ]; then
        energy=`echo "$queryResult" | cut -d " " -f 2`
    else
        logInfo "There is no data from $dailytargetMeasurement for $monthlytargetMeasurement. Writing 0 as data point for this month."
    fi
    if [ "$additionalTags" != "" ]; then
        insertStatement="INSERT ${monthlytargetMeasurement},year=${fYear},month=${fMonth},${additionalTags} value=${energy} ${timestamp}"
    else
        insertStatement="INSERT ${monthlytargetMeasurement},year=${fYear},month=${fMonth} value=${energy} ${timestamp}"
    fi
    logDebug "Insert statement: $insertStatement"
    influx  -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -execute "$insertStatement"
}

aggregateMonth() {
    ayear=$1
    amonth=$2

    logInfo "`printf "Aggregating monthly metrics for %04d" $ayear`-`printf "%02d" $amonth`"

    writeMonthlyAggregations "sum" "value" "pvDailyEnergy" "pvMonthlyEnergy" $ayear $amonth
    writeMonthlyAggregations "sum" "value" "homeDailyEnergy" "homeMonthlyEnergy" $ayear $amonth
    writeMonthlyAggregations "sum" "value" "gridDailyEnergy" "gridMonthlyEnergy" $ayear $amonth
    writeMonthlyAggregations "sum" "value" "feedInDailyEnergy" "feedInMonthlyEnergy" $ayear $amonth

    # writeMonthlyAggregations "sum" "value" "loadpoint1DailyEnergy" "loadpoint1MonthlyEnergy" $ayear $amonth 
    # if [ "$LOADPOINT_2_ENABLED" == "true" ]; then
    #     writeMonthlyAggregations "sum" "value" "loadpoint2DailyEnergy" "loadpoint2MonthlyEnergy" $ayear $amonth
    # else
    #     logDebug "Loadpoint 2 is disabled."
    # fi
    
    # writeMonthlyAggregations "spread" "value" "vehicle1Odometer" "vehicle1DrivenKm" $ayear $amonth 
    # writeMonthlyAggregations "sum" "value" "vehicle1DailyEnergy" "vehicle1MonthlyEnergy" $ayear $amonth 
    # if [ "$VEHICLE_2_ENABLED" == "true" ]; then
    #     writeMonthlyAggregations "spread" "value" "vehicle2Odometer" "vehicle2DrivenKm" $ayear $amonth 
    #     writeMonthlyAggregations "sum" "value" "vehicle2DailyEnergy" "vehicle2MonthlyEnergy" $ayear $amonth 
    # else
    #     logDebug "Vehicle 2 is disabled."
    # fi

    if [ "$HOME_BATTERY" == "true" ]; then
        writeMonthlyAggregations "sum" "value" "dischargeDailyEnergy" "dischargeMonthlyEnergy" $ayear $amonth
        writeMonthlyAggregations "sum" "value" "chargeDailyEnergy" "chargeMonthlyEnergy" $ayear $amonth
    else
        logDebug "Home battery aggregation is disabled"
    fi

    for vehicle in "${VEHICLES[@]}"; do
        logDebug "Aggregating vehicle $vehicle"
        escapedVehicle=$(echo $vehicle | sed 's/ /\\ /g')
        writeMonthlyAggregations "spread" "value" "vehicleOdometerDailyMax" "vehicleMonthlyDrivenKm" $ayear $amonth "AND \"vehicle\"::tag = '${vehicle}'" "vehicle=${escapedVehicle}"
        writeMonthlyAggregations "sum" "value" "vehicleDailyEnergy" "vehicleMonthlyEnergy" $ayear $amonth "AND \"vehicle\"::tag = '${vehicle}'" "vehicle=${escapedVehicle}"
    done

    for loadpoint in "${LOADPOINTS[@]}"; do
        logDebug "Aggregating loadpoint $loadpoint"
        escapedLoadpoint=$(echo $loadpoint | sed 's/ /\\ /g')
        writeMonthlyAggregations "sum" "value" "loadpointDailyEnergy" "loadpointMonthlyEnergy" $ayear $amonth "AND \"loadpoint\"::tag = '${loadpoint}'" "loadpoint=${escapedLoadpoint}"
    done
}

dropMeasurement() {
    measurement=$1
    logInfo "Deleting measurement $measurement"
    dropStatement="DROP MEASUREMENT ${measurement}"
    influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -execute "$dropStatement"
}

dropAggregations() {
    logWarning "You are about to delete all aggregated measurements. You will lose all historical measurements for the times, where realtime data is no longer available."
    logWarning "Are you sure you want to delete all aggregated data? Type 'YES' to continue."
    read confirmation
    if [ "$confirmation" == "YES" ]; then
        logInfo "Deleting all aggregated measurements in 3 seconds."
        sleep 1
        logInfo "Deleting all aggregated measurements in 2 seconds."
        sleep 1
        logInfo "Deleting all aggregated measurements in 1 seconds."
        sleep 1
        dropMeasurement "pvDailyEnergy"
        dropMeasurement "homeDailyEnergy"
        dropMeasurement "gridDailyEnergy"
        dropMeasurement "feedInDailyEnergy"
        dropMeasurement "dischargeDailyEnergy"
        dropMeasurement "chargeDailyEnergy"
        dropMeasurement "pvMonthlyEnergy"
        dropMeasurement "homeMonthlyEnergy"
        dropMeasurement "gridMonthlyEnergy"
        dropMeasurement "feedInMonthlyEnergy"
        dropMeasurement "dischargeMonthlyEnergy"
        dropMeasurement "chargeMonthlyEnergy"
        dropMeasurement "batteryMaxSoc"
        dropMeasurement "batteryMinSoc"
        dropMeasurement "tariffGridDailyMax"
        dropMeasurement "tariffGridDailyMean"
        dropMeasurement "tariffGridDailyMin"
        dropMeasurement "vehicleDailyEnergy"
        dropMeasurement "vehicleMonthlyEnergy"
        dropMeasurement "vehicleOdometerDailyMax"
        dropMeasurement "vehicleMonthlyDrivenKm"
        dropMeasurement "loadpointDailyEnergy"
        dropMeasurement "loadpointMonthlyEnergy"

        # Legacy measurements
        dropMeasurement "loadpoint1DailyEnergy"
        dropMeasurement "loadpoint2DailyEnergy"
        dropMeasurement "loadpoint1MonthlyEnergy"
        dropMeasurement "loadpoint2MonthlyEnergy"
        dropMeasurement "vehicle1DailyEnergy"
        dropMeasurement "vehicle1DrivenKm"
        dropMeasurement "vehicle1MonthlyEnergy"
        dropMeasurement "vehicle1Odometer"
        dropMeasurement "vehicle2DailyEnergy"
        dropMeasurement "vehicle2DrivenKm"
        dropMeasurement "vehicle2MonthlyEnergy"
        dropMeasurement "vehicle2Odometer"
    else
        logInfo "Deletion of aggregated measurements aborted."
    fi
}

detectValues() {
    # We are reading from vehicleOdometer as it typically contains entries for all vehicles and loadpoints, however has
    # the least amount of records for a speedy query result.

    # Detecting vehicles
    index=0
    vehicle_list=$(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -execute "select min(value) from vehicleOdometer group by vehicle" | grep "tags: vehicle=" | sed "s/tags: vehicle=//" | grep -v "(offline)" | grep -v "^$" | sort)
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
    loadpoint_list=$(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -execute "select min(value) from vehicleOdometer group by loadpoint" | grep "tags: loadpoint=" | sed "s/tags: loadpoint=//" | grep -v "^$" | sort)
    while read loadpoint; do
        if [ "$loadpoint" != "" ]; then
            LOADPOINTS[${index}]=$loadpoint
            index=$((index+1))
            logInfo "Detected loadpoint $index: $loadpoint"
        fi
    done <<< "$loadpoint_list"
    logDebug "Detected ${#LOADPOINTS[*]} vehicles: ${LOADPOINTS[*]}"
}

###############################################################################
### MAIN
###############################################################################
parseArguments $@

# Check if timezone is set
if [ "$TIMEZONE" == "" ]; then
    logError "Timezone is not set. Please set the script variable TIMEZONE to your timezone."
    exit 1
fi

# Start aggregation
if [ "$DELETE_AGGREGATIONS" != "true" ]; then
    detectValues
    if [ "$DETECT_VALUES" != "true" ]; then
        logInfo "[`date '+%F %T'`] Starting aggregation..."
    fi
fi

if [ "$AGGREGATE_YEAR" -ne 0 ]; then
    if isLeapYear $AGGREGATE_YEAR; then
        logDebug "The year $AGGREGATE_YEAR is a leap year. February has 29 days."
        DAYS_OF_MONTH[2]=29
    fi
    for month in {1..12}; do
        for (( day=1; day<=${DAYS_OF_MONTH[$month]}; day++ )); do
            aggregateDay $AGGREGATE_YEAR $month $day
        done
        aggregateMonth $AGGREGATE_YEAR $month
    done
elif [ "$AGGREGATE_MONTH_YEAR" -ne 0 ]; then
    if isLeapYear $AGGREGATE_MONTH_YEAR; then
        logDebug "The year $AGGREGATE_MONTH_YEAR is a leap year. February has 29 days."
        DAYS_OF_MONTH[2]=29
    fi
    for (( day=1; day<=${DAYS_OF_MONTH[$AGGREGATE_MONTH_MONTH]}; day++ )); do
        aggregateDay $AGGREGATE_MONTH_YEAR $AGGREGATE_MONTH_MONTH $day
    done
    aggregateMonth $AGGREGATE_MONTH_YEAR $AGGREGATE_MONTH_MONTH
elif [ "$AGGREGATE_DAY_YEAR" -ne 0 ]; then
    if isLeapYear $AGGREGATE_DAY_YEAR; then
        logDebug "The year $AGGREGATE_DAY_YEAR is a leap year. February has 29 days."
        DAYS_OF_MONTH[2]=29
    fi
    aggregateDay $AGGREGATE_DAY_YEAR $AGGREGATE_DAY_MONTH $AGGREGATE_DAY_DAY
    aggregateMonth $AGGREGATE_DAY_YEAR $AGGREGATE_DAY_MONTH
elif [ "$AGGREGATE_YESTERDAY" == "true" ]; then
    year=`date -d yesterday +%Y`
    # Converting to a base 10 number, stripping of a leading 0
    month=$(( 10#`date -d yesterday +%m`))
    day=$(( 10#`date -d yesterday +%d`))
    if isLeapYear $year; then
        logDebug "The year $year is a leap year. February has 29 days."
        DAYS_OF_MONTH[2]=29
    fi
    aggregateDay $year $month $day
    aggregateMonth $year $month
elif [ "$AGGREGATE_TODAY" == "true" ]; then
    year=`date +%Y`
    # Converting to a base 10 number, stripping of a leading 0
    month=$(( 10#`date +%m`))
    day=$(( 10#`date +%d`))
    if isLeapYear $year; then
        logDebug "The year $year is a leap year. February has 29 days."
        DAYS_OF_MONTH[2]=29
    fi
    aggregateDay $year $month $day
    aggregateMonth $year $month
elif [ "$DELETE_AGGREGATIONS" == "true" ]; then
    dropAggregations
fi

### END