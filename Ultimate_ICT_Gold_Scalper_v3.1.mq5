//+------------------------------------------------------------------+
//|                               Ultimate_ICT_Gold_Scalper_v3.1.mq5 |
//+------------------------------------------------------------------+
#property copyright "BAKOME"
#property link      ""
#property version   "3.1"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
//--- Risk Management
input group "=== Risk Management ==="
input double RiskPercent             = 1.0;   // Risk per trade (% of balance)
input double MaxDailyRiskPercent     = 5.0;   // Max daily loss (% of balance)
input double MaxDailyProfitPercent   = 8.0;   // Max daily profit (% of balance)
input int    MaxPositions            = 2;     // Max open positions
input int    MaxDailyTrades          = 10;    // Max trades per day

//--- XAUUSD Specific Settings
input group "=== XAUUSD Specific Settings ==="
input double MinATR_Points           = 100.0; // Min ATR required to trade (in points)
input double MaxSpreadPoints         = 50.0;  // Max allowed spread (in points)
input double ATR_SL_Multiplier       = 2.0;   // Stop Loss = ATR * Multiplier
input double ATR_TP_Multiplier       = 3.0;   // Take Profit = ATR * Multiplier

//--- ICT Strategy Parameters
input group "=== ICT Strategy Parameters ==="
input bool   UseLiquiditySweeps      = true;  // Enable Liquidity Sweeps
input bool   UseFairValueGaps        = true;  // Enable Fair Value Gap entries
input bool   UseOrderBlocks          = true;  // Enable Order Block validation
input bool   UseSilverBullet         = true;  // Filter trades by Silver Bullet time
input int    LiquidityLookback       = 50;    // Bars to scan for Liquidity High/Low
input int    FVG_Lookback            = 20;    // Bars to scan for FVG
input double FVG_MinSizeATR          = 0.5;   // Minimum FVG size relative to ATR

//--- Session Settings
input group "=== Session Settings ==="
input bool   TradeAsianSession       = false; // Trade Asian Session
input bool   TradeLondonSession      = true;  // Trade London Session
input bool   TradeNewYorkSession     = true;  // Trade New York Session
input int    LondonStartHour         = 7;     // London start hour (Server Time)
input int    NewYorkStartHour        = 13;    // NY start hour (Server Time)

//--- Silver Bullet Windows
input group "=== Silver Bullet Windows ==="
input bool   LondonSilverBullet      = true;  // Enable London Silver Bullet
input int    LondonKillZoneStart     = 8;     // London Silver Bullet Start Hour
input int    LondonKillZoneEnd       = 9;     // London Silver Bullet End Hour
input bool   NewYorkSilverBullet     = true;  // Enable NY Silver Bullet
input int    NYKillZoneStart         = 15;    // NY Silver Bullet Start Hour
input int    NYKillZoneEnd           = 16;    // NY Silver Bullet End Hour

//--- Position Management
input group "=== Position Management ==="
input bool   UseBreakEven            = true;  // Move SL to Break-Even
input double BE_TriggerATR           = 1.0;   // Move to BE when profit >= ATR * Multiplier
input bool   UseTrailingStop         = true;  // Enable Trailing Stop
input double Trail_StartATR          = 1.5;   // Start trailing when profit >= ATR * Multiplier
input double Trail_StepATR           = 0.5;   // Trailing step distance relative to ATR
input bool   UsePartialClose         = true;  // Enable Partial Close
input double PartialClosePercent     = 50.0;  // Volume % to close partially
input double PartialCloseTriggerATR  = 1.0;   // Partial close trigger relative to ATR

//--- Execution Settings
input group "=== Execution Settings ==="
input int    SlippagePoints          = 10;    // Slippage tolerance in points
input int    OrderRetryCount         = 5;     // Execution retry attempts
input int    OrderRetryDelayMs       = 200;   // Delay between retries in ms

//--- System Settings
input group "=== System Settings ==="
input int    LogLevel                = 3;     // Log Verbosity Level
input bool   UseAsyncExecution       = true;  // Use Async Order Execution
input bool   EnablePerformanceMode   = true;  // Only compute on New Bar

//+------------------------------------------------------------------+
//| GLOBAL OBJECTS AND VARIABLES                                     |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbol;

int            m_handleATR;
ulong          m_magicNumber       = 2645928;
datetime       m_lastBarTime       = 0;
datetime       m_lastCheckDay      = 0;
bool           m_targetLoggedToday = false;
double         m_dailyProfit       = 0.0;
int            m_dailyTradesCount  = 0;

// Tracker structure for positions
struct PositionTracker {
   ulong ticket;
   bool  breakEvenSet;
   bool  partiallyClosed;
};
PositionTracker m_trackers[];

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION FUNCTION                                   |
//+------------------------------------------------------------------+
int OnInit() {
   if(!m_symbol.Name(_Symbol)) {
      Print("[ERROR] Failed to initialize symbol info.");
      return INIT_FAILED;
   }
   m_symbol.Refresh();

   m_trade.SetExpertMagicNumber(m_magicNumber);
   m_trade.SetDeviationInPoints(SlippagePoints);
   
   if(UseAsyncExecution) {
      m_trade.SetAsyncMode(true);
   }

   // Initialize ATR Indicator
   m_handleATR = iATR(_Symbol, _Period, 14);
   if(m_handleATR == INVALID_HANDLE) {
      Print("[ERROR] Failed to create ATR indicator handle.");
      return INIT_FAILED;
   }

   Print("[INFO] BAKOME EA initialized successfully. Magic: ", m_magicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION FUNCTION                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(m_handleATR != INVALID_HANDLE) {
      IndicatorRelease(m_handleATR);
   }
   Print("[INFO] EA Deinitialized. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| UTILITY & CALCULATION FUNCTIONS                                  |
//+------------------------------------------------------------------+

// Fetch current ATR value
double GetCurrentATR() {
   double atr[1];
   if(CopyBuffer(m_handleATR, 0, 0, 1, atr) > 0) {
      return atr[0];
   }
   return 0.0;
}

// Check for new bar (Performance Mode)
bool IsNewBar() {
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime != m_lastBarTime) {
      m_lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

// Midnight Daily Reset Logic
void CheckDailyReset() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Normalize timestamp to midnight (00:00:00)
   datetime todayMidnight = StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   
   if(todayMidnight != m_lastCheckDay) {
      m_dailyProfit = 0.0;
      m_dailyTradesCount = 0;
      m_lastCheckDay = todayMidnight;
      m_targetLoggedToday = false;
      ArrayResize(m_trackers, 0); // Reset local trackers
      Print("[INFO] New trading day started. Daily metrics reset.");
   }
}

// Calculate cumulative Daily Profit and Trade Count from Account History
void UpdateDailyStats() {
   m_dailyProfit = 0.0;
   m_dailyTradesCount = 0;

   if(!HistorySelect(m_lastCheckDay, TimeCurrent())) return;

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;

      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == m_magicNumber &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         
         m_dailyProfit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
         m_dailyProfit += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         m_dailyProfit += HistoryDealGetDouble(ticket, DEAL_SWAP);
         m_dailyTradesCount++;
      }
   }
}

// Calculate Position Sizing based on Risk %
double CalculateLotSize(double slDistancePrice) {
   if(slDistancePrice <= 0) return m_symbol.LotsMin();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);
   double tickSize = m_symbol.TickSize();
   double tickValue = m_symbol.TickValue();

   if(tickSize <= 0 || tickValue <= 0) return m_symbol.LotsMin();

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0) return m_symbol.LotsMin();

   double lotSize = riskAmount / lossPerLot;
   
   // Step and Limit rounding
   double lotStep = m_symbol.LotsStep();
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(m_symbol.LotsMin(), MathMin(m_symbol.LotsMax(), lotSize));

   return lotSize;
}

// Check session hours & Silver Bullet Killzones
bool IsTradingAllowedByTime() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;

   // 1. Check Silver Bullet Windows if forced
   if(UseSilverBullet) {
      bool inLondonSB = LondonSilverBullet && (hour >= LondonKillZoneStart && hour < LondonKillZoneEnd);
      bool inNYSB = NewYorkSilverBullet && (hour >= NYKillZoneStart && hour < NYKillZoneEnd);
      if(!inLondonSB && !inNYSB) return false;
   }

   // 2. Check Standard Sessions
   bool inLondon = TradeLondonSession && (hour >= LondonStartHour && hour < LondonStartHour + 8);
   bool inNY     = TradeNewYorkSession && (hour >= NewYorkStartHour && hour < NewYorkStartHour + 8);
   bool inAsia   = TradeAsianSession && (hour >= 0 && hour < 8);

   return (inLondon || inNY || inAsia);
}

//+------------------------------------------------------------------+
//| ICT STRATEGY ANALYSIS                                            |
//+------------------------------------------------------------------+

// Detect Liquidity Sweeps (+1 = Bullish Sweep of Low, -1 = Bearish Sweep of High)
int CheckLiquiditySweep() {
   if(!UseLiquiditySweeps) return 0;

   double lowestLow = iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, LiquidityLookback, 2));
   double highestHigh = iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, LiquidityLookback, 2));

   double currentLow = iLow(_Symbol, _Period, 1);
   double currentHigh = iHigh(_Symbol, _Period, 1);
   double currentClose = iClose(_Symbol, _Period, 1);

   // Bullish Sweep: Price swept below previous low but closed back above it
   if(currentLow < lowestLow && currentClose > lowestLow) {
      return 1;
   }
   // Bearish Sweep: Price swept above previous high but closed back below it
   if(currentHigh > highestHigh && currentClose < highestHigh) {
      return -1;
   }

   return 0;
}

// Detect Fair Value Gap (+1 = Bullish FVG, -1 = Bearish FVG)
int CheckFVG(double atr) {
   if(!UseFairValueGaps) return 0;

   double minFVGSize = atr * FVG_MinSizeATR;

   // Check last few candles for FVG gap pattern
   for(int i = 1; i <= FVG_Lookback; i++) {
      double high3 = iHigh(_Symbol, _Period, i + 2);
      double low1  = iLow(_Symbol, _Period, i);

      // Bullish FVG: Low of candle 1 is higher than High of candle 3
      if(low1 - high3 >= minFVGSize) {
         return 1;
      }

      double low3  = iLow(_Symbol, _Period, i + 2);
      double high1 = iHigh(_Symbol, _Period, i);

      // Bearish FVG: High of candle 1 is lower than Low of candle 3
      if(low3 - high1 >= minFVGSize) {
         return -1;
      }
   }

   return 0;
}

// Detect Order Block Confluence
int CheckOrderBlock() {
   if(!UseOrderBlocks) return 0;

   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   double open2  = iOpen(_Symbol, _Period, 2);

   // Bullish Order Block: Last down candle before strong up expansion
   if(close2 < open2 && close1 > open1 && (close1 - open1) > (open2 - close2) * 1.5) {
      return 1;
   }
   // Bearish Order Block: Last up candle before strong down expansion
   if(close2 > open2 && close1 < open1 && (open1 - close1) > (close2 - open2) * 1.5) {
      return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT (Break-Even, Trailing Stop, Partial Close)   |
//+------------------------------------------------------------------+
void ManageOpenPositions(double currentATR) {
   int totalPositions = PositionsTotal();
   
   for(int i = totalPositions - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      if(!m_position.SelectByTicket(ticket)) continue;
      if(m_position.Magic() != m_magicNumber || m_position.Symbol() != _Symbol) continue;

      // Ensure tracker exists for this position
      int trackerIdx = -1;
      for(int t = 0; t < ArraySize(m_trackers); t++) {
         if(m_trackers[t].ticket == ticket) {
            trackerIdx = t;
            break;
         }
      }
      if(trackerIdx == -1) {
         int newSize = ArraySize(m_trackers) + 1;
         ArrayResize(m_trackers, newSize);
         trackerIdx = newSize - 1;
         m_trackers[trackerIdx].ticket = ticket;
         m_trackers[trackerIdx].breakEvenSet = false;
         m_trackers[trackerIdx].partiallyClosed = false;
      }

      // FIXED: Correct MQL5 standard library method PriceOpen()
      double entryPrice = m_position.PriceOpen();
      double currentSL  = m_position.StopLoss();
      double currentTP  = m_position.TakeProfit();
      double currentPrice = (m_position.PositionType() == POSITION_TYPE_BUY) ? m_symbol.Bid() : m_symbol.Ask();
      
      double profitPoints = 0.0;
      if(m_position.PositionType() == POSITION_TYPE_BUY) {
         profitPoints = currentPrice - entryPrice;
      } else {
         profitPoints = entryPrice - currentPrice;
      }

      // 1. Break-Even Management
      if(UseBreakEven && !m_trackers[trackerIdx].breakEvenSet) {
         if(profitPoints >= BE_TriggerATR * currentATR) {
            double newSL = entryPrice;
            if(m_trade.PositionModify(ticket, newSL, currentTP)) {
               m_trackers[trackerIdx].breakEvenSet = true;
               Print("[INFO] Break-Even applied for ticket #", ticket);
            }
         }
      }

      // 2. Partial Close Management
      if(UsePartialClose && !m_trackers[trackerIdx].partiallyClosed) {
         if(profitPoints >= PartialCloseTriggerATR * currentATR) {
            double closeVolume = m_position.Volume() * (PartialClosePercent / 100.0);
            double lotStep = m_symbol.LotsStep();
            closeVolume = MathFloor(closeVolume / lotStep) * lotStep;

            if(closeVolume >= m_symbol.LotsMin()) {
               if(m_trade.PositionClosePartial(ticket, closeVolume)) {
                  m_trackers[trackerIdx].partiallyClosed = true;
                  Print("[INFO] Partial Close executed for ticket #", ticket, " Volume: ", closeVolume);
               }
            }
         }
      }

      // 3. Trailing Stop Management
      if(UseTrailingStop) {
         if(profitPoints >= Trail_StartATR * currentATR) {
            double trailStepDist = Trail_StepATR * currentATR;

            if(m_position.PositionType() == POSITION_TYPE_BUY) {
               double desiredSL = currentPrice - trailStepDist;
               if(desiredSL > currentSL + (m_symbol.Point() * 10)) {
                  m_trade.PositionModify(ticket, desiredSL, currentTP);
               }
            } else if(m_position.PositionType() == POSITION_TYPE_SELL) {
               double desiredSL = currentPrice + trailStepDist;
               if(currentSL == 0 || desiredSL < currentSL - (m_symbol.Point() * 10)) {
                  m_trade.PositionModify(ticket, desiredSL, currentTP);
               }
            }
         }
      }
   }
}

// Count open positions belonging to this EA
int CountOpenPositions() {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && m_position.SelectByTicket(ticket)) {
         if(m_position.Magic() == m_magicNumber && m_position.Symbol() == _Symbol) {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| MAIN ON TICK FUNCTION                                            |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Midnight Reset Check
   CheckDailyReset();

   // 2. Refresh Prices & ATR
   if(!m_symbol.RefreshRates()) return;
   
   double currentATR = GetCurrentATR();
   if(currentATR <= 0) return;

   // 3. Manage active positions on every tick
   ManageOpenPositions(currentATR);

   // 4. Performance Optimization check
   if(EnablePerformanceMode && !IsNewBar()) return;

   // 5. Daily Risk & Profit Limit Enforcements
   UpdateDailyStats();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(m_dailyProfit >= balance * (MaxDailyProfitPercent / 100.0)) {
      if(!m_targetLoggedToday) {
         Print("[INFO] Daily profit target reached. Trading halted for today.");
         m_targetLoggedToday = true;
      }
      return;
   }

   if(m_dailyProfit <= -1.0 * balance * (MaxDailyRiskPercent / 100.0)) {
      if(!m_targetLoggedToday) {
         Print("[WARNING] Max daily loss limit hit. Trading halted for today.");
         m_targetLoggedToday = true;
      }
      return;
   }

   if(m_dailyTradesCount >= MaxDailyTrades) {
      return;
   }

   // 6. Pre-Trade Filters (Spread & ATR Thresholds)
   double currentSpread = (m_symbol.Ask() - m_symbol.Bid()) / m_symbol.Point();
   if(currentSpread > MaxSpreadPoints) return;
   if(currentATR < MinATR_Points * m_symbol.Point()) return;

   // 7. Max Open Positions Check
   if(CountOpenPositions() >= MaxPositions) return;

   // 8. Session & Time Window Check
   if(!IsTradingAllowedByTime()) return;

   // 9. Analyze ICT Signals
   int sweepSignal = CheckLiquiditySweep();
   int fvgSignal   = CheckFVG(currentATR);
   int obSignal    = CheckOrderBlock();

   // Signal Confluence
   int finalSignal = 0;
   if(sweepSignal > 0 && fvgSignal >= 0 && obSignal >= 0) finalSignal = 1;  // BUY
   if(sweepSignal < 0 && fvgSignal <= 0 && obSignal <= 0) finalSignal = -1; // SELL

   if(finalSignal == 0) return;

   // 10. Execute Trades
   double slDistance = currentATR * ATR_SL_Multiplier;
   double tpDistance = currentATR * ATR_TP_Multiplier;
   double lotSize    = CalculateLotSize(slDistance);

   if(finalSignal == 1) { // BUY ORDER
      double ask = m_symbol.Ask();
      double sl  = ask - slDistance;
      double tp  = ask + tpDistance;

      if(m_trade.Buy(lotSize, _Symbol, ask, sl, tp, "ICT Scalp Buy")) {
         Print("[INFO] Executed BUY ", lotSize, " @ ", ask);
      }
   }
   else if(finalSignal == -1) { // SELL ORDER
      double bid = m_symbol.Bid();
      double sl  = bid + slDistance;
      double tp  = bid - tpDistance;

      if(m_trade.Sell(lotSize, _Symbol, bid, sl, tp, "ICT Scalp Sell")) {
         Print("[INFO] Executed SELL ", lotSize, " @ ", bid);
      }
   }
}
