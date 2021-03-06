#!/bin/bash
# Change to your path variables throughout, hoping to add up front global vars
cp ~/unomp/unified/scripts/payouts ~/unomp/unified/scripts/old_payouts
rm ~/unomp/unified/scripts/payouts

counter=0
redis-cli -h 172.16.1.17 del Pool_Stats:CurrentShift:Coins
redis-cli -h 172.16.1.17 del Pool_Stats:CurrentShift:CoinsTgtCoin
now="$(date +"%s")"
thisShift=$(redis-cli -h 172.16.1.17 hget Pool_Stats This_Shift)
ShiftStart=$(redis-cli -h 172.16.1.17 hget Pool_Stats:"$thisShift" starttime)
TgtPrice=$(redis-cli -h 172.16.1.17 hget Exchange_Rates opalcoin)
TotalEarned=0
TotalEarnedTgt=0

# loop through algos
while read line
do
        AlgoTotal=0
        AlgoTotalTgt=0
        logkey2="Pool_Stats:"$thisShift":Algos"
        logkey2Tgt="Pool_Stats:"$thisShift":AlgosTgt"
	echo "LOGKEY2: $logkey2"

        # loop through each coin for that algo
        while read CoinName
        do
                coinTotal=0
                coinTotalTgt=0
                thiskey=$CoinName":balances"
                logkey="Pool_Stats:"$thisShift":Coins"
                logkeyTgt="Pool_Stats:"$thisShift":CoinsTgt"
                #Determine price for Coin
                coin2btc=`redis-cli -h 172.16.1.17 hget Exchange_Rates $CoinName`
		echo "$CoinName - $coin2btc"
                workersPerCoin=`redis-cli -h 172.16.1.17 hlen $thiskey`
                if [ $workersPerCoin = 0 ]
                then
                        echo "do nothing" > /dev/null
                else

                        while read WorkerName
                        do
                                thisBalance=$(redis-cli -h 172.16.1.17 hget $thiskey $WorkerName)
                                thisEarned=$(echo "scale=8;$thisBalance * $coin2btc" | bc -l)
                                coinTotal=$(echo "scale=8;$coinTotal + $thisEarned" | bc -l)
                                AlgoTotal=$(echo "scale=8;$AlgoTotal + $thisEarned" | bc -l)
                                TgtEarned=$(echo "scale=8;$thisEarned / $TgtPrice" | bc -l)
                                coinTotalTgt=$(echo "scale=8;$coinTotalTgt + $TgtEarned" | bc -l)
                                AlgoTotalTgt=$(echo "scale=8;$AlgoTotalTgt + $TgtEarned" | bc -l)
                                redis-cli -h 172.16.1.17 hincrbyfloat Pool_Stats:CurrentRound "Total" "$TgtEarned"
                                redis-cli -h 172.16.1.17 hincrbyfloat Pool_Stats:CurrentRound "$WorkerName" "$TgtEarned"
                                redis-cli -h 172.16.1.17 hincrbyfloat Worker_Stats:TotalPaid "Total" "$TgtEarned"
                                echo "$WorkerName earned $thisEarned from $CoinName"
                        done< <(redis-cli -h 172.16.1.17 hkeys "$CoinName":balances)
                        redis-cli -h 172.16.1.17 hset "$logkey" "$CoinName" "$coinTotal"
                        redis-cli -h 172.16.1.17 hset "$logkeyTgt" "$CoinName" "$coinTotalTgt"
                        echo "$CoinName: $coinTotal"

                fi
        done< <(redis-cli -h 172.16.1.17 hkeys Coin_Names_"$line")
TotalEarned=$(echo "scale=8;$TotalEarned + $AlgoTotal" | bc -l)
TotalEarnedTgt=$(echo "scale=8;$TotalEarnedTgt + $AlgoTotalTgt" | bc -l)


done< <(redis-cli -h 172.16.1.17 hkeys Coin_Algos)
redis-cli -h 172.16.1.17 hset Pool_Stats:"$thisShift" Earned_BTC "$TotalEarned"
redis-cli -h 172.16.1.17 hset Pool_Stats:"$thisShift" Earned_Tgt "$TotalEarnedTgt"

echo "Total Earned: $TotalEarned"

redis-cli -h 172.16.1.17 hset Pool_Stats:"$thisShift" endtime "$now"
nextShift=$(($thisShift + 1))
redis-cli -h 172.16.1.17 hincrby Pool_Stats This_Shift 1
echo "$thisShift" >> ~/unomp/unified/multipool/alerts/Shifts
redis-cli -h 172.16.1.17 hset Pool_Stats:$nextShift starttime "$now"
echo "Printing Earnings report" >> ~/unomp/unified/multipool/alerts/ShiftChangeLog.txt
echo "Shift change switching from $thisShift to $nextShift at $now" >> ~/unomp/unified/multipool/alerts/ShiftChangeErrorCheckerReport

######STILL NEEDS TO BE CHANGED FOR EXTRA COINS#####
while read WorkerName
do
        PrevBalance=$(redis-cli -h 172.16.1.17 zscore Pool_Stats:Balances "$WorkerName")
        if [[ $PrevBalance == "" ]]
        then
                PrevBalance=0
        fi
        thisBalance=$(redis-cli -h 172.16.1.17 hget Pool_Stats:CurrentRound "$WorkerName")
        TotalBalance=$(echo "scale=8;$PrevBalance + $thisBalance" | bc -l) >/dev/null
        echo "$WorkerName" "$TotalBalance"
        echo "$WorkerName $TotalBalance - was $PrevBalance plus today's $thisBalance" >> ~/unomp/unified/multipool/alerts/ShiftChangeErrorCheckerReport
        redis-cli -h 172.16.1.17 zadd Pool_Stats:Balances "$TotalBalance" "$WorkerName"
        redis-cli -h 172.16.1.17 hset Worker_Stats:Earnings:"$WorkerName" "$thisShift" "$thisBalance"
        redis-cli -h 172.16.1.17 hincrbyfloat Worker_Stats:TotalEarned "$WorkerName" "$thisBalance"
echo "$WorkerName" "$TotalBalance"
        redis-cli -h 172.16.1.17 zadd Pool_Stats:Balances "$TotalBalance" "$WorkerName"
        redis-cli -h 172.16.1.17 hset Worker_Stats:Earnings:"$WorkerName" "$thisShift" "$thisBalance"
        redis-cli -h 172.16.1.17 hincrbyfloat Worker_Stats:TotalEarned "$WorkerName" "$thisBalance"
done< <(redis-cli -h 172.16.1.17 hkeys Pool_Stats:CurrentRound)
echo "Done adding coins, clearing balances for shift $thisShift at $now." >> ~/unomp/unified/multipool/alerts/ShiftChangeLog.log
######STILL NEEDS TO BE CHANGED FOR EXTRA COINS#####

# Save the total BTC/Tgt earned for each shift into a historical key for auditing purposes.
echo "Done adding coins, Saving round for historical purposes"
redis-cli -h 172.16.1.17 rename Pool_Stats:CurrentRound Pool_Stats:"$thisShift":Shift
redis-cli -h 172.16.1.17 rename Pool_Stats:CurrentRoundTgt Pool_Stats:"$thisShift":ShiftTgt
redis-cli -h 172.16.1.17 rename Pool_Stats:CurrentRoundBTC Pool_Stats:"$thisShift":ShiftBTC

redis-cli -h 172.16.1.17 rename Pool_Stats:CurrentShift:Algos Pool_Stats:"$thisShift":Algos
redis-cli -h 172.16.1.17 rename Pool_Stats:CurrentShift:AlgosTgtCoin Pool_Stats:"$thisShift":AlgosTgtCoin

echo "Saving coin balances for historical purposes"
#for every coin on the pool....
while read Coin_Names2
do
        #Save the old balances key +shares and blocks for every coin into a historical key.
        redis-cli -h 172.16.1.17 rename $Coin_Names2:balances Prev:$thisShift:$Coin_Names2:balances
	redis-cli -h 172.16.1.17 rename $Coin_Names2:blocksKicked Prev:$thisShift:$Coin_Names2:blocksKicked
	redis-cli -h 172.16.1.17 rename $Coin_Names2:blocksConfirmed Prev:$thisShift:$Coin_Names2:blocksConfirmed
	redis-cli -h 172.16.1.17 rename $Coin_Names2:blocksOrphaned Prev:$thisShift:$Coin_Names2:blocksOrphaned
	redis-cli -h 172.16.1.17 rename $Coin_Names2:blocksPaid Prev:$thisShift:$Coin_Names2:blocksPaid
	redis-cli -h 172.16.1.17 rename $Coin_Names2:stats Prev:$thisShift:$Coin_Names2:stats

        # This loop will move every block from the blocksConfirmed keys into the blocksPaid keys. This means only blocksConfirmed are unpaid.
        while read PaidLine
        do
                redis-cli -h 172.16.1.17 sadd "$Coin_Names2":"blocksPaid" "$PaidLine"
                redis-cli -h 172.16.1.17 srem "$Coin_Names2":"blocksConfirmed" "$PaidLine"
                echo "nothing" > /dev/null
        done< <(redis-cli -h 172.16.1.17 smembers "$Coin_Names2":"blocksConfirmed")


done< <(redis-cli -h 172.16.1.17 hkeys Coin_Names)
echo "Done saving coin balances in database"
echo "Done script for shift $thisShift at $now" >> ~/unomp/unified/multipool/alerts/ShiftChangeLog.log
echo "Running payouts for shift $thisShift at $now"
#Calculate workers owed in excesss of 0.01 coins and generate a report of them.
while read PayoutLine
do
        amount=$(redis-cli -h 172.16.1.17 zscore Pool_Stats:Balances $PayoutLine)
        roundedamount=$(echo "scale=8;$amount - 1" | bc -l)
        echo "$PayoutLine $roundedamount"
#send all of the payments using the coin daemon
        txn=$(opalcoind --datadir=/media/tba/coin_data/.opalcoin sendtoaddress "$PayoutLine" "$amount")
        if [[ -z "$txn" ]]
        then
	#log failed payout to txt file.
        echo "shiftnumber: $thisShift payment failed! $PayoutLine" >>~/unomp/unified/multipool/alerts/alert.log
	echo "payment failed! $PayoutLine"
        else
       		echo "$PayoutLine $amount" >> ~/unomp/unified/multipool/alerts/payouts
                newtotal=$(echo "scale=8;$amount - $roundedamount" | bc -l) >/dev/null
                redis-cli -h 172.16.1.17 hincrby Pool_Stats Earning_Log_Entries 1
                redis-cli -h 172.16.1.17 lpush Worker_Stats:Payouts:"$PayoutLine" "$amount"
                redis-cli -h 172.16.1.17 hincrbyfloat Worker_Stats:TotalPaid "$PayoutLine" "$amount"
                redis-cli -h 172.16.1.17 zadd Pool_Stats:Balances 0 $PayoutLine 
        fi
done< <(redis-cli -h 172.16.1.17 zrangebyscore Pool_Stats:Balances 1.0 inf)

redis-cli -h 172.16.1.17 save
