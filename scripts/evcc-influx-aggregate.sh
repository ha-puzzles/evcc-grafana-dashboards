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
AGGREGATE_FROM_YEAR=0
AGGREGATE_FROM_MONTH=0
AGGREGATE_FROM_DAY=0
AGGREGATE_TO_YEAR=0
AGGREGATE_TO_MONTH=0
AGGREGATE_TO_DAY=0
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

validateNumber() {
    if ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
        return 1
    fi
    return 0
}

validateDate() {
    year=$1
    month=$2
    day=$3

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
    if [ "$#" -eq 0 ]; then
        printUsage
        exit 1
    fi
    while [ "$#" -gt 0 ]; do
        if [ "$1" == '--debug' ]; then
            export DEBUG=true
            shift 1
            logDebug "Enabling debug."
        elif [ "$1" == '--year' ]; then
            if [ "$#" -lt 2 ]; then
                printUsage
                exit 1
            fi
            validateDate $2
            AGGREGATE_YEAR=$2
            shift 2
            logDebug "Aggregating year $AGGREGATE_YEAR"
        elif [ "$1" == '--month' ]; then
            if [ "$#" -lt 3 ]; then
                printUsage
                exit 1
            fi
            validateDate $2 $3
            AGGREGATE_MONTH_YEAR=$2
            AGGREGATE_MONTH_MONTH=$3
            shift 3
            logDebug "Aggregating month ${AGGREGATE_MONTH_YEAR}-${AGGREGATE_MONTH_MONTH}"
        elif [ "$1" == '--day' ]; then
            if [ "$#" -lt 4 ]; then
                printUsage
                exit 1
            fi
            validateDate $2 $3 $4
            AGGREGATE_DAY_YEAR=$2
            AGGREGATE_DAY_MONTH=$3
            AGGREGATE_DAY_DAY=$4
            shift 4
            logDebug "Aggregating day ${AGGREGATE_DAY_YEAR}-${AGGREGATE_DAY_MONTH}-${AGGREGATE_DAY_DAY}"
        elif [ "$1" == '--from' ]; then
            if [ "$#" -lt 4 ]; then
                printUsage
                exit 1
            fi
            validateDate $2 $3 $4
            AGGREGATE_FROM_YEAR=$2
            AGGREGATE_FROM_MONTH=$3
            AGGREGATE_FROM_DAY=$4
            AGGREGATE_TO_YEAR=`date +%Y`
            AGGREGATE_TO_MONTH=`date +%-m`
            AGGREGATE_TO_DAY=`date +%-d`
            shift 4
            if [ "$1" == '--to' ]; then
                if [ "$#" -lt 4 ]; then
                    printUsage
                    exit 1
                fi
                validateDate $2 $3 $4
                AGGREGATE_TO_YEAR=$2
                AGGREGATE_TO_MONTH=$3
                AGGREGATE_TO_DAY=$4
                shift 4
            fi
            logDebug "Aggregating from day ${AGGREGATE_FROM_YEAR}-${AGGREGATE_FROM_MONTH}-${AGGREGATE_FROM_DAY} to ${AGGREGATE_TO_YEAR}-${AGGREGATE_TO_MONTH}-${AGGREGATE_TO_DAY}"
        elif [ "$1" == '--yesterday' ]; then
            AGGREGATE_YESTERDAY=true
            shift 1
            logDebug "Aggregating yesterday"
        elif [ "$1" == '--today' ]; then
            AGGREGATE_TODAY=true
            shift 1
            logDebug "Aggregating today"
        elif [ "$1" == '--delete-aggregations' ]; then
            DELETE_AGGREGATIONS=true
            shift 1
            logDebug "Deleting aggregations."
        elif [ "$1" == '--detect' ]; then
            DETECT_VALUES=true
            shift 1
            logDebug "Detecting loadpoints and vehicles."
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
            query="SELECT integral(\"subquery\") / 3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$sourceMeasurement\" WHERE ${timeCondition} $additionalWhere AND \"$field\" >=0 GROUP BY time(${ENERGY_SAMPLE_INTERVAL}) fill(0)) WHERE ${timeCondition} GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
            ;;
        integral-negatives)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of negative values from $sourceMeasurement into ${targetMeasurement}"
            query="SELECT integral(\"subquery\") / -3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$sourceMeasurement\" WHERE ${timeCondition} $additionalWhere AND \"$field\" <=0 GROUP BY time(${ENERGY_SAMPLE_INTERVAL}) fill(0)) WHERE ${timeCondition} GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
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
        logDebug "There is no data from $sourceMeasurement for $targetMeasurement."
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

writeDailyPriceAggregation() {
    year=$1
    month=$2
    day=$3

    printf -v fYear "%04d" $year
    printf -v fMonth "%02d" $month
    printf -v fDay "%02d" $day

    # Convert time to UTC for local timezone
    fromTime=$(date -d "`date -d ${fYear}-${fMonth}-${fDay}T00:00:00 +%FT%T%Z`" -u +%FT%TZ)
    toTime=$(date -d "`date -d ${fYear}-${fMonth}-${fDay}T23:59:59 +%FT%T%Z`" -u +%FT%TZ)
    timeCondition="time >= '${fromTime}' AND time <= '${toTime}'"

    timestamp=$(date -d "`date -d ${fYear}-${fMonth}-${fDay}T00:00:00 +%FT%T%Z`" -u +%s%9N)

    ### Energy purchase price ###

    # Get grid prices
    # In case of fixed tariffs, prices are very infrequently updated. So we need to get the last available price as default.
    query="SELECT last("value") FROM "tariffGrid" WHERE time <= '${fromTime}'"
    lastGridPrice=`influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1 | awk '{print $2}'`
    logDebug "Last queried grid price: $lastGridPrice"
    
    query="SELECT last("value") FROM "tariffGrid" WHERE ${timeCondition} GROUP BY time(1h) TZ('$TIMEZONE')"
    logDebug "Query: $query"
    declare -a gridPrices
    row=0
    while read value; do
        if [ "$value" != "" ]; then
            gridPrices[$row]=$value
            export lastGridPrice=$value
        else 
            logDebug "Price for index $row is empty. Using last grid price $lastGridPrice. Please make sure that a 'grid' tariff is configured in EVCC: https://docs.evcc.io/docs/reference/configuration/tariffs"
            gridPrices[$row]=$lastGridPrice
        fi
        row=$((row+1))
    done < <(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -precision rfc3339 -execute "$query" | tail -n +4 | awk '{print $2}')
    logDebug "Grid prices: ${gridPrices[*]}"

    # Calculate total daily purchase price
    totalPrice=0
    query="SELECT integral(\"subquery\") / 3600000 FROM (SELECT mean(\"value\") AS \"subquery\" FROM \"gridPower\" WHERE ${timeCondition} AND \"value\" >=0 GROUP BY time(${ENERGY_SAMPLE_INTERVAL}) fill(0)) WHERE ${timeCondition} GROUP BY time(${TARIFF_PRICE_INTERVAL}) fill(0) tz('$TIMEZONE')"
    logDebug "Query: $query"
    row=0
    while read -r value; do
        if [ "$value" != "" ]; then
            if [ "${gridPrices[$i]}" == "" ]; then
                logDebug "Price for index $row is empty. Using last grid price $lastGridPrice."
                totalPrice=$(echo "$totalPrice + $value * $lastGridPrice" | bc)
            else
                totalPrice=$(echo "$totalPrice + $value * ${gridPrices[$i]}" | bc)
            fi
            row=$((row+1))
        fi
    done < <(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -precision rfc3339 -execute "$query" | tail -n +4 | awk '{print $2}')
    logDebug "Total daily energy purchase price: ${totalPrice}€"

    insertStatement="INSERT energyPurchasedDailyPrice,year=${fYear},month=${fMonth},day=${fDay} value=${totalPrice} ${timestamp}"
    logDebug "Insert statement: $insertStatement"
    influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -execute "$insertStatement"

    ### Energy sold price ###

    # Get feed in prices
     # In case of fixed tariffs, prices are very infrequently updated. So we need to get the last available price as default.
    query="SELECT last("value") FROM "tariffFeedIn" WHERE time <= '${fromTime}'"
    lastFeedInPrice=`influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1 | awk '{print $2}'`
    logDebug "Last queried feed in price: $lastFeedInPrice"

    query="SELECT last("value") FROM "tariffFeedIn" WHERE ${timeCondition} GROUP BY time(1h) TZ('$TIMEZONE')"
    logDebug "Query: $query"
    declare -a feedInPrices
    row=0
    while read value; do
        if [ "$value" != "" ]; then
            feedInPrices[$row]=$value
            lastFeedInPrice=$value
        else
            logDebug "Price for index $row is empty. Using last feed-in price $lastFeedInPrice. Please make sure that a 'feedin' tariff is configured in EVCC: https://docs.evcc.io/docs/reference/configuration/tariffs"
            feedInPrices[$row]=$lastFeedInPrice
        fi
        row=$((row+1))
    done < <(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -precision rfc3339 -execute "$query" | tail -n +4 | awk '{print $2}')
    logDebug "Feed in prices: ${feedInPrices[*]}"

    # Calculate total daily sold price
    totalPrice=0
    query="SELECT integral(\"subquery\") / -3600000 FROM (SELECT mean(\"value\") AS \"subquery\" FROM \"gridPower\" WHERE ${timeCondition} AND \"value\" <=0 GROUP BY time(${ENERGY_SAMPLE_INTERVAL}) fill(0)) WHERE ${timeCondition} GROUP BY time(${TARIFF_PRICE_INTERVAL}) fill(0) tz('$TIMEZONE')"
    logDebug "Query: $query"
    row=0
    while read -r value; do
        if [ "$value" != "" ]; then
            if [ "${feedInPrices[$i]}" == "" ]; then
                logDebug "Price for index $row is empty. Using last feed-in price $lastFeedInPrice."
                totalPrice=$(echo "$totalPrice + $value * $lastFeedInPrice" | bc)
            else
                totalPrice=$(echo "$totalPrice + $value * ${feedInPrices[$i]}" | bc)
            fi
            row=$((row+1))
        fi
    done < <(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -precision rfc3339 -execute "$query" | tail -n +4 | awk '{print $2}')
    logDebug "Total daily energy sold price: ${totalPrice}€"

    insertStatement="INSERT energySoldDailyPrice,year=${fYear},month=${fMonth},day=${fDay} value=${totalPrice} ${timestamp}"
    logDebug "Insert statement: $insertStatement"
    influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -execute "$insertStatement"
}

aggregateDay() {
    ayear=$1
    amonth=$2
    aday=$3

    # logInfo "Aggregating daily metrics for `printf "%04d" $ayear`-`printf "%02d" $amonth`-`printf "%02d" $aday`"

    # writeDailyAggregations "integral-positives" "value" "pvPower" "pvDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT AND ("id"::tag = '')" "true"
    # writeDailyAggregations "integral-positives" "value" "homePower" "homeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"
    # writeDailyAggregations "integral-positives" "value" "gridPower" "gridDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"
    # writeDailyAggregations "integral-negatives" "value" "gridPower" "feedInDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT" "true"

    # if [ "$HOME_BATTERY" == "true" ]; then
    #     writeDailyAggregations "integral-positives" "value" "batteryPower" "dischargeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT AND ("id"::tag = '')" "true"
    #     writeDailyAggregations "integral-negatives" "value" "batteryPower" "chargeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT AND ("id"::tag = '')" "true"
    #     writeDailyAggregations "min" "value" "batterySoc" "batteryMinSoc" $ayear $amonth $aday "AND value < 101 AND value > 0 AND ("id"::tag = '')" "false"
    #     writeDailyAggregations "max" "value" "batterySoc" "batteryMaxSoc" $ayear $amonth $aday "AND value < 101 AND ("id"::tag = '')" "false"
    # else
    #     logDebug "Home battery aggregation is disabled."
    # fi

    # if [ "$DYNAMIC_TARIFF" == "true" ]; then
    #     writeDailyAggregations "min" "value" "tariffGrid" "tariffGridDailyMin" $ayear $amonth $aday "" "false"
    #     writeDailyAggregations "max" "value" "tariffGrid" "tariffGridDailyMax" $ayear $amonth $aday "" "false"
    #     writeDailyAggregations "mean" "value" "tariffGrid" "tariffGridDailyMean" $ayear $amonth $aday "" "false"
    # else
    #     logDebug "Dynamic tariff aggregation is disabled."
    # fi

    # for vehicle in "${VEHICLES[@]}"; do
    #     logDebug "Aggregating vehicle $vehicle"
    #     escapedVehicle=$(echo $vehicle | sed 's/ /\\ /g')
    #     writeDailyAggregations "max" "value" "vehicleOdometer" "vehicleOdometerDailyMax" $ayear $amonth $aday "AND \"vehicle\"::tag = '${vehicle}'" "false" "vehicle=${escapedVehicle}"
    #     writeDailyAggregations "integral-positives" "value" "chargePower" "vehicleDailyEnergy" $ayear $amonth $aday "AND \"vehicle\"::tag = '${vehicle}' AND value < $PEAK_POWER_LIMIT" "true" "vehicle=${escapedVehicle}"
    # done

    # for loadpoint in "${LOADPOINTS[@]}"; do
    #     logDebug "Aggregating loadpoint $loadpoint"
    #     escapedLoadpoint=$(echo $loadpoint | sed 's/ /\\ /g')
    #     writeDailyAggregations "integral-positives" "value" "chargePower" "loadpointDailyEnergy" $ayear $amonth $aday "AND \"loadpoint\"::tag = '${loadpoint}' AND value < $PEAK_POWER_LIMIT" "true" "loadpoint=${escapedLoadpoint}"
    # done

    writeDailyPriceAggregation $ayear $amonth $aday
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
        logDebug "There is no data from $dailytargetMeasurement for $monthlytargetMeasurement. Writing 0 as data point for this month."
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

    # logInfo "`printf "Aggregating monthly metrics for %04d" $ayear`-`printf "%02d" $amonth`"

    # writeMonthlyAggregations "sum" "value" "pvDailyEnergy" "pvMonthlyEnergy" $ayear $amonth
    # writeMonthlyAggregations "sum" "value" "homeDailyEnergy" "homeMonthlyEnergy" $ayear $amonth
    # writeMonthlyAggregations "sum" "value" "gridDailyEnergy" "gridMonthlyEnergy" $ayear $amonth
    # writeMonthlyAggregations "sum" "value" "feedInDailyEnergy" "feedInMonthlyEnergy" $ayear $amonth
    # writeMonthlyAggregations "sum" "value" "energyPurchasedDailyPrice" "energyPurchasedMonthlyPrice" $ayear $amonth
    # writeMonthlyAggregations "sum" "value" "energySoldDailyPrice" "energySoldMonthlyPrice" $ayear $amonth

    # if [ "$HOME_BATTERY" == "true" ]; then
    #     writeMonthlyAggregations "sum" "value" "dischargeDailyEnergy" "dischargeMonthlyEnergy" $ayear $amonth
    #     writeMonthlyAggregations "sum" "value" "chargeDailyEnergy" "chargeMonthlyEnergy" $ayear $amonth
    # else
    #     logDebug "Home battery aggregation is disabled"
    # fi

    # for vehicle in "${VEHICLES[@]}"; do
    #     logDebug "Aggregating vehicle $vehicle"
    #     escapedVehicle=$(echo $vehicle | sed 's/ /\\ /g')
    #     writeMonthlyAggregations "spread" "value" "vehicleOdometerDailyMax" "vehicleMonthlyDrivenKm" $ayear $amonth "AND \"vehicle\"::tag = '${vehicle}'" "vehicle=${escapedVehicle}"
    #     writeMonthlyAggregations "sum" "value" "vehicleDailyEnergy" "vehicleMonthlyEnergy" $ayear $amonth "AND \"vehicle\"::tag = '${vehicle}'" "vehicle=${escapedVehicle}"
    # done

    # for loadpoint in "${LOADPOINTS[@]}"; do
    #     logDebug "Aggregating loadpoint $loadpoint"
    #     escapedLoadpoint=$(echo $loadpoint | sed 's/ /\\ /g')
    #     writeMonthlyAggregations "sum" "value" "loadpointDailyEnergy" "loadpointMonthlyEnergy" $ayear $amonth "AND \"loadpoint\"::tag = '${loadpoint}'" "loadpoint=${escapedLoadpoint}"
    # done
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
    vehicle_list=$(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -execute "show tag values from vehicleOdometer with key="vehicle | grep "^vehicle " | sed 's/^vehicle //' | sort)
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
    loadpoint_list=$(influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -execute "show tag values from vehicleOdometer with key="loadpoint | grep "^loadpoint " | sed 's/^loadpoint //' | sort)
    while read loadpoint; do
        if [ "$loadpoint" != "" ]; then
            LOADPOINTS[${index}]=$loadpoint
            index=$((index+1))
            logInfo "Detected loadpoint $index: $loadpoint"
        fi
    done <<< "$loadpoint_list"
    logDebug "Detected ${#LOADPOINTS[*]} loadpoints: ${LOADPOINTS[*]}"
}



###############################################################################
### MAIN
###############################################################################
parseArguments $@

if ! bc --version > /dev/null 2>&1; then
    logError "This script required the bc command. Please install bc, e.g. by running 'apt install bc'."
    exit 1
fi

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
elif [ "$AGGREGATE_FROM_YEAR" -ne 0 ]; then
    for (( year=$AGGREGATE_FROM_YEAR; year<=$AGGREGATE_TO_YEAR; year++ )); do
        if isLeapYear $year; then
            logDebug "The year $year is a leap year. February has 29 days."
            DAYS_OF_MONTH[2]=29
        else
            logDebug "The year $year is not a leap year. February has 28 days."
            DAYS_OF_MONTH[2]=28
        fi

        startMonth=1
        endMonth=12
        if [ $year -eq $AGGREGATE_FROM_YEAR ]; then
            startMonth=$AGGREGATE_FROM_MONTH
        fi
        if [ $year -eq $AGGREGATE_TO_YEAR ]; then
            endMonth=$AGGREGATE_TO_MONTH
        fi

        for (( month=$startMonth; month<=$endMonth; month++ )); do
            startDay=1
            endDay=${DAYS_OF_MONTH[$month]}
            if [ $year -eq $AGGREGATE_FROM_YEAR ] && [ $month -eq $AGGREGATE_FROM_MONTH ]; then
                startDay=$AGGREGATE_FROM_DAY
            fi
            if [ $year -eq $AGGREGATE_TO_YEAR ] && [ $month -eq $AGGREGATE_TO_MONTH ]; then
                endDay=$AGGREGATE_TO_DAY
            fi
            for (( day=$startDay; day<=$endDay; day++ )); do
                aggregateDay $year $month $day
            done
            aggregateMonth $year $month
        done
    done
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