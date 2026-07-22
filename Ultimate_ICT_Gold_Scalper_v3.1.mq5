//+------------------------------------------------------------------+
//|                                BAKOME_Ultimate_ICT_Gold_Scalper_v3.0.mq5 |
//|                                      BAKOME Trading Systems      |
//|                                                      Version 3.1 |
//+------------------------------------------------------------------+
#property copyright "BAKOME – Fabrice Kitoko"
#property version   "3.1"
#property description "Advanced ICT Gold Scalper with FVG, Order Blocks, Silver Bullet"
#property link      "https://github.com/BAKOME-Hub"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/AccountInfo.mqh>
#include <Trade/DealInfo.mqh>
#include <Math/Stat/Math.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double RiskPercent            = 1.0;      // Risk per trade (%)
input double MaxDailyRiskPercent    = 5.0;      // Max daily loss (%)
input double MaxDailyProfitPercent  = 8.0;      // Daily profit target (%)
input int    MaxPositions           = 2;        // Maximum concurrent positions
input int    MaxDailyTrades         = 10;       // Maximum trades per day

input group "=== XAUUSD Specific Settings ==="
input double MinATR_Points          = 100.0;    // Minimum ATR for Gold (points)
input double MaxSpreadPoints        = 50.0;     // Maximum spread (points)
input double ATR_SL_Multiplier      = 2.0;      // Stop Loss ATR multiplier
input double ATR_TP_Multiplier      = 3.0;      // Take Profit ATR multiplier

input group "=== ICT Strategy Parameters ==="
input bool   UseLiquiditySweeps     = true;     // Use liquidity sweeps
input bool   UseFairValueGaps       = true;     // Use Fair Value Gaps
input bool   UseOrderBlocks         = true;     // Use Order Blocks
input bool   UseSilverBullet        = true;     // Use Silver Bullet
input int    LiquidityLookback      = 50;       // Bars for liquidity lookback
input int    FVG_Lookback           = 20;       // Bars for FVG lookback
input double FVG_MinSizeATR         = 0.5;      // Minimum FVG size (x ATR)

input group "=== Session Settings ==="
input bool   TradeAsianSession      = false;    // Trade Asian session
input bool   TradeLondonSession     = true;     // Trade London session
input bool   TradeNewYorkSession    = true;     // Trade New York session
input int    LondonStartHour        = 7;        // London session start
input int    NewYorkStartHour       = 13;       // New York session start

input group "=== Silver Bullet Windows ==="
input bool   LondonSilverBullet     = true;
input int    LondonKillZoneStart    = 8;
input int    LondonKillZoneEnd      = 9;
input bool   NewYorkSilverBullet    = true;
input int    NYKillZoneStart        = 15;
input int    NYKillZoneEnd          = 16;

input group "=== Position Management ==="
input bool   UseBreakEven           = true;
input double BE_TriggerATR          = 1.0;
input bool   UseTrailingStop        = true;
input double Trail_StartATR         = 1.5;
input double Trail_StepATR          = 0.5;
input bool   UsePartialClose        = true;
input double PartialClosePercent    = 50.0;
input double PartialCloseTriggerATR = 1.0;

input group "=== Execution Settings ==="
input int    SlippagePoints         = 10;
input int    OrderRetryCount        = 5;
input int    OrderRetryDelayMs      = 200;

input group "=== System Settings ==="
enum ENUM_LOG_LEVEL {
   LOG_NONE = 0,
   LOG_ERROR = 1,
   LOG_WARNING = 2,
   LOG_INFO = 3,
   LOG_DEBUG = 4
};
input ENUM_LOG_LEVEL LogLevel          = LOG_INFO;
input bool           UseAsyncExecution = true;
input bool           EnablePerformanceMode = true;

//+------------------------------------------------------------------+
//| Structures and Classes                                           |
//+------------------------------------------------------------------+

class CMarketData {
public:
   datetime time[10000];
   double   high[10000];
   double   low[10000];
   double   close[10000];
   double   volume[10000];
   int      dataIndex;
   CMarketData() : dataIndex(0) {}
   void AddBar(datetime t, double h, double l, double c, double v) {
      int idx = dataIndex % 10000;
      time[idx] = t;
      high[idx] = h;
      low[idx] = l;
      close[idx] = c;
      volume[idx] = v;
      dataIndex++;
   }
};

struct LiquidityLevel {
   double   price;
   datetime time;
   int      strength;
   bool     isHigh;
   bool     swept;
   double   volume;
};

struct FairValueGap {
   double   topPrice;
   double   bottomPrice;
   datetime time;
   bool     isBullish;
   bool     filled;
   double   size;
};

struct OrderBlock {
   double   topPrice;
   double   bottomPrice;
   datetime time;
   bool     isBullish;
   bool     mitigated;
   double   volume;
};

class CPositionTracker {
public:
   ulong    ticket;
   datetime openTime;
   double   openPrice;
   double   originalSL;
   double   originalTP;
   bool     partialClosed;
   bool     breakEvenSet;
   bool     trailingActive;
   double   peakProfit;
   double   currentRR;
   CPositionTracker() { Reset(); }
   void Reset() {
      ticket = 0;
      openTime = 0;
      openPrice = 0;
      originalSL = 0;
      originalTP = 0;
      partialClosed = false;
      breakEvenSet = false;
      trailingActive = false;
      peakProfit = 0;
      currentRR = 0;
   }
};

template<typename T>
class CObjectPool {
private:
   T*  m_pool[];
   int m_poolSize;
   int m_nextAvailable;
public:
   CObjectPool(int size = 100) {
      m_poolSize = size;
      ArrayResize(m_pool, m_poolSize);
      m_nextAvailable = 0;
      for(int i = 0; i < m_poolSize; i++)
         m_pool[i] = new T();
   }
   ~CObjectPool() {
      for(int i = 0; i < m_poolSize; i++)
         delete m_pool[i];
   }
   T* Acquire() {
      if(m_nextAvailable >= m_poolSize) {
         int oldSize = m_poolSize;
         m_poolSize *= 2;
         ArrayResize(m_pool, m_poolSize);
         for(int i = oldSize; i < m_poolSize; i++)
            m_pool[i] = new T();
      }
      return m_pool[m_nextAvailable++];
   }
   void Release(T* obj) {
      obj.Reset();
      m_nextAvailable--;
   }
};

//+------------------------------------------------------------------+
//| Main EA Class                                                    |
//+------------------------------------------------------------------+
class CUltimateICTGoldScalper {
private:
   CTrade         m_trade;
   CPositionInfo  m_position;
   CSymbolInfo    m_symbol;
   CAccountInfo   m_account;
   int            m_atrHandle;
   int            m_emaFastHandle;
   int            m_emaSlowHandle;
   LiquidityLevel m_liquidityLevels[];
   FairValueGap   m_fairValueGaps[];
   OrderBlock     m_orderBlocks[];
   CMarketData    m_marketData;
   CObjectPool<CPositionTracker>* m_positionPool;
   CPositionTracker*               m_activePositions[];
   double         m_dayStartBalance;
   int            m_todayTradeCount;
   datetime       m_lastTradeTime;
   double         m_currentATR;
   long           m_magicNumber;
   bool           m_initialized;
   
   void LogError(string msg)   { if(LogLevel >= LOG_ERROR)   Print("[ERROR] ", msg); }
   void LogWarning(string msg) { if(LogLevel >= LOG_WARNING) Print("[WARN] ",  msg); }
   void LogInfo(string msg)    { if(LogLevel >= LOG_INFO)    Print("[INFO] ",  msg); }
   void LogDebug(string msg)   { if(LogLevel >= LOG_DEBUG)   Print("[DEBUG] ", msg); }
   
   long GenerateMagicNumber() {
      string str = _Symbol + IntegerToString(Period());
      uchar arr[];
      StringToCharArray(str, arr);
      long hash = 0;
      for(int i = 0; i < ArraySize(arr); i++)
         hash = (hash * 31 + arr[i]) % 9999999;
      return 100000 + hash;
   }
   
   bool IsRecoverableError(int errorCode) {
      switch(errorCode) {
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_TIMEOUT:
         case TRADE_RETCODE_CONNECTION:
            return true;
         default:
            return false;
      }
   }
   
   bool ExecuteWithRetry(MqlTradeRequest &request, MqlTradeResult &result) {
      for(int attempt = 0; attempt < OrderRetryCount; attempt++) {
         ZeroMemory(result);
         if(OrderSend(request, result)) {
            if(result.retcode == TRADE_RETCODE_DONE) return true;
         }
         if(!IsRecoverableError(result.retcode)) break;
         Sleep(OrderRetryDelayMs * (int)MathPow(2, attempt));
      }
      return false;
   }
   
   double GetAverageVolume(int periods) {
      long volumes[];
      ArraySetAsSeries(volumes, true);
      if(CopyTickVolume(_Symbol, PERIOD_M5, 0, periods, volumes) <= 0) return 0;
      double sum = 0;
      for(int i = 0; i < periods; i++) sum += (double)volumes[i];
      return sum / periods;
   }
   
   double GetCurrentVolumeRatio() {
      long volumes[];
      if(CopyTickVolume(_Symbol, PERIOD_M5, 0, 1, volumes) <= 0) return 1.0;
      double currentVolume = (double)volumes[0];
      double avgVolume = GetAverageVolume(20);
      if(avgVolume > 0) return currentVolume / avgVolume;
      return 1.0;
   }
   
   bool IsInKillZone() {
      if(!UseSilverBullet) return false;
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int hour = dt.hour;
      if(LondonSilverBullet && hour >= LondonKillZoneStart && hour < LondonKillZoneEnd) return true;
      if(NewYorkSilverBullet && hour >= NYKillZoneStart && hour < NYKillZoneEnd) return true;
      return false;
   }
   
   bool IsInTradingSession() {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int hour = dt.hour;
      if(TradeAsianSession && hour >= 0 && hour < 6) return true;
      if(TradeLondonSession && hour >= LondonStartHour && hour < LondonStartHour+4) return true;
      if(TradeNewYorkSession && hour >= NewYorkStartHour && hour < NewYorkStartHour+4) return true;
      return false;
   }
   
   ENUM_POSITION_TYPE GetMarketBias() {
      double emaBuffer[];
      ArraySetAsSeries(emaBuffer, true);
      if(CopyBuffer(m_emaSlowHandle, 0, 0, 1, emaBuffer) <= 0) return -1;
      double closeBuffer[];
      ArraySetAsSeries(closeBuffer, true);
      if(CopyClose(_Symbol, PERIOD_M5, 0, 1, closeBuffer) <= 0) return -1;
      double currentPrice = closeBuffer[0];
      if(currentPrice > emaBuffer[0]) return POSITION_TYPE_BUY;
      if(currentPrice < emaBuffer[0]) return POSITION_TYPE_SELL;
      return -1;
   }
   
   void AddLiquidityLevel(double price, bool isHigh, datetime time) {
      int size = ArraySize(m_liquidityLevels);
      ArrayResize(m_liquidityLevels, size + 1);
      m_liquidityLevels[size].price = price;
      m_liquidityLevels[size].isHigh = isHigh;
      m_liquidityLevels[size].time = time;
      m_liquidityLevels[size].swept = false;
      m_liquidityLevels[size].strength = CalculateLevelStrength(price);
      long volumes[1];
      if(CopyTickVolume(_Symbol, PERIOD_M5, 0, 1, volumes) > 0)
         m_liquidityLevels[size].volume = (double)volumes[0];
   }
   
   int CalculateLevelStrength(double price) {
      int strength = 0;
      double tolerance = m_currentATR * 0.1;
      double highBuffer[], lowBuffer[];
      ArraySetAsSeries(highBuffer, true);
      ArraySetAsSeries(lowBuffer, true);
      if(CopyHigh(_Symbol, PERIOD_M5, 0, 100, highBuffer) <= 0) return 0;
      if(CopyLow(_Symbol, PERIOD_M5, 0, 100, lowBuffer) <= 0) return 0;
      for(int i = 0; i < 100; i++) {
         if(MathAbs(highBuffer[i] - price) < tolerance || MathAbs(lowBuffer[i] - price) < tolerance)
            strength++;
      }
      return strength;
   }
   
   void UpdateLiquidityLevels() {
      ArrayResize(m_liquidityLevels, 0);
      double highBuffer[];
      double lowBuffer[];
      datetime timeBuffer[];
      ArraySetAsSeries(highBuffer, true);
      ArraySetAsSeries(lowBuffer, true);
      ArraySetAsSeries(timeBuffer, true);
      
      if(CopyHigh(_Symbol, PERIOD_M5, 0, LiquidityLookback, highBuffer) <= 0) return;
      if(CopyLow(_Symbol, PERIOD_M5, 0, LiquidityLookback, lowBuffer) <= 0) return;
      if(CopyTime(_Symbol, PERIOD_M5, 0, LiquidityLookback, timeBuffer) <= 0) return;
      
      for(int i = 3; i < LiquidityLookback - 2; i++) {
         if(highBuffer[i] > highBuffer[i-1] &&
            highBuffer[i] > highBuffer[i-2] &&
            highBuffer[i] > highBuffer[i+1] &&
            highBuffer[i] > highBuffer[i+2]) {
            AddLiquidityLevel(highBuffer[i], true, timeBuffer[i]);
         }
         if(lowBuffer[i] < lowBuffer[i-1] &&
            lowBuffer[i] < lowBuffer[i-2] &&
            lowBuffer[i] < lowBuffer[i+1] &&
            lowBuffer[i] < lowBuffer[i+2]) {
            AddLiquidityLevel(lowBuffer[i], false, timeBuffer[i]);
         }
      }
      
      double dailyHigh[], dailyLow[], weeklyHigh[], weeklyLow[];
      if(CopyHigh(_Symbol, PERIOD_D1, 0, 1, dailyHigh) > 0) AddLiquidityLevel(dailyHigh[0], true, 0);
      if(CopyLow(_Symbol, PERIOD_D1, 0, 1, dailyLow) > 0) AddLiquidityLevel(dailyLow[0], false, 0);
      if(CopyHigh(_Symbol, PERIOD_W1, 0, 1, weeklyHigh) > 0) AddLiquidityLevel(weeklyHigh[0], true, 0);
      if(CopyLow(_Symbol, PERIOD_W1, 0, 1, weeklyLow) > 0) AddLiquidityLevel(weeklyLow[0], false, 0);
   }
   
   void UpdateFairValueGaps() {
      if(!UseFairValueGaps) return;
      ArrayResize(m_fairValueGaps, 0);
      double closeBuffer[], highBuffer[], lowBuffer[];
      datetime timeBuffer[];
      ArraySetAsSeries(closeBuffer, true);
      ArraySetAsSeries(highBuffer, true);
      ArraySetAsSeries(lowBuffer, true);
      ArraySetAsSeries(timeBuffer, true);
      
      if(CopyClose(_Symbol, PERIOD_M5, 0, FVG_Lookback, closeBuffer) <= 0) return;
      if(CopyHigh(_Symbol, PERIOD_M5, 0, FVG_Lookback, highBuffer) <= 0) return;
      if(CopyLow(_Symbol, PERIOD_M5, 0, FVG_Lookback, lowBuffer) <= 0) return;
      if(CopyTime(_Symbol, PERIOD_M5, 0, FVG_Lookback, timeBuffer) <= 0) return;
      
      for(int i = 2; i < FVG_Lookback - 1; i++) {
         if(lowBuffer[i] > highBuffer[i-1]) {
            double gapSize = lowBuffer[i] - highBuffer[i-1];
            if(gapSize >= m_currentATR * FVG_MinSizeATR) {
               int size = ArraySize(m_fairValueGaps);
               ArrayResize(m_fairValueGaps, size + 1);
               m_fairValueGaps[size].topPrice = lowBuffer[i];
               m_fairValueGaps[size].bottomPrice = highBuffer[i-1];
               m_fairValueGaps[size].time = timeBuffer[i];
               m_fairValueGaps[size].isBullish = true;
               m_fairValueGaps[size].filled = false;
               m_fairValueGaps[size].size = gapSize;
            }
         }
         if(highBuffer[i] < lowBuffer[i-1]) {
            double gapSize = lowBuffer[i-1] - highBuffer[i];
            if(gapSize >= m_currentATR * FVG_MinSizeATR) {
               int size = ArraySize(m_fairValueGaps);
               ArrayResize(m_fairValueGaps, size + 1);
               m_fairValueGaps[size].topPrice = highBuffer[i];
               m_fairValueGaps[size].bottomPrice = lowBuffer[i-1];
               m_fairValueGaps[size].time = timeBuffer[i];
               m_fairValueGaps[size].isBullish = false;
               m_fairValueGaps[size].filled = false;
               m_fairValueGaps[size].size = gapSize;
            }
         }
      }
   }
   
   void UpdateOrderBlocks() {
      if(!UseOrderBlocks) return;
      ArrayResize(m_orderBlocks, 0);
      double closeBuffer[], openBuffer[], highBuffer[], lowBuffer[];
      datetime timeBuffer[];
      ArraySetAsSeries(closeBuffer, true);
      ArraySetAsSeries(openBuffer, true);
      ArraySetAsSeries(highBuffer, true);
      ArraySetAsSeries(lowBuffer, true);
      ArraySetAsSeries(timeBuffer, true);
      
      if(CopyClose(_Symbol, PERIOD_M5, 0, 50, closeBuffer) <= 0) return;
      if(CopyOpen(_Symbol, PERIOD_M5, 0, 50, openBuffer) <= 0) return;
      if(CopyHigh(_Symbol, PERIOD_M5, 0, 50, highBuffer) <= 0) return;
      if(CopyLow(_Symbol, PERIOD_M5, 0, 50, lowBuffer) <= 0) return;
      if(CopyTime(_Symbol, PERIOD_M5, 0, 50, timeBuffer) <= 0) return;
      
      for(int i = 1; i < 50; i++) {
         if(closeBuffer[i] < openBuffer[i]) { // bearish
            if(closeBuffer[i-1] > openBuffer[i-1]) { // bullish next
               int size = ArraySize(m_orderBlocks);
               ArrayResize(m_orderBlocks, size + 1);
               m_orderBlocks[size].topPrice = highBuffer[i];
               m_orderBlocks[size].bottomPrice = lowBuffer[i];
               m_orderBlocks[size].time = timeBuffer[i];
               m_orderBlocks[size].isBullish = true;
               m_orderBlocks[size].mitigated = false;
               long volumes[1];
               if(CopyTickVolume(_Symbol, PERIOD_M5, i, 1, volumes) > 0)
                  m_orderBlocks[size].volume = (double)volumes[0];
            }
         }
         if(closeBuffer[i] > openBuffer[i]) { // bullish
            if(closeBuffer[i-1] < openBuffer[i-1]) { // bearish next
               int size = ArraySize(m_orderBlocks);
               ArrayResize(m_orderBlocks, size + 1);
               m_orderBlocks[size].topPrice = highBuffer[i];
               m_orderBlocks[size].bottomPrice = lowBuffer[i];
               m_orderBlocks[size].time = timeBuffer[i];
               m_orderBlocks[size].isBullish = false;
               m_orderBlocks[size].mitigated = false;
               long volumes[1];
               if(CopyTickVolume(_Symbol, PERIOD_M5, i, 1, volumes) > 0)
                  m_orderBlocks[size].volume = (double)volumes[0];
            }
         }
      }
   }
   
   void UpdateMarketData() {
      double atrBuffer[];
      ArraySetAsSeries(atrBuffer, true);
      if(CopyBuffer(m_atrHandle, 0, 0, 1, atrBuffer) > 0)
         m_currentATR = atrBuffer[0];
      
      double highBuf[], lowBuf[], closeBuf[];
      long volumeBuf[];
      ArraySetAsSeries(highBuf, true);
      ArraySetAsSeries(lowBuf, true);
      ArraySetAsSeries(closeBuf, true);
      ArraySetAsSeries(volumeBuf, true);
      
      if(CopyHigh(_Symbol, PERIOD_M5, 0, 1, highBuf) > 0 &&
         CopyLow(_Symbol, PERIOD_M5, 0, 1, lowBuf) > 0 &&
         CopyClose(_Symbol, PERIOD_M5, 0, 1, closeBuf) > 0 &&
         CopyTickVolume(_Symbol, PERIOD_M5, 0, 1, volumeBuf) > 0) {
         m_marketData.AddBar(TimeCurrent(), highBuf[0], lowBuf[0], closeBuf[0], (double)volumeBuf[0]);
      }
   }
   
   bool CheckDailyLimits() {
      if(m_todayTradeCount >= MaxDailyTrades) return true;
      double currentEquity = m_account.Equity();
      double dailyPL = (currentEquity - m_dayStartBalance) / m_dayStartBalance * 100;
      if(dailyPL <= -MaxDailyRiskPercent) { LogWarning("Daily loss limit reached"); return true; }
      if(dailyPL >= MaxDailyProfitPercent) { LogInfo("Daily profit target reached"); return true; }
      return false;
   }
   
   void ResetDailyStats() {
      m_todayTradeCount = 0;
      m_dayStartBalance = m_account.Balance();
   }
   
   bool CanOpenNewPosition() {
      int openPositions = 0;
      for(int i = 0; i < PositionsTotal(); i++)
         if(m_position.SelectByIndex(i) && m_position.Magic() == m_magicNumber) openPositions++;
      if(openPositions >= MaxPositions) return false;
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > MaxSpreadPoints) return false;
      if(m_currentATR / m_symbol.Point() < MinATR_Points) return false;
      if(!IsInTradingSession()) return false;
      return true;
   }
   
   // FIX #2: Call RefreshRates() so Ask/Bid doesn't return 0.0 creating bad SL/TP
   void CalculateBullishEntry(double &entry, double &sl, double &tp) {
      m_symbol.RefreshRates(); 
      entry = m_symbol.Ask();
      sl = entry - (m_currentATR * ATR_SL_Multiplier);
      tp = entry + (m_currentATR * ATR_TP_Multiplier);
      entry = NormalizeDouble(entry, (int)m_symbol.Digits());
      sl   = NormalizeDouble(sl,   (int)m_symbol.Digits());
      tp   = NormalizeDouble(tp,   (int)m_symbol.Digits());
   }
   
   void CalculateBearishEntry(double &entry, double &sl, double &tp) {
      m_symbol.RefreshRates();
      entry = m_symbol.Bid();
      sl = entry + (m_currentATR * ATR_SL_Multiplier);
      tp = entry - (m_currentATR * ATR_TP_Multiplier);
      entry = NormalizeDouble(entry, (int)m_symbol.Digits());
      sl   = NormalizeDouble(sl,   (int)m_symbol.Digits());
      tp   = NormalizeDouble(tp,   (int)m_symbol.Digits());
   }
   
   // FIX #3: Adjusted mathematical formula so lot calculation is based on actual tick values
   double RiskLot(double riskPercent, double atr) {
      double riskAmount = m_account.Balance() * riskPercent / 100.0;
      double slDistance = atr * ATR_SL_Multiplier;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      
      if(slDistance <= 0 || tickValue <= 0 || tickSize <= 0) return 0.01;
      
      double slPoints = slDistance / tickSize;
      double lot = riskAmount / (slPoints * tickValue);
      
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      
      lot = MathRound(lot / stepLot) * stepLot;
      if(lot < minLot) lot = minLot;
      if(lot > maxLot) lot = maxLot;
      
      return NormalizeDouble(lot, 2);
   }
   
   void ApplyBreakEven(CPositionTracker &pos) {
      if(!UseBreakEven || pos.breakEvenSet) return;
      double beTrigger = m_currentATR * BE_TriggerATR;
      if(m_position.SelectByTicket(pos.ticket)) {
         if(m_position.Profit() >= beTrigger) {
            double entry = m_position.OpenPrice();
            m_trade.PositionModify(pos.ticket, entry, m_position.TakeProfit());
            pos.breakEvenSet = true;
         }
      }
   }
   
   void ManageTrailingStop(CPositionTracker &pos) {
      if(!UseTrailingStop || pos.trailingActive) return;
      if(m_position.SelectByTicket(pos.ticket)) {
         double profit = m_position.Profit();
         double trailStart = m_currentATR * Trail_StartATR;
         if(profit >= trailStart) {
            if(m_position.PositionType() == POSITION_TYPE_BUY) {
               double newSL = m_symbol.Bid() - (m_currentATR * Trail_StepATR);
               if(newSL > m_position.StopLoss() || m_position.StopLoss() == 0) {
                  m_trade.PositionModify(pos.ticket, newSL, m_position.TakeProfit());
                  pos.trailingActive = true;
               }
            } else {
               double newSL = m_symbol.Ask() + (m_currentATR * Trail_StepATR);
               if(newSL < m_position.StopLoss() || m_position.StopLoss() == 0) {
                  m_trade.PositionModify(pos.ticket, newSL, m_position.TakeProfit());
                  pos.trailingActive = true;
               }
            }
         }
      }
   }
   
   void ExecuteTrade(int type) {
      if(!CanOpenNewPosition() || CheckDailyLimits()) return;
      double entry, sl, tp;
      
      if(type == ORDER_TYPE_BUY) CalculateBullishEntry(entry, sl, tp);
      else CalculateBearishEntry(entry, sl, tp);
      
      double lot = RiskLot(RiskPercent, m_currentATR);
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      request.action = TRADE_ACTION_DEAL;
      request.symbol = _Symbol;
      request.volume = lot;
      request.type = (ENUM_ORDER_TYPE)type;
      request.price = entry;
      request.sl = sl;
      request.tp = tp;
      request.deviation = SlippagePoints;
      request.magic = m_magicNumber;
      request.comment = "BAKOME_ICT_EA";
      
      // FIX #1: Added dynamic filling mode detection
      int fillFlags = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
      if((fillFlags & SYMBOL_FILLING_FOK) != 0) request.type_filling = ORDER_FILLING_FOK;
      else if((fillFlags & SYMBOL_FILLING_IOC) != 0) request.type_filling = ORDER_FILLING_IOC;
      else request.type_filling = ORDER_FILLING_RETURN;
      
      if(ExecuteWithRetry(request, result)) {
         LogInfo(StringFormat("Executed %s %.2f @ %.2f", (type==ORDER_TYPE_BUY)?"BUY":"SELL", lot, entry));
         m_todayTradeCount++;
         CPositionTracker* pos = m_positionPool.Acquire();
         pos.ticket = result.order;
         pos.openTime = TimeCurrent();
         pos.openPrice = entry;
         pos.originalSL = sl;
         pos.originalTP = tp;
         ArrayResize(m_activePositions, ArraySize(m_activePositions)+1);
         m_activePositions[ArraySize(m_activePositions)-1] = pos;
      } else LogError(StringFormat("Order failed: %d", result.retcode));
   }
   
public:
   CUltimateICTGoldScalper() { m_positionPool = new CObjectPool<CPositionTracker>(5); }
   ~CUltimateICTGoldScalper() { delete m_positionPool; }
   
   bool Init() {
      m_symbol.Name(_Symbol);
      m_symbol.Refresh();
      m_atrHandle = iATR(_Symbol, PERIOD_M5, 14);
      m_emaFastHandle = iMA(_Symbol, PERIOD_H1, 34, 0, MODE_EMA, PRICE_CLOSE);
      m_emaSlowHandle = iMA(_Symbol, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
      if(m_atrHandle==INVALID_HANDLE || m_emaFastHandle==INVALID_HANDLE || m_emaSlowHandle==INVALID_HANDLE) {
         LogError("Indicators failed");
         return false;
      }
      m_magicNumber = GenerateMagicNumber();
      m_dayStartBalance = m_account.Balance();
      m_todayTradeCount = 0;
      m_initialized = true;
      LogInfo("BAKOME EA initialized. Magic: " + IntegerToString(m_magicNumber));
      return true;
   }
   
   void OnTick() {
      if(!m_initialized) return;
      UpdateMarketData();
      UpdateLiquidityLevels();
      UpdateFairValueGaps();
      UpdateOrderBlocks();
      for(int i=0; i<ArraySize(m_activePositions); i++) {
         CPositionTracker* pos = m_activePositions[i];
         if(pos && m_position.SelectByTicket(pos.ticket)) {
            if(!m_position.SelectByTicket(pos.ticket) || m_position.Time() == 0) {
               m_positionPool.Release(pos);
               ArrayRemove(m_activePositions, i, 1);
               i--;
               continue;
            }
            if(m_position.StopLoss() == 0 && m_position.Profit() > 0) ApplyBreakEven(*pos);
            ManageTrailingStop(*pos);
         }
      }
      if(IsInKillZone()) {
         ENUM_POSITION_TYPE bias = GetMarketBias();
         if(bias == POSITION_TYPE_BUY) ExecuteTrade(ORDER_TYPE_BUY);
         else if(bias == POSITION_TYPE_SELL) ExecuteTrade(ORDER_TYPE_SELL);
      }
   }
};

CUltimateICTGoldScalper EA;

void OnInit() { if(!EA.Init()) ExpertRemove(); }
void OnTick() { EA.OnTick(); }
void OnDeinit(const int reason) { Print("EA removed: ", reason); }
