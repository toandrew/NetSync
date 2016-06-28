--[[
版权: The ONE@copyright 2016
作用: 服务器与客户端的网络同步
作者: zhou jianmin
时间: 2016.6.26
备注: 
]]

NetSync = {}
NetSync.__cname = "NetSync"

local pingTimeoutDelay = {min = 1, max = 30}

local pingSeriesIterations = 10
local pingSeriesPeriod = 0.250
local pingSeriesDelay = { min = 10, max = 20 }

local pingDelay = 0 --current delay before next ping
local pingTimeoutId = 0 --to cancel timeout on sync_pinc
local pingId = 0 --absolute ID to mach pong against

local pingSeriesCount = 0 -- elapsed pings in a series
local seriesData = {} --circular buffer
local seriesDataNextIndex = 1 --next index to write in circular buffer
local seriesDataLength = pingSeriesIterations -- size of circular buffer

local longTermDataTrainingDuration = 120 -- Mean over an array, selecting one dimension of the array values.

local longTermDataDuration = 900
local longTermDataLength = math.max(
      2,
      longTermDataDuration /
        (0.5 * (pingSeriesDelay.min + pingSeriesDelay.max) ) )


local longTermData = {} --circular buffer
local longTermDataNextIndex = 1 --next index to write in circular buffer

local timeOffset = 0 --mean of (serverTime - clientTime) in the last series
local travelDuration = 0
local travelDurationMin = 0
local travelDurationMax = 0

    --T(t) = T0 + R * (t - t0)
local serverTimeReference = 0 -- T0
local clientTimeReference = 0 -- t0
local frequencyRatio = 1 -- R

pingTimeoutDelay.current = pingTimeoutDelay.min

--local getTimeFunction = getTimeFunction

local status = "new"
local statusChangedTime = 0

local connectionStatus = "offline"
local connectionStatusChangedTime = 0

local function mean(array, dimension)
	local val = 0
	local i = 1
	for i = 1, #array, 1 do
		Log.d("B i[%d]d[%d]val[%s][%s]", i, dimension, val, array[i][dimension])
		val = val + array[i][dimension]
		Log.d("E i[%d]d[%d]val[%s][%s]", i, dimension, val, array[i][dimension])
	end

  --return array.reduce((p, q) => p + q[dimension], 0) / array.length;
  Log.d("mean!!![%s][%s]", val/#array, #array)
  return val / #array
end

-- Order min and max attributes.
local function orderMinMax(that)
  if that and that.min and that.max and that.min > that.max then
    local tmp = that.min
    that.min = that.max
    that.max = tmp
  end

  return that
end

-- Get local time, or convert a synchronised time to a local time.
function NetSync.getLocalTime(syncTime)
    if syncTime then
      -- conversion: t(T) = t0 + (T - T0) / R
      return clientTimeReference + (syncTime - serverTimeReference) / frequencyRatio
    else
      --read local clock
      return UtilsWanakaFramework:getUnixTimestamp()
    end
end

-- Get synchronised time, or convert a local time to a synchronised time.
function NetSync.getSyncTime(localTime)
	return serverTimeReference + frequencyRatio * (localTime - clientTimeReference);
end

-- global
function NetSync.init()
	Log.d("NetSync.init!!!! %d", pingTimeoutDelay.current)
end

function NetSync.setStatus(s)
	if status ~= s then
      status = s
      statusChangedTime = NetSync.getLocalTime()
  end
end

function NetSync.getStatus()
	return status
end

function NetSync.getStatusDuration()
	local t = math.max(0, NetSync.getLocalTime() - statusChangedTime)
	Log.d("NetSync.getStatusDuration()!!![%s]", t)
	return t
end

function NetSync.setConnectionStatus(s)
	if connectionStatus ~= s then
      connectionStatus = s;
      connectionStatusChangedTime = NetSync.getLocalTime()
  end
end

function NetSync.getConnectionStatusDuration()
	return math.max(0, NetSync.getLocalTime() - connectionStatusChangedTime)
end

function NetSync.reportStatus()
end

function NetSync.procssRecv(clientPingTime, serverPingTime, serverPongTime)
	pingSeriesCount = pingSeriesCount + 1

	NetSync.setConnectionStatus("online")

	-- reduce timeout duration on pong, for better reactivity
	pingTimeoutDelay.current = math.max(pingTimeoutDelay.current * 0.75, pingTimeoutDelay.min)

	-- time-differences are valid on a single-side only (client or server)
	local clientPongTime = NetSync.getLocalTime()
	local clientTime = 0.5 * (clientPongTime + clientPingTime)
	local serverTime = 0.5 * (serverPongTime + serverPingTime)
	local travelDuration = math.max(0, (clientPongTime - clientPingTime)
                                        - (serverPongTime - serverPingTime))
  local offsetTime = serverTime - clientTime

  -- order is important for sorting, later.
  seriesData[seriesDataNextIndex]
          = {travelDuration, offsetTime, clientTime, serverTime}
  seriesDataNextIndex = seriesDataNextIndex + 1
  seriesDataNextIndex = seriesDataNextIndex % seriesDataLength
  if seriesDataNextIndex == 0 then seriesDataNextIndex = seriesDataLength end

  Log.d("ping %s, travel = %s, offset = %s, client = %s, server = %s count=%d, seriesDataNextIndex= %d, seriesDataLength= %d",
         pingId, travelDuration, offsetTime, clientTime, serverTime , #seriesData, seriesDataNextIndex, seriesDataLength)

  -- end of a series
  if pingSeriesCount >= pingSeriesIterations
            and #seriesData >= seriesDataLength then
      -- plan the begining of the next series
      --pingDelay = pingSeriesDelay.min
      --      + math.random() * (pingSeriesDelay.max - pingSeriesDelay.min)
      pingSeriesCount = 0;

      Log.d("1.0!")
      -- sort by travel time first, then offset time.
      --
      table.sort(seriesData, function(a, b)
      	if a[1] < b[1] then
        	return true
        else
        	return false
        end
      end)

      Log.d("1!")
      local sorted = seriesData
      local i = 1

      for i = 1, #seriesData, 1 do
      	Log.d('%d: [%s][%s][%s][%s]', i, seriesData[i][1], seriesData[i][2], seriesData[i][3], seriesData[i][4])
      end

      local seriesTravelDuration = sorted[1][1]
      Log.d("1.1![%s]", seriesTravelDuration)
      -- When the clock tick is long enough,
      -- some travel times (dimension 0) might be identical.
      -- Then, use the offset median (dimension 1 is the second sort key)
      local s = 1
      while (s < #sorted and sorted[s][1] <= seriesTravelDuration * 1.01)
      	do
            s = s+1
      	end
      Log.d("2!![%s][%s][%s]", s, sorted[s][1], (seriesTravelDuration * 1.01))
      s = math.max(1, s - 1)
      local median = math.floor(s / 2)
      if median == 0 then median = 1 end

      Log.d("2![%s][%s]", s, median)
      local seriesClientTime = sorted[median][3]
      local seriesServerTime = sorted[median][4]
      local seriesClientSquaredTime = seriesClientTime * seriesClientTime
      local seriesClientServerTime = seriesClientTime * seriesServerTime;

      Log.d("3![%s][%s][%s][%s]", seriesClientTime, seriesServerTime, seriesClientSquaredTime, seriesClientServerTime)
      longTermData[longTermDataNextIndex]
            = {seriesTravelDuration, seriesClientTime, seriesServerTime,
               seriesClientSquaredTime, seriesClientServerTime}

      longTermDataNextIndex = longTermDataNextIndex + 1
     	longTermDataNextIndex = longTermDataNextIndex % longTermDataLength

     	if longTermDataNextIndex == 0 then longTermDataNextIndex = longTermDataLength end

      -- mean of the time offset over 3 samples around median
      -- (it might use a longer travel duration)
      Log.d("3.1[%s][%s]", math.max(1, median-1), math.min(#sorted, median + 1))
      local aroundMedian = {}
      local i = 1
      local j = 1
      for i = math.max(1, median - 1), math.min(#sorted, median), 1 
      do
        Log.d("i[%d][%s]", i, sorted[i])
      	aroundMedian[j] = sorted[i]

      	Log.d("[%s] [%s] [%s] [%s]", aroundMedian[j][1], aroundMedian[j][2], aroundMedian[j][3], aroundMedian[j][4])

      	j = j + 1
      end
      Log.d("4![%s][%s]", #aroundMedian, median)
      timeOffset = mean(aroundMedian, 4) - mean(aroundMedian, 3)
      Log.d("5[%s]", timeOffset)
      if status == "startup"
             or (status == "training"
                 and NetSync.getStatusDuration() < longTermDataTrainingDuration) then
     		-- set only the phase offset, not the frequency
     		Log.d("6[%s]", timeOffset)
        serverTimeReference = timeOffset
        clientTimeReference = 0
        frequencyRatio = 1
        Log.d("6.1[%s]", timeOffset)
        NetSync.setStatus("training")
				Log.d("6.2[%s]", timeOffset)
        Log.d("T = %s + %s * (%s - %s) = %s",
              serverTimeReference, frequencyRatio,
              seriesClientTime, clientTimeReference,
              NetSync.getSyncTime(seriesClientTime))
      end

      Log.d("5")
      if ((status == "training"
              and NetSync.getStatusDuration() >= longTermDataTrainingDuration)
             or status == "sync") then
      	-- linear regression, R = covariance(t,T) / variance(t)
      	Log.d("7[%d]", #longTermData)
        local regClientTime = mean(longTermData, 2)

        local regServerTime = mean(longTermData, 3)
        local regClientSquaredTime = mean(longTermData, 4)
        local regClientServerTime = mean(longTermData, 5);

        local covariance = regClientServerTime - regClientTime * regServerTime
        local variance = regClientSquaredTime - regClientTime * regClientTime

        Log.d("8[%s][%s][%s][%s][%s][%s]", regClientTime, regServerTime, regClientSquaredTime, regClientServerTime, covariance, variance)
        if variance > 0 then
        	-- update freq and shift
          frequencyRatio = covariance / variance
          clientTimeReference = regClientTime
          serverTimeReference = regServerTime

          -- 0.05% is a lot (500 PPM, like an old mechanical clock)
          --if frequencyRatio > 0.9995 and frequencyRatio < 1.0005 then
          if frequencyRatio > 0.95 and frequencyRatio < 1.05 then
          	NetSync.setStatus('sync')
          else
          	Log.d("clock frequency ratio out of sync: %s, training again", frequencyRatio)
            -- start the training again from the last series
            serverTimeReference = timeOffset; -- offset only
            clientTimeReference = 0
            frequencyRatio = 1
            NetSync.setStatus("training")

            longTermData[1]
                  = {seriesTravelDuration, seriesClientTime, seriesServerTime,
                     seriesClientSquaredTime, seriesClientServerTime}
            longTermData.length = 1
            longTermDataNextIndex = 2;
          end
        end

        Log.d("T = %s + %s * (%s - %s) = %s",
               serverTimeReference, frequencyRatio,
               seriesClientTime, clientTimeReference,
               NetSync.getSyncTime(seriesClientTime))
      end
      Log.d("10[%d]", #sorted)
      travelDuration = mean(sorted, 1)
      Log.d("12[%d]", #sorted)
      travelDurationMin = sorted[1][1]
      Log.d("13[%d]", #sorted)
      travelDurationMax = sorted[#sorted][1]
      Log.d("14[%d]", #sorted)
      NetSync.reportStatus(reportFunction)
    else
    	--we are in a series, use the pingInterval value
      pingDelay = pingSeriesPeriod
    end
end

function NetSync.syncLoop()
end

function NetSync.start(sendFunction, receiveFunction, reportFunction)
    NetSync.init()

    Log.d("NetSync.start!!!")

   	NetSync.setStatus('startup')
    NetSync.setConnectionStatus('offline')

    NetSync.seriesData = {}
    NetSync.seriesDataNextIndex = 1

    NetSync.longTermData = {}
    NetSync.longTermDataNextIndex = 1
end

Log.d('NetSync!!!!')