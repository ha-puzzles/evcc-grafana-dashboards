#!/bin/bash

# Aggregate date into daily chunks

#consts
INFLUX_EVCC_DB="evcc" # Name of the Influx DB, where you write the EVCC data into.
INFLUX_EVCC_USER="" # User name of the EVCC DB. Empty, if no user is required. Default: ""
INFLUX_EVCC_PASSWORD="none" # Password of the EVCC DB user. Can be anything except an empty string in case no password is set.  Default: "none"
INFLUX_AGGR_DB="evcc_aggr" # Name of the Influx DB, where you write the aggregations into.
INFLUX_AGGR_USER="" # User name of the aggregation DB. Empty, if no user is required. Default: ""
INFLUX_AGGR_PASSWORD="none" # Password of the aggreation DB user. Can be anything except an empty string in case no password is set.  Default: "none"
INFLUX_HOST="localhost" # If the script is run remotely, enter the host name of the remote host. Default: "localhost"
INFLUX_PORT=8086 # The port to connect to influx. Default: 8086
HOME_BATTERY="true" # Set to false in case your home does not use a battery.
DEBUG="false" # Set to true to generate debug output.
LOADPOINT_1_TITLE="Garage" # Title of loadpoint 1 as defined in evcc.yaml
LOADPOINT_2_ENABLED=true # Set to false in case you have just one loadpoint
LOADPOINT_2_TITLE="Stellplatz" # Title of loadpoint 2 as defined in evcc.yaml
TIMEZONE="Europe/Berlin" # Time zone as in TZ identifier column here: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones#List
PEAK_POWER_LIMIT=25000 # Limit in W to filter out unrealistic peaks

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
    printUsage
    exit 1
}

printUsage() {
    echo "`basename $0` [--year <year> | --month <year> <month> | --day <year> <month> <day> | --yesterday | --today | --delete-aggregations]"
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

writeDailyEnergies() {
    mode=$1 # all | positives | negatives
    field=$2
    powerMeasurement=$3
    energyMeasurement=$4
    year=$5
    month=$6
    day=$7
    additionalWhere=$8

    printf -v fYear "%04d" $year
    printf -v fMonth "%02d" $month
    printf -v fDay "%02d" $day

    # Convert time to UTC for local timezone
    fromTime=$(date -d "`date -d ${fYear}-${fMonth}-${fDay}T00:00:00 +%FT%T%Z`" -u +%FT%TZ)
    toTime=$(date -d "`date -d ${fYear}-${fMonth}-${fDay}T23:59:59 +%FT%T%Z`" -u +%FT%TZ)
    timeCondition="time >= '${fromTime}' AND time <= '${toTime}'"

    query=""
    case $mode in
        all)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of all values from $powerMeasurement into ${energyMeasurement}"
            query="SELECT integral(\"$field\") / 3600 FROM \"$powerMeasurement\" WHERE ${timeCondition} $additionalWhere GROUP BY time(1d) fill(none) tz('$TIMEZONE')"
            ;;
        positives)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of positive values from $powerMeasurement into ${energyMeasurement}"
            # query="SELECT integral(\"subquery\") / 3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$powerMeasurement\" WHERE ${timeCondition} $additionalWhere AND \"$field\" >=0 GROUP BY time(10s) fill(0)) WHERE ${timeCondition} GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
            query="SELECT integral(\"subquery\") / 3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$powerMeasurement\" WHERE ${timeCondition} $additionalWhere AND \"$field\" >=0 GROUP BY time(10s) fill(0)) WHERE ${timeCondition} GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
            
            ;;
        negatives)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of negative values from $powerMeasurement into ${energyMeasurement}"
            # query="SELECT integral(\"subquery\") / -3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$powerMeasurement\" WHERE ${timeCondition} $additionalWhere AND \"$field\" <=0 GROUP BY time(10s) fill(0)) WHERE ${timeCondition} GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
            query="SELECT integral(\"subquery\") / -3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$powerMeasurement\" WHERE ${timeCondition} $additionalWhere AND \"$field\" <=0 GROUP BY time(10s) fill(0)) WHERE ${timeCondition} GROUP BY time(1d) fill(0) tz('$TIMEZONE')"
            
            ;;
        *)
            logError "Unknown query mode: '$mode'."
            exit 1
            ;;
    esac
    logDebug "Query: $query"

    queryResult=`influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_EVCC_DB -username "$INFLUX_EVCC_USER" -password "$INFLUX_EVCC_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1`
    logDebug "Query result (last row): $queryResult"
    if [ `echo $queryResult | wc -w ` -eq 2 ]; then
        timestamp=`echo "$queryResult" | cut -d " " -f 1`
        timestampNano=`date -d "$timestamp" +%s%9N`
        energy=`echo "$queryResult" | cut -d " " -f 2`
        insertStatement="INSERT ${energyMeasurement},year=${fYear},month=${fMonth},day=${fDay} value=${energy} ${timestampNano}"
        logDebug "Insert statement: $insertStatement"
        influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -execute "$insertStatement"
    else
        logInfo "There is no data from $powerMeasurement for $energyMeasurement. This may be fine, if no data had been collected for this day and this measurement."
    fi
}

aggregateDay() {
    ayear=$1
    amonth=$2
    aday=$3

    logInfo "Aggregating daily metrics for `printf "%04d" $ayear`-`printf "%02d" $amonth`-`printf "%02d" $aday`"

    writeDailyEnergies "all" "value" "pvPower" "pvDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT"
    writeDailyEnergies "all" "value" "homePower" "homeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT"
    writeDailyEnergies "all" "value" "chargePower" "loadpoint1DailyEnergy" $ayear $amonth $aday "AND ("loadpoint"::tag = '${LOADPOINT_1_TITLE}') AND value < $PEAK_POWER_LIMIT"

    if [ "$LOADPOINT_2_ENABLED" == "true" ]; then
        writeDailyEnergies "all" "value" "chargePower" "loadpoint2DailyEnergy" $ayear $amonth $aday "AND ("loadpoint"::tag = '${LOADPOINT_2_TITLE}') AND value < $PEAK_POWER_LIMIT"
    else
        logDebug "Loadpoint 2 is disabled."
    fi
    writeDailyEnergies "positives" "value" "gridPower" "gridDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT"
    writeDailyEnergies "negatives" "value" "gridPower" "feedInDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT"

    if [ "$HOME_BATTERY" == "true" ]; then
        writeDailyEnergies "positives" "value" "batteryPower" "dischargeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT"
        writeDailyEnergies "negatives" "value" "batteryPower" "chargeDailyEnergy" $ayear $amonth $aday "AND value < $PEAK_POWER_LIMIT"
    else
        logDebug "Home battery aggregation is disabled."
    fi
}

writeMonthlyEnergies () {
    field=$1
    dailyEnergyMeasurement=$2
    monthlyEnergyMeasurement=$3
    year=$4
    month=$5

    numDays=${DAYS_OF_MONTH[$month]}

    printf -v fYear "%04d" $year
    printf -v fMonth "%02d" $month
    printf -v fDays "%02d" $numDays

    # Convert time to UTC for local timezone
    fromTime=$(date -d "`date -d ${fYear}-${fMonth}-01T00:00:00 +%FT%T%Z`" -u +%FT%TZ)
    toTime=$(date -d "`date -d ${fYear}-${fMonth}-${fDays}T23:59:59 +%FT%T%Z`" -u +%FT%TZ)
    timeCondition="time >= '${fromTime}' AND time <= '${toTime}'"

    logDebug "${fYear}-${fMonth}: Creating monthly aggregation from $dailyEnergyMeasurement into ${monthlyEnergyMeasurement}"
    logDebug "Month has $numDays days."
    query="SELECT sum(\"$field\") FROM $dailyEnergyMeasurement WHERE ${timeCondition} tz('$TIMEZONE')"
    logDebug "Query: $query"

    queryResult=`influx -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1`
    logDebug "Query result (last row): $queryResult"
    if [ `echo $queryResult | wc -w ` -eq 2 ]; then
        timestamp=`echo "$queryResult" | cut -d " " -f 1`
        timestampNano=`date -d "$timestamp" +%s%9N`
        energy=`echo "$queryResult" | cut -d " " -f 2`
        insertStatement="INSERT ${monthlyEnergyMeasurement},year=${fYear},month=${fMonth} value=${energy} ${timestampNano}"
        logDebug "Insert statement: $insertStatement"
        influx  -host "$INFLUX_HOST" -port $INFLUX_PORT -database $INFLUX_AGGR_DB -username "$INFLUX_AGGR_USER" -password "$INFLUX_AGGR_PASSWORD" -execute "$insertStatement"
    else
        logInfo "There is no data from $dailyEnergyMeasurement for $monthlyEnergyMeasurement. This may be fine, if no data had been collected for this month and this measurement."
    fi    
}

aggregateMonth() {
    ayear=$1
    amonth=$2

    logInfo "`printf "Aggregating monthly metrics for %04d" $ayear`-`printf "%02d" $amonth`"

    writeMonthlyEnergies "value" "pvDailyEnergy" "pvMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "homeDailyEnergy" "homeMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "loadpoint1DailyEnergy" "loadpoint1MonthlyEnergy" $ayear $amonth 
    if [ "$LOADPOINT_2_ENABLED" == "true" ]; then
        writeMonthlyEnergies "value" "loadpoint2DailyEnergy" "loadpoint2MonthlyEnergy" $ayear $amonth
    else
        logDebug "Loadpoint 2 is disabled."
    fi
    writeMonthlyEnergies "value" "gridDailyEnergy" "gridMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "feedInDailyEnergy" "feedInMonthlyEnergy" $ayear $amonth

    if [ "$HOME_BATTERY" == "true" ]; then
        writeMonthlyEnergies "value" "dischargeDailyEnergy" "dischargeMonthlyEnergy" $ayear $amonth
        writeMonthlyEnergies "value" "chargeDailyEnergy" "chargeMonthlyEnergy" $ayear $amonth
    else
        logDebug "Home battery aggregation is disabled"
    fi
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
        dropMeasurement "loadpoint1DailyEnergy"
        dropMeasurement "loadpoint2DailyEnergy"
        dropMeasurement "gridDailyEnergy"
        dropMeasurement "feedInDailyEnergy"
        dropMeasurement "dischargeDailyEnergy"
        dropMeasurement "chargeDailyEnergy"
        dropMeasurement "pvMonthlyEnergy"
        dropMeasurement "homeMonthlyEnergy"
        dropMeasurement "loadpoint1MonthlyEnergy"
        dropMeasurement "loadpoint2MonthlyEnergy"
        dropMeasurement "gridMonthlyEnergy"
        dropMeasurement "feedInMonthlyEnergy"
        dropMeasurement "dischargeMonthlyEnergy"
        dropMeasurement "chargeMonthlyEnergy"
    else
        logInfo "Deletion of aggregated measurements aborted."
    fi
}

###############################################################################
### MAIN
###############################################################################
parseArguments $@

if [ "$DELETE_AGGREGATIONS" != "true" ]; then
    logInfo "[`date '+%F %T'`] Starting aggregation..."
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