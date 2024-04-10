#!/bin/bash

# Aggregate date into daily chunks

#consts
INFLUXDB="evcc" # Name of the Influx DB, where you write the EVCC data into
INFLUX_USER="" # Your user name. Empty, if no user is required.
INFLUX_PASSWORD="none" # can be anything except an empty string in case no password is set
DEBUG="false" # set to true to generate debug output
LOADPOINT_1_TITLE="Garage" # title of loadpoint 1 as defined in evcc.yaml
LOADPOINT_2_ENABLED=true # set to false in case you have just one loadpoint
LOADPOINT_2_TITLE="Stellplatz" # title of loadpoint 2 as defined in evcc.yaml

#arguments
AGGREGATE_YEAR=0
AGGREGATE_YESTERDAY=false
AGGREGATE_TODAY=false
AGGREGATE_MONTH_YEAR=0
AGGREGATE_MONTH_MONTH=0
AGGREGATE_DAY_YEAR=0
AGGREGATE_DAY_MONTH=0
AGGREGATE_DAY_DAY=0

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
    echo "[ERROR] $1"
}

logInfo() {
    echo "[INFO]  $1"
}

logDebug() {
    if [ "$DEBUG" == "true" ]; then
        echo "[DEBUG] $1"
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
    printUsage
    exit 1
}

printUsage() {
    echo "`basename $0` [--year <year> | --month <year> <month> | --day <year> <month> <day> | --yesterday | --today]"
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

isMeasurementExisting() {
    databaseName=$1
    
    return influx -database $INFLUXDB -execute 'show measurements' | grep -q $databaseName
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


    query=""
    case $mode in
        all)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of all values from $powerMeasurement into ${energyMeasurement}"
            query="SELECT integral(\"$field\") / 3600 FROM \"$powerMeasurement\" WHERE time >= '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time <= '${fYear}-${fMonth}-${fDay}T23:59:59Z' $additionalWhere GROUP BY time(1d) fill(none)"
            ;;
        positives)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of positive values from $powerMeasurement into ${energyMeasurement}"
            query="SELECT integral(\"subquery\") / 3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$powerMeasurement\" WHERE time >= '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time <= '${fYear}-${fMonth}-${fDay}T23:59:59Z' $additionalWhere AND \"$field\" >=0 GROUP BY time(10s) fill(none)) WHERE time > '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time < '${fYear}-${fMonth}-${fDay}T23:59:59Z' GROUP BY time(1d) fill(null)"
            ;;
        negatives)
            logDebug "${fYear}-${fMonth}-${fDay}: Aggregating energy of negative values from $powerMeasurement into ${energyMeasurement}"
            query="SELECT integral(\"subquery\") / -3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM \"$powerMeasurement\" WHERE time >= '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time <= '${fYear}-${fMonth}-${fDay}T23:59:59Z' $additionalWhere AND \"$field\" <=0 GROUP BY time(10s) fill(none)) WHERE time > '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time < '${fYear}-${fMonth}-${fDay}T23:59:59Z' GROUP BY time(1d) fill(null)"
            ;;
        *)
            logError "Unknown query mode: '$mode'."
            exit 1
            ;;
    esac
    logDebug "Query: $query"

    queryResult=`influx -database $INFLUXDB -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1`
    logDebug "Query result (last row): $queryResult"
    if [ `echo $queryResult | wc -w ` -eq 2 ]; then
        timestamp=`echo "$queryResult" | cut -d " " -f 1`
        timestampNano=`date -d "$timestamp" +%s%9N`
        energy=`echo "$queryResult" | cut -d " " -f 2`
        insertStatement="INSERT ${energyMeasurement},year=${fYear},month=${fMonth},day=${fDay} value=${energy} ${timestampNano}"
        logDebug "Insert statement: $insertStatement"
        influx -database $INFLUXDB -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -execute "$insertStatement"
    else
        logInfo "There is no data from $powerMeasurement for $energyMeasurement. This may be fine, if no data had been collected for this day and this measurement."
    fi
}

aggregateDay() {
    ayear=$1
    amonth=$2
    aday=$3

    logInfo "`printf "%04d" $ayear`-`printf "%02d" $amonth`-`printf "%02d" $aday`: Aggregating daily metrics."

    writeDailyEnergies "all" "value" "pvPower" "pvDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "all" "value" "homePower" "homeDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "all" "value" "chargePower" "carDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "all" "value" "chargePower" "loadpoint1DailyEnergy" $ayear $amonth $aday "AND ("loadpoint"::tag = '${LOADPOINT_1_TITLE}') AND value < 20000"

    if [ "$LOADPOINT_2_ENABLED" == "true" ]; then
        writeDailyEnergies "all" "value" "chargePower" "loadpoint2DailyEnergy" $ayear $amonth $aday "AND ("loadpoint"::tag = '${LOADPOINT_2_TITLE}') AND value < 20000"
    else
        logDebug "Loadpoint 2 is disabled."
    fi
    writeDailyEnergies "positives" "value" "gridPower" "gridDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "negatives" "value" "gridPower" "feedInDailyEnergy" $ayear $amonth $aday "AND value < 20000"

    if [ "$HOME_BATTERY" == "true" ]; then
        writeDailyEnergies "positives" "value" "batteryPower" "dischargeDailyEnergy" $ayear $amonth $aday "AND value < 20000"
        writeDailyEnergies "negatives" "value" "batteryPower" "chargeDailyEnergy" $ayear $amonth $aday "AND value < 20000"
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

    logDebug "${fYear}-${fMonth}: Creating monthly aggregation from $dailyEnergyMeasurement into ${monthlyEnergyMeasurement}"
    logDebug "Month has $numDays days."
    query="SELECT sum(\"$field\") FROM $dailyEnergyMeasurement WHERE time >= '${fYear}-${fMonth}-01T00:00:00Z' AND time <= '${fYear}-${fMonth}-${fDays}T23:59:59Z'"
    logDebug "Query: $query"

    queryResult=`influx -database $INFLUXDB -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1`
    logDebug "Query result (last row): $queryResult"
    if [ `echo $queryResult | wc -w ` -eq 2 ]; then
        timestamp=`echo "$queryResult" | cut -d " " -f 1`
        timestampNano=`date -d "$timestamp" +%s%9N`
        energy=`echo "$queryResult" | cut -d " " -f 2`
        insertStatement="INSERT ${monthlyEnergyMeasurement},year=${fYear},month=${fMonth} value=${energy} ${timestampNano}"
        logDebug "Insert statement: $insertStatement"
        influx -database $INFLUXDB -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -execute "$insertStatement"
    else
        logInfo "There is no data from $dailyEnergyMeasurement for $monthlyEnergyMeasurement. This may be fine, if no data had been collected for this month and this measurement."
    fi    
}

aggregateMonth() {
    ayear=$1
    amonth=$2

    logInfo "`printf "%04d" $ayear`-`printf "%02d" $amonth`: Aggregating monthly metrics."

    writeMonthlyEnergies "value" "pvDailyEnergy" "pvMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "homeDailyEnergy" "homeMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "carDailyEnergy" "carMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "loadpoint1DailyEnergy" "loadpoint1MonthlyEnergy" $ayear $amonth 
        if [ "$LOADPOINT_2_ENABLED" == "true" ]; then
    writeMonthlyEnergies "value" "loadpoint2DailyEnergy" "loadpoint2MonthlyEnergy" $ayear $amonth
    else
        logDebug "Loadpoint 2 is disabled."
    fi
    writeMonthlyEnergies "value" "gridDailyEnergy" "gridMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "feedInDailyEnergy" "feedInMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "dischargeDailyEnergy" "dischargeMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "chargeDailyEnergy" "chargeMonthlyEnergy" $ayear $amonth
}

###############################################################################
### MAIN
###############################################################################
parseArguments $@



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
fi

### END