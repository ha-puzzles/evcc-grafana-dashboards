#!/bin/bash

# Aggregate date into daily chunks

#consts
INFLUXDB="evcc" # Name of the Influx DB, where you write the EVCC data into
INFLUX_USER="" # Your user name. Empty, if no user is required.
INFLUX_PASSWORD="none" # can be anything except an empty string in case no password is set

#arguments
AGGREGATE_YEAR=0
AGGREGATE_YESTERDAY=false
AGGREGATE_TODAY=false
AGGREGATE_MONTH_YEAR=0
AGGREGATE_MONTH_MONTH=0

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
        echo "Aggregating year $AGGREGATE_YEAR"
        return 0
    fi
    if [ "$1" == '--month' ]; then
        if [ "$#" -ne 3 ]; then
            printUsage
            exit 1
        fi
        AGGREGATE_MONTH_YEAR=$2
        AGGREGATE_MONTH_MONTH=$3
        echo "Aggregating month ${AGGREGATE_MONTH_YEAR}-${AGGREGATE_MONTH_MONTH}"
        return 0
    fi
    if [ "$1" == '--yesterday' ]; then
        AGGREGATE_YESTERDAY=true
        echo "Aggregating yesterday"
        return 0
    fi
    if [ "$1" == '--today' ]; then
        AGGREGATE_TODAY=true
        echo "Aggregating today"
        return 0
    fi
    printUsage
    exit 1
}

printUsage() {
    echo "`basename $0` [--year <year> | --month <year> <month> | --yesterday | --today]"
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

# STDOUT: last line of query result
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
            # echo "${fYear}-${fMonth}-${fDay}: Aggregating energy of all values from $powerMeasurement into ${energyMeasurement}"
            query="SELECT integral(\"$field\") / 3600 FROM $powerMeasurement WHERE time >= '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time <= '${fYear}-${fMonth}-${fDay}T23:59:59Z' $additionalWhere GROUP BY time(1d) fill(none)"
            ;;
        positives)
            # echo "${fYear}-${fMonth}-${fDay}: Aggregating energy of positive values from $powerMeasurement into ${energyMeasurement}"
            query="SELECT integral(\"subquery\") / 3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM "$powerMeasurement" WHERE time >= '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time <= '${fYear}-${fMonth}-${fDay}T23:59:59Z' $additionalWhere AND \"$field\" >=0 GROUP BY time(10s) fill(none)) WHERE time > '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time < '${fYear}-${fMonth}-${fDay}T23:59:59Z' GROUP BY time(1d) fill(null)"
            ;;
        negatives)
            # echo "${fYear}-${fMonth}-${fDay}: Aggregating energy of negative values from $powerMeasurement into ${energyMeasurement}"
            query="SELECT integral(\"subquery\") / -3600 FROM (SELECT mean(\"$field\") AS \"subquery\" FROM "$powerMeasurement" WHERE time >= '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time <= '${fYear}-${fMonth}-${fDay}T23:59:59Z' $additionalWhere AND \"$field\" <=0 GROUP BY time(10s) fill(none)) WHERE time > '${fYear}-${fMonth}-${fDay}T00:00:00Z' AND time < '${fYear}-${fMonth}-${fDay}T23:59:59Z' GROUP BY time(1d) fill(null)"
            ;;
        *)
            echo "ERROR: Unknown mode"
            exit 1
            ;;
    esac

    queryResult=`influx -database $INFLUXDB -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1`
    if [ `echo $queryResult | wc -w ` -eq 2 ]; then
        timestamp=`echo "$queryResult" | cut -d " " -f 1`
        timestampNano=`date -d "$timestamp" +%s%9N`
        energy=`echo "$queryResult" | cut -d " " -f 2`
        insertStatement="INSERT ${energyMeasurement},year=${fYear},month=${fMonth},day=${fDay} value=${energy} ${timestampNano}"
        influx -database $INFLUXDB -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -execute "$insertStatement"
    else
        echo "INFO: Query for daily aggregation of measurement $powerMeasurement did not return any results."
    fi
}

aggregateDay() {
    ayear=$1
    amonth=$2
    aday=$3

    echo "`printf "%04d" $ayear`-`printf "%02d" $amonth`-`printf "%02d" $day`: Aggregating daily metrics."

    writeDailyEnergies "all" "value" "pvPower" "pvDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "all" "value" "homePower" "homeDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "all" "value" "chargePower" "carDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "all" "value" "chargePower" "garageDailyEnergy" $ayear $amonth $aday "AND ("loadpoint"::tag = 'Garage') AND value < 20000"
    writeDailyEnergies "all" "value" "chargePower" "stellplatzDailyEnergy" $ayear $amonth $aday "AND ("loadpoint"::tag = 'Stellplatz') AND value < 20000"
    writeDailyEnergies "positives" "value" "gridPower" "gridDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "negatives" "value" "gridPower" "feedInDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "positives" "value" "batteryPower" "dischargeDailyEnergy" $ayear $amonth $aday "AND value < 20000"
    writeDailyEnergies "negatives" "value" "batteryPower" "chargeDailyEnergy" $ayear $amonth $aday "AND value < 20000"
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

    # echo "${fYear}-${fMonth}: Creating monthly aggregation from $dailyEnergyMeasurement into ${monthlyEnergyMeasurement}"
    query="SELECT sum(\"$field\") FROM $dailyEnergyMeasurement WHERE time >= '${fYear}-${fMonth}-01T00:00:00Z' AND time <= '${fYear}-${fMonth}-${fDays}T23:59:59Z'"
    #echo $query
    queryResult=`influx -database $INFLUXDB -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -precision rfc3339 -execute "$query" | tail -n 1`
    if [ `echo $queryResult | wc -w ` -eq 2 ]; then
        timestamp=`echo "$queryResult" | cut -d " " -f 1`
        timestampNano=`date -d "$timestamp" +%s%9N`
        energy=`echo "$queryResult" | cut -d " " -f 2`
        insertStatement="INSERT ${monthlyEnergyMeasurement},year=${fYear},month=${fMonth} value=${energy} ${timestampNano}"
        influx -database $INFLUXDB -username "$INFLUX_USER" -password "$INFLUX_PASSWORD" -execute "$insertStatement"
    else
        echo "INFO: Query for monthly aggregation of measurement $dailyEnergyMeasurement did not return any results."
    fi    
}

aggregateMonth() {
    ayear=$1
    amonth=$2

    echo "`printf "%04d" $ayear`-`printf "%02d" $amonth`:    Aggregating monthly metrics."

    writeMonthlyEnergies "value" "pvDailyEnergy" "pvMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "homeDailyEnergy" "homeMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "carDailyEnergy" "carMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "garageDailyEnergy" "garageMonthlyEnergy" $ayear $amonth 
    writeMonthlyEnergies "value" "stellplatzDailyEnergy" "stellplatzMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "gridDailyEnergy" "gridMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "feedInDailyEnergy" "feedInMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "dischargeDailyEnergy" "dischargeMonthlyEnergy" $ayear $amonth
    writeMonthlyEnergies "value" "chargeDailyEnergy" "chargeMonthlyEnergy" $ayear $amonth
}

###############################################################################
### MAIN
###############################################################################
parseArguments $@

if isLeapYear $AGGREGATE_YEAR; then
    DAYS_OF_MONTH[2]=29
fi

if [ "$AGGREGATE_YEAR" -ne 0 ]; then

    for month in {1..12}; do
        for (( day=1; day<=${DAYS_OF_MONTH[$month]}; day++ )); do
            aggregateDay $AGGREGATE_YEAR $month $day
        done
        aggregateMonth $AGGREGATE_YEAR $month
    done
elif [ "$AGGREGATE_MONTH_YEAR" -ne 0 ]; then
    aggregateMonth $AGGREGATE_MONTH_YEAR $AGGREGATE_MONTH_MONTH
elif [ "$AGGREGATE_YESTERDAY" == "true" ]; then
    year=`date -d yesterday +%Y`
    month=`date -d yesterday +%m`
    day=`date -d yesterday +%d`
    aggregateDay $year $month $day
    aggregateMonth $year $month
elif [ "$AGGREGATE_TODAY" == "true" ]; then
    year=`date +%Y`
    month=`date +%m`
    day=`date +%d`
    aggregateDay $year $month $day
    aggregateMonth $year $month
fi

### END